import Darwin
import Foundation
import XCTest
@testable import Ping_Island

final class HookEventResponseRoutingTests: XCTestCase {
    private final class ReceivedEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [HookEvent] = []
        func append(_ event: HookEvent) {
            lock.lock()
            defer { lock.unlock() }
            values.append(event)
        }
        func snapshot() -> [HookEvent] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func route(_ envelope: [String: Any], through server: HookSocketServer) throws -> [String: Any] {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
        defer { close(sockets[1]) }
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard server.writeAll(data, to: sockets[1]) else { throw POSIXError(.EIO) }
        shutdown(sockets[1], SHUT_WR)
        server.handleClient(sockets[0])
        var descriptor = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 1_000) > 0 else {
            server.cancelPendingPermissions(sessionId: envelope["sessionKey"] as? String ?? "")
            throw POSIXError(.ETIMEDOUT)
        }
        var response = [UInt8](repeating: 0, count: 4_096)
        let count = read(sockets[1], &response, response.count)
        guard count > 0 else { throw POSIXError(.EIO) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.prefix(count))) as? [String: Any])
    }

    func testDefaultCodexAutoReviewEnvelopeDefersWithoutDecisionThenAcceptsToolAndStop() throws {
        let received = ReceivedEvents()
        let server = HookSocketServer(onEvent: { received.append($0) })
        let sessionId = "codex-auto-review-\(UUID().uuidString)"
        let requestId = UUID()
        let metadata = [
            "session_id": sessionId,
            "client_kind": "codex-cli",
            "tool_name": "Bash",
            "tool_use_id": "auto-reviewed-tool",
            "tool_input_json": "{\"command\":\"printf done\"}",
            "approval_policy": "on-request",
            "approvals_reviewer": "auto_review",
            "sandbox_mode": "workspace-write",
            "permission_mode": "default"
        ]
        var envelope: [String: Any] = [
            "id": requestId.uuidString, "provider": "codex", "eventType": "PermissionRequest",
            "sessionKey": "codex:\(sessionId)", "cwd": "/tmp/auto-review-project",
            "status": ["kind": "waitingForApproval"], "expectsResponse": true, "metadata": metadata
        ]
        let response = try route(envelope, through: server)
        XCTAssertEqual(response["requestID"] as? String, requestId.uuidString)
        XCTAssertNil(response["decision"])
        XCTAssertNil(response["updatedInput"])
        XCTAssertTrue(received.snapshot().isEmpty, "Automatic review must not reach the human-intervention handler")
        XCTAssertFalse(server.hasPendingPermission(sessionId: sessionId))

        for (eventType, status) in [("PreToolUse", "runningTool"), ("PostToolUse", "active"), ("Stop", "idle")] {
            envelope["id"] = UUID().uuidString
            envelope["eventType"] = eventType
            envelope["status"] = ["kind": status]
            envelope["expectsResponse"] = false
            let result = try route(envelope, through: server)
            XCTAssertNil(result["decision"])
        }
        XCTAssertEqual(received.snapshot().map(\.event), ["PreToolUse", "PostToolUse", "Stop"])
        XCTAssertTrue(received.snapshot().allSatisfy { $0.intervention == nil && !$0.codexBypassPermissions })
        XCTAssertFalse(server.hasPendingPermission(sessionId: sessionId))
    }

    func testWriteAllRetriesInterruptedAndShortWritesWithoutDroppingBytes() {
        let server = HookSocketServer()
        let data = Data("complete bridge response".utf8)
        var written = Data()
        var attempts = 0
        XCTAssertTrue(server.writeAll(data, to: -1) { _, pointer, remaining in
            attempts += 1
            if attempts == 1 { errno = EINTR; return -1 }
            let count = min(3, remaining)
            written.append(pointer!.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        })
        XCTAssertEqual(written, data)
        XCTAssertGreaterThan(attempts, 2)
        XCTAssertFalse(server.writeAll(data, to: -1) { _, _, _ in 0 })
    }

    func testCodexAutomaticApprovalReviewIsDetectedFromBridgeMetadata() {
        XCTAssertTrue(CodexAutomaticApprovalReviewResolver.shouldDeferToCodex(
            provider: "codex",
            eventType: "PermissionRequest",
            metadata: [
                "permission_mode": "default",
                "approvals_reviewer": "auto_review"
            ]
        ))
    }

    func testCodexManualReviewerKeepsPingIslandApprovalPath() {
        XCTAssertFalse(CodexAutomaticApprovalReviewResolver.shouldDeferToCodex(
            provider: "codex",
            eventType: "PermissionRequest",
            metadata: [
                "permission_mode": "default",
                "approvals_reviewer": "guardian_subagent"
            ]
        ))
    }

    func testCodexBypassPermissionsKeepsExistingApprovalPath() {
        XCTAssertFalse(CodexAutomaticApprovalReviewResolver.shouldDeferToCodex(
            provider: "codex",
            eventType: "PermissionRequest",
            metadata: [
                "permission_mode": "bypassPermissions",
                "approvals_reviewer": "auto_review"
            ]
        ))
    }

    func testTerminalRoutedPermissionRequestStillExpectsResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Edit",
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertTrue(event.expectsResponse)
    }

    func testTerminalRoutedAskUserQuestionDoesNotExpectResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: ["questions": AnyCodable([["question": "Pick one"]])],
            toolUseId: "question-tool",
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertFalse(event.expectsResponse)
    }

    func testExplicitNonResponsivePermissionRequestDoesNotSurfaceApproval() {
        let intervention = SessionIntervention(
            id: "toolu_nonresponsive",
            kind: .approval,
            title: "Claude needs approval",
            message: "WebSearch",
            options: [
                SessionInterventionOption(id: "approve", title: "Allow Once", detail: nil),
                SessionInterventionOption(id: "deny", title: "Deny", detail: nil)
            ],
            questions: [],
            supportsSessionScope: true,
            metadata: ["tool_name": "WebSearch"]
        )

        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "WebSearch",
            toolInput: ["query": AnyCodable("AI news")],
            toolUseId: "toolu_nonresponsive",
            notificationType: nil,
            message: nil,
            bridgeIntervention: intervention,
            bridgeExpectsResponse: false
        )

        XCTAssertFalse(event.expectsResponse)
        XCTAssertNil(event.intervention)
        guard case .processing = event.determinePhase() else {
            XCTFail("Expected non-responsive permission request to determine processing phase")
            return
        }
        guard case .processing = event.sessionPhase else {
            XCTFail("Expected non-responsive permission request session phase to stay processing")
            return
        }
    }

    func testQoderCLIAnsweredQuestionPermissionRequestStillExpectsReplayResponse() {
        let event = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "processing",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli",
                terminalBundleIdentifier: "com.qoder.ide"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "header": "Task type",
                        "question": "What would you like to work on today?",
                        "options": [
                            ["label": "Write new code"],
                            ["label": "Debug or fix a bug"]
                        ]
                    ]
                ]),
                "answers": AnyCodable([
                    "What would you like to work on today?": "Write new code"
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil
        )

        XCTAssertTrue(event.isAnsweredAskUserQuestionEvent)
        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertTrue(event.expectsResponse)
        XCTAssertNil(event.intervention)
    }

    func testQoderCLIQuestionsOnlyPermissionRequestStillExpectsReplayResponse() {
        let event = HookEvent(
            sessionId: "qoder-cli-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(
                kind: .qoder,
                profileID: "qoder-cli",
                name: "Qoder CLI",
                origin: "cli",
                terminalBundleIdentifier: "com.googlecode.iterm2"
            ),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: [
                "questions": AnyCodable([
                    [
                        "header": "Task type",
                        "question": "What would you like to work on today?",
                        "options": [
                            ["label": "Write new code"],
                            ["label": "Debug or fix a bug"]
                        ]
                    ]
                ])
            ],
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            bridgeExpectsResponse: true
        )

        XCTAssertFalse(event.isAnsweredAskUserQuestionEvent)
        XCTAssertFalse(event.isAskUserQuestionRequest)
        XCTAssertTrue(event.expectsResponse)
    }

}
