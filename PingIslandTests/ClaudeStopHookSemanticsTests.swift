import XCTest
@testable import Ping_Island

/// Integration tests for the Stop / SubagentStop / SessionEnd hook semantics
/// introduced by the `fix-claude-sound-triggers` change. These verify that the
/// new mapping (Stop → "waiting_for_input", SubagentStop → "running_tool",
/// SessionEnd → "ended") flows through `SessionStore.processHookEvent` without
/// invoking `markSessionEnded` for the non-terminating events.
final class ClaudeStopHookSemanticsTests: XCTestCase {

    func testClaudeStopKeepsSessionAliveAndPreservesAutoApprove() async {
        let sessionId = "claude-stop-alive-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Prime: arrive via UserPromptSubmit so the session exists in processing.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))

        // Arm autoApprove on the live session — markSessionEnded would clear it.
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )

        // Now the Stop event arrives, post-mapping, as "waiting_for_input".
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertNotNil(session, "Session must remain in store after Stop")
        XCTAssertEqual(session?.phase, .waitingForInput,
                       "Stop with new mapping must land in .waitingForInput, not .ended")
        XCTAssertTrue(session?.autoApprovePermissions ?? false,
                      "markSessionEnded clears autoApprovePermissions; preservation proves it was NOT called")
        XCTAssertNil(session?.intervention)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testClaudeSubagentStopDoesNotEndParentSession() async {
        let sessionId = "claude-subagent-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Prime: parent session is actively running a Task tool.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "PreToolUse",
            status: "running_tool",
            tool: "Task",
            toolUseId: "task-1"
        )))
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )

        // SubagentStop arrives, post-mapping, as "running_tool" (parent stays processing).
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "SubagentStop",
            status: "running_tool"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertNotNil(session, "Parent session must survive SubagentStop")
        XCTAssertNotEqual(session?.phase, .ended,
                          "SubagentStop must NOT mark the parent session as ended")
        XCTAssertTrue(session?.autoApprovePermissions ?? false,
                      "markSessionEnded clears autoApprovePermissions; preservation proves it was NOT called")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testClaudeSessionEndStillTerminatesSession() async {
        let sessionId = "claude-end-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(
            .permissionAutoApprovalChanged(sessionId: sessionId, isEnabled: true)
        )
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "Notification",
            status: "waiting_for_input",
            suppressInAppPrompt: true
        )))
        let routedPrompt = await store.session(for: sessionId)
        XCTAssertTrue(routedPrompt?.needsPromptNotification ?? false)
        XCTAssertFalse(routedPrompt?.canInteract ?? true)

        // SessionEnd remains the sole terminating event — status "ended".
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            event: "SessionEnd",
            status: "ended"
        )))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .ended,
                       "SessionEnd MUST still mark the session as .ended")
        XCTAssertFalse(session?.autoApprovePermissions ?? true,
                       "markSessionEnded clears autoApprovePermissions on a real SessionEnd")
        XCTAssertFalse(session?.suppressInAppPromptControls ?? true,
                       "SessionEnd must clear terminal-routed prompt visibility")
        XCTAssertFalse(session?.needsPromptNotification ?? true,
                       "An ended session must not remain eligible as an unanswered prompt")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testTwoAssistantEndTurnAppendsAfterStopStayCompletedUntilNewUserInput() async throws {
        let store = SessionStore.shared
        let sessionId = "stop-two-appends-\(UUID().uuidString)"
        // A separate reader ID keeps debounced hook syncs from consuming this
        // deterministic test reader's deltas. Both use the real incremental parser.
        let readerId = "stop-reader-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("transcript.jsonl")
        try Data().write(to: transcript)
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func appendRecord(id: String, role: String, at timestamp: Date) throws {
            var message: [String: Any] = [
                "id": role == "assistant" ? "one-assistant-response" : id,
                "role": role,
                "content": [["type": "text", "text": id]]
            ]
            if role == "assistant" { message["stop_reason"] = "end_turn" }
            let record: [String: Any] = [
                "uuid": id, "type": role,
                "timestamp": formatter.string(from: timestamp), "message": message
            ]
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        func syncAppend() async {
            let parsed = await ConversationParser.shared.parseIncremental(
                sessionId: readerId, cwd: directory.path, explicitFilePath: transcript.path
            )
            await store.processFileUpdate(FileUpdatePayload(
                sessionId: sessionId, cwd: directory.path,
                messages: parsed.newMessages, isIncremental: !parsed.clearDetected,
                completedToolIds: parsed.completedToolIds, toolResults: parsed.toolResults,
                structuredResults: parsed.structuredResults
            ), conversationInfoLoader: {
                ConversationInfo(
                    summary: nil, lastMessage: "Final response", lastMessageRole: "assistant",
                    lastToolName: nil, firstUserMessage: "Original prompt", lastUserMessageDate: nil
                )
            })
        }

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId, event: "UserPromptSubmit", status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId, event: "Stop", status: "waiting_for_input"
        )))
        let finishedSnapshot = await store.session(for: sessionId)
        let finished = try XCTUnwrap(finishedSnapshot)
        try appendRecord(id: "old-user", role: "user", at: finished.lastActivity.addingTimeInterval(-10))

        for index in 1...2 {
            try appendRecord(
                id: "final-record-\(index)", role: "assistant",
                at: finished.lastActivity.addingTimeInterval(Double(index))
            )
            await syncAppend()
            let snapshot = await store.session(for: sessionId)
            XCTAssertEqual(snapshot?.phase, .waitingForInput, "Assistant append \(index) is not a new turn")
            XCTAssertFalse(snapshot?.isExecutionActive ?? true)
            XCTAssertFalse(snapshot?.needsManualAttention ?? true)
            let unchanged = await ConversationParser.shared.parseIncremental(
                sessionId: readerId, cwd: directory.path, explicitFilePath: transcript.path
            )
            XCTAssertTrue(unchanged.newMessages.isEmpty, "An unchanged file never replays old input")
        }
        let beforePromptSnapshot = await store.session(for: sessionId)
        let beforePrompt = try XCTUnwrap(beforePromptSnapshot)
        XCTAssertTrue(beforePrompt.chatItems.contains { $0.id == "final-record-1-text-0" })
        XCTAssertTrue(beforePrompt.chatItems.contains { $0.id == "final-record-2-text-0" })
        try appendRecord(id: "genuinely-new-user", role: "user", at: beforePrompt.lastActivity.addingTimeInterval(60))
        await syncAppend()
        let resumed = await store.session(for: sessionId)
        XCTAssertEqual(resumed?.phase, .processing)
        XCTAssertTrue(resumed?.isExecutionActive ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
        await ConversationParser.shared.resetState(for: readerId)
    }

    // MARK: - Helpers

    private func makeClaudeEvent(
        sessionId: String,
        event: String,
        status: String,
        tool: String? = nil,
        toolUseId: String? = nil,
        suppressInAppPrompt: Bool = false
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/project",
            event: event,
            status: status,
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .claudeCode,
                profileID: "claude_code",
                name: "Claude Code",
                bundleIdentifier: "com.anthropic.claudecode"
            ),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: tool != nil ? [:] : nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: suppressInAppPrompt
        )
    }
}
