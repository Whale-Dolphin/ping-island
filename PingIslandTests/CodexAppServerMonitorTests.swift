import Foundation
import XCTest
@testable import Ping_Island

final class CodexAppServerMonitorTests: XCTestCase {
    private actor SentRPCs {
        var messages: [String] = []
        func append(_ message: String) { messages.append(message) }
    }

    func testCompletionCallbacksReturnBeforeTheirRefreshRPCReply() async throws {
        for method in ["serverRequest/resolved", "item/autoApprovalReview/completed"] {
            let sent = SentRPCs()
            let requestSent = expectation(description: "refresh request sent")
            let callbackReturned = expectation(description: "receive callback returned")
            let monitor = CodexAppServerMonitor(messageSender: { message in
                await sent.append(message)
                requestSent.fulfill()
            })
            let threadID = "refresh-callback-\(UUID().uuidString)"
            if method == "serverRequest/resolved" {
                try await deliver([
                    "id": "approval", "method": "item/commandExecution/requestApproval",
                    "params": ["threadId": threadID, "command": ["printf", "done"]]
                ], to: monitor)
            }
            let callback = Task {
                try await deliver(["method": method, "params": [
                    "threadId": threadID, "requestId": "approval", "targetItemId": "review"
                ]], to: monitor)
                callbackReturned.fulfill()
            }
            // The full serial app suite can leave SessionStore/MainActor work queued
            // for more than one second. A real receive-loop deadlock still fails
            // deterministically because neither expectation can ever complete.
            await fulfillment(of: [requestSent, callbackReturned], timeout: 5)
            if let text = await sent.messages.first {
                let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                XCTAssertEqual(request["method"] as? String, "thread/read")
                // Feed the reply only after checking that the callback returned.
                try await deliver(["id": request["id"]!, "error": ["message": "fake refresh finished"]], to: monitor)
            }
            try await callback.value
            await monitor.stop()
            await SessionStore.shared.process(.sessionArchived(sessionId: threadID))
        }
    }

    func testAppServerMCPInferenceRespectsCachedReviewerAndNeverPolicy() async throws {
        let monitor = CodexAppServerMonitor()
        let threadID = "mcp-review-cache-\(UUID().uuidString)"
        let thread: [String: Any] = [
            "id": threadID, "source": "cli", "originator": "codex-tui", "cwd": "/tmp/reviewer-test",
            "status": ["type": "active"], "turns": [["id": "turn", "items": [[
                "id": "mcp-item", "type": "mcpToolCall", "server": "test", "tool": "read", "status": "inProgress"
            ]]]]
        ]
        for (policy, reviewer, shouldInfer) in [
            ("on-request", "auto_review", false), (" NEVER ", "user", false),
            ("on-request", "guardian_subagent", true)
        ] {
            try await deliver(["method": "thread/settings/updated", "params": [
                "threadId": threadID, "threadSettings": ["approvalPolicy": policy, "approvalsReviewer": reviewer]
            ]], to: monitor)
            let snapshot = await monitor.parseThreadSnapshot(thread)
            XCTAssertEqual(snapshot?.clientInfo?.kind, .codexCLI)
            XCTAssertEqual(snapshot?.intervention != nil, shouldInfer)
        }
        await monitor.stop()
    }

    private func deliver(_ object: [String: Any], to monitor: CodexAppServerMonitor) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        await monitor.handle(.data(data))
    }

    func testAutomaticReviewNotificationsDoNotReplaceOrResolveGenuineApproval() async throws {
        let monitor = CodexAppServerMonitor()
        let store = SessionStore.shared
        let threadId = "auto-review-\(UUID().uuidString)"
        await store.upsertCodexSession(
            sessionId: threadId, name: nil, preview: nil, cwd: "/tmp/codex-review",
            phase: .processing, intervention: nil, clientInfo: .codexCLI()
        )
        try await deliver([
            "method": "thread/settings/updated",
            "params": ["threadId": threadId, "threadSettings": [
                "approvalPolicy": "on-request", "approvalsReviewer": " AUTO-REVIEW ",
                "sandboxPolicy": ["type": "workspaceWrite"]
            ]]
        ], to: monitor)
        let review: [String: Any] = [
            "threadId": threadId, "targetItemId": "review-tool",
            "review": ["status": "inProgress"],
            "action": ["type": "command", "command": "printf done"]
        ]
        try await deliver(["method": "item/autoApprovalReview/started", "params": review], to: monitor)
        var session = await store.session(for: threadId)
        XCTAssertEqual(session?.phase, .processing)
        XCTAssertNil(session?.intervention)

        try await deliver([
            "id": "approval-1", "method": "item/commandExecution/requestApproval",
            "params": ["threadId": threadId, "command": ["printf", "done"], "callId": "command-1"]
        ], to: monitor)
        try await deliver(["method": "item/autoApprovalReview/started", "params": review], to: monitor)
        try await deliver([
            "method": "item/autoApprovalReview/completed",
            "params": ["threadId": threadId, "targetItemId": "review-tool"]
        ], to: monitor)
        session = await store.session(for: threadId)
        XCTAssertEqual(session?.intervention?.id, "approval-1")
        XCTAssertEqual(session?.intervention?.kind, .approval)

        try await deliver([
            "method": "serverRequest/resolved",
            "params": ["threadId": threadId, "requestId": "older-approval"]
        ], to: monitor)
        session = await store.session(for: threadId)
        XCTAssertEqual(session?.intervention?.id, "approval-1")
        try await deliver([
            "method": "serverRequest/resolved",
            "params": ["threadId": threadId, "requestId": "approval-1"]
        ], to: monitor)
        session = await store.session(for: threadId)
        XCTAssertNil(session?.intervention)
        XCTAssertEqual(session?.phase, .processing)
        await store.process(.sessionArchived(sessionId: threadId))
    }

    func testSettingsUpdateRestoresManualReviewAndCompletionMatchesTargetItem() async throws {
        let monitor = CodexAppServerMonitor()
        let store = SessionStore.shared
        let threadId = "manual-review-\(UUID().uuidString)"
        await store.upsertCodexSession(
            sessionId: threadId, name: nil, preview: nil, cwd: "/tmp/codex-review", phase: .processing,
            intervention: nil, clientInfo: .codexCLI()
        )
        for reviewer in ["auto_review", "guardian_subagent"] {
            try await deliver([
                "method": "thread/settings/updated",
                "params": ["threadId": threadId, "threadSettings": [
                    "approvalPolicy": "on-request", "approvals_reviewer": reviewer
                ]]
            ], to: monitor)
        }
        try await deliver([
            "method": "item/autoApprovalReview/started",
            "params": ["threadId": threadId, "targetItemId": "manual-tool",
                       "review": ["status": "inProgress"],
                       "action": ["type": "mcpToolCall", "server": "test", "toolName": "read"]]
        ], to: monitor)
        var session = await store.session(for: threadId)
        XCTAssertEqual(session?.intervention?.id, "manual-tool")
        XCTAssertEqual(session?.phase, .waitingForInput)
        try await deliver([
            "method": "item/autoApprovalReview/completed",
            "params": ["threadId": threadId, "targetItemId": "older-tool"]
        ], to: monitor)
        session = await store.session(for: threadId)
        XCTAssertEqual(session?.intervention?.id, "manual-tool")
        try await deliver([
            "method": "item/autoApprovalReview/completed",
            "params": ["threadId": threadId, "targetItemId": "manual-tool"]
        ], to: monitor)
        session = await store.session(for: threadId)
        XCTAssertNil(session?.intervention)
        await store.process(.sessionArchived(sessionId: threadId))
    }

    private func makeTemporaryRollout(
        named name: String,
        modificationDate: Date
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-island-codex-thread-normalizer", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
        return url
    }

    func testWebSocketTaskAllowsLargeCodexMessages() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:41241"))
        let task = CodexAppServerMonitor.makeWebSocketTask(url: url)
        defer {
            task.cancel(with: .goingAway, reason: nil)
        }

        XCTAssertEqual(task.maximumMessageSize, CodexAppServerMonitor.maximumWebSocketMessageSize)
        XCTAssertGreaterThan(task.maximumMessageSize, 1_214_839)
    }

    func testWebSocketPayloadsEncodeAsTextJSON() throws {
        let message = try CodexAppServerMonitor.webSocketTextMessage(from: [
            "jsonrpc": "2.0",
            "id": "1",
            "method": "initialize",
            "params": [
                "capabilities": [
                    "experimentalApi": true
                ],
                "clientInfo": [
                    "name": "Island",
                    "title": "Island",
                    "version": "0.0.4"
                ]
            ]
        ])

        let data = try XCTUnwrap(message.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["id"] as? String, "1")
        XCTAssertEqual(json["method"] as? String, "initialize")

        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "Island")
    }

    func testGuardianReviewInterventionMapsMcpToolApprovalToExternalReminder() throws {
        let intervention = try XCTUnwrap(
            CodexAppServerMonitor.guardianReviewIntervention(from: [
                "threadId": "thread-1",
                "targetItemId": "item-1",
                "review": [
                    "status": "inProgress"
                ],
                "action": [
                    "type": "mcpToolCall",
                    "server": "omx_state",
                    "toolName": "state_list_active"
                ]
            ])
        )

        XCTAssertEqual(intervention.kind, .question)
        XCTAssertEqual(intervention.title, "MCP Tool Approval Needed")
        XCTAssertEqual(
            intervention.message,
            "Allow the omx_state MCP server to run tool \"state_list_active\"?"
        )
        XCTAssertEqual(intervention.metadata["responseMode"], "external_only")
        XCTAssertEqual(intervention.metadata["source"], "guardian_review")
    }

    func testAutoApprovalReviewDoesNotSurfaceAsUserPrompt() {
        XCTAssertFalse(CodexAppServerMonitor.shouldSurfaceAutoApprovalReview(
            approvalsReviewer: "auto_review"
        ))
        XCTAssertFalse(CodexAppServerMonitor.shouldSurfaceAutoApprovalReview(
            approvalsReviewer: " AUTO-REVIEW "
        ))
        XCTAssertTrue(CodexAppServerMonitor.shouldSurfaceAutoApprovalReview(
            approvalsReviewer: "user"
        ))
        XCTAssertTrue(CodexAppServerMonitor.shouldSurfaceAutoApprovalReview(
            approvalsReviewer: nil
        ))
    }

    func testApprovalSettingsReadCurrentCodexHeartbeatShape() {
        let settings = CodexAppServerMonitor.approvalSettings(
            from: [
                "electron-persisted-atom-state": [
                    "heartbeat-thread-permissions-by-id": [
                        "thread-1": [
                            "approvalPolicy": "on-request",
                            "approvalsReviewer": "auto_review"
                        ]
                    ]
                ]
            ],
            threadId: "thread-1"
        )

        XCTAssertEqual(settings.approvalPolicy, "on-request")
        XCTAssertEqual(settings.approvalsReviewer, "auto_review")
    }

    func testCodexUserInputQuestionsDefaultToCustomInput() {
        let questions = CodexAppServerMonitor.parseQuestions([
            [
                "id": "scope",
                "header": "Scope",
                "question": "Where should Codex focus?",
                "options": [
                    ["label": "Tests"],
                    ["label": "UI"]
                ]
            ]
        ])

        XCTAssertEqual(questions.first?.options.map(\.title), ["Tests", "UI"])
        XCTAssertTrue(questions.first?.allowsOther ?? false)
    }

    func testRecentIdleThreadRequestsRolloutRecoveryAfterReconnect() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)
        let recentUpdate = referenceDate.addingTimeInterval(-93).timeIntervalSince1970
        let rolloutPath = "/tmp/ping-island-tests/rollout-thread-with-recent-activity.jsonl"
        let thread: [String: Any] = [
            "id": "thread-with-recent-activity",
            "updatedAt": recentUpdate,
            "status": ["type": "idle"],
            "path": rolloutPath
        ]

        XCTAssertTrue(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: thread,
            referenceDate: referenceDate
        ))
        XCTAssertEqual(CodexAppServerMonitor.rolloutPath(from: thread), rolloutPath)
    }

    func testActiveThreadRequestsRolloutRecoveryDespiteStaleTimestamp() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)

        XCTAssertTrue(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: [
                "id": "active-thread",
                "updatedAt": referenceDate.addingTimeInterval(-(60 * 60)).timeIntervalSince1970,
                "status": ["type": "active"]
            ],
            referenceDate: referenceDate
        ))
    }

    func testStaleIdleThreadDoesNotRequestRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_481_907)
        let staleUpdate = referenceDate.addingTimeInterval(-(31 * 60)).timeIntervalSince1970

        XCTAssertFalse(CodexAppServerMonitor.shouldRecoverRolloutSnapshot(
            from: [
                "id": "stale-thread",
                "updatedAt": staleUpdate,
                "status": ["type": "idle"]
            ],
            referenceDate: referenceDate
        ))
    }

    func testRecentNotLoadedThreadRequestsRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let thread: [String: Any] = [
            "id": "vscode-thread",
            "updatedAt": referenceDate.addingTimeInterval(-15).timeIntervalSince1970,
            "recencyAt": referenceDate.addingTimeInterval(-30).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]

        XCTAssertNotNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))
    }

    func testNotLoadedThreadRecoveryUsesRecencyTimestampWhenUpdatedTimestampIsMissing() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let thread: [String: Any] = [
            "id": "vscode-thread",
            "recencyAt": referenceDate.addingTimeInterval(-15).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]

        XCTAssertNotNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))
    }

    func testLoadedAndStaleThreadsDoNotRequestRolloutRecovery() {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        let recentTimestamp = referenceDate.addingTimeInterval(-15).timeIntervalSince1970
        let staleTimestamp = referenceDate.addingTimeInterval(-(11 * 60)).timeIntervalSince1970

        XCTAssertNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: [
                "id": "loaded-thread",
                "updatedAt": recentTimestamp,
                "status": ["type": "active"]
            ],
            referenceDate: referenceDate
        ))
        XCTAssertNil(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: [
                "id": "stale-thread",
                "updatedAt": staleTimestamp,
                "status": ["type": "notLoaded"]
            ],
            referenceDate: referenceDate
        ))
    }

    func testNotLoadedRecoveryVersionChangesWhenActivityAdvances() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_784_812_800)
        var thread: [String: Any] = [
            "id": "vscode-thread",
            "updatedAt": referenceDate.addingTimeInterval(-30).timeIntervalSince1970,
            "status": ["type": "notLoaded"]
        ]
        let initialVersion = try XCTUnwrap(CodexAppServerMonitor.notLoadedRecoveryVersion(
            from: thread,
            referenceDate: referenceDate
        ))

        thread["updatedAt"] = referenceDate.addingTimeInterval(-5).timeIntervalSince1970

        XCTAssertNotEqual(
            initialVersion,
            CodexAppServerMonitor.notLoadedRecoveryVersion(
                from: thread,
                referenceDate: referenceDate
            )
        )
    }

    func testRolloutPathAcceptsJSONLPathWithoutTreatingWorkspaceAsSessionFile() {
        XCTAssertEqual(
            CodexAppServerMonitor.rolloutPath(from: [
                "path": "/tmp/codex/rollout-vscode-thread.jsonl"
            ]),
            "/tmp/codex/rollout-vscode-thread.jsonl"
        )
        XCTAssertNil(CodexAppServerMonitor.rolloutPath(from: [
            "path": "/tmp/codex-workspace"
        ]))
    }

    func testCanonicalThreadListImportsDuplicateThreadIDOnlyOnceAndPrefersActiveCandidate() {
        let inactive: [String: Any] = [
            "id": "thread-duplicate",
            "updatedAt": 200,
            "status": ["type": "idle"],
            "path": "/tmp/codex/rollout-idle.jsonl"
        ]
        let active: [String: Any] = [
            "id": "thread-duplicate",
            "updatedAt": 100,
            "status": ["type": "active"],
            "path": "/tmp/codex/rollout-active.jsonl"
        ]

        let canonical = CodexThreadListNormalizer.canonicalThreads(from: [inactive, active])

        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(
            CodexAppServerMonitor.rolloutPath(from: canonical[0]),
            "/tmp/codex/rollout-active.jsonl"
        )
    }

    func testCanonicalThreadListPrefersNewerUpdatedAtBeforeRolloutMetadata() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let newerFile = try makeTemporaryRollout(
            named: "rollout-newer-file.jsonl",
            modificationDate: reference
        )
        let olderFile = try makeTemporaryRollout(
            named: "rollout-older-file.jsonl",
            modificationDate: reference.addingTimeInterval(-60)
        )
        defer {
            try? FileManager.default.removeItem(at: newerFile.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: olderFile.deletingLastPathComponent())
        }

        let canonical = CodexThreadListNormalizer.canonicalThreads(from: [
            [
                "id": "thread-updated-at",
                "updatedAt": reference.addingTimeInterval(-30).timeIntervalSince1970,
                "status": ["type": "idle"],
                "path": newerFile.path
            ],
            [
                "id": "thread-updated-at",
                "updatedAt": reference.timeIntervalSince1970,
                "status": ["type": "idle"],
                "path": olderFile.path
            ]
        ])

        XCTAssertEqual(CodexAppServerMonitor.rolloutPath(from: canonical[0]), olderFile.path)
    }

    func testCanonicalThreadListKeepsContinuationPathWhenDuplicateOrderingAlternates() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let oldRollout = try makeTemporaryRollout(
            named: "rollout-old.jsonl",
            modificationDate: reference.addingTimeInterval(-60)
        )
        let continuationRollout = try makeTemporaryRollout(
            named: "rollout-continuation.jsonl",
            modificationDate: reference
        )
        defer {
            try? FileManager.default.removeItem(at: oldRollout.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: continuationRollout.deletingLastPathComponent())
        }

        let old: [String: Any] = [
            "id": "thread-continuation",
            "updatedAt": reference.timeIntervalSince1970,
            "status": ["type": "idle"],
            "path": oldRollout.path
        ]
        let continuation: [String: Any] = [
            "id": "thread-continuation",
            "updatedAt": reference.timeIntervalSince1970,
            "status": ["type": "idle"],
            "path": continuationRollout.path
        ]

        let first = CodexThreadListNormalizer.canonicalThreads(from: [old, continuation])
        let second = CodexThreadListNormalizer.canonicalThreads(from: [continuation, old])
        let oldOnlyAfterContinuation = CodexThreadListNormalizer.canonicalThreads(
            from: [old],
            preferredRolloutPaths: ["thread-continuation": continuationRollout.path]
        )

        XCTAssertEqual(CodexAppServerMonitor.rolloutPath(from: first[0]), continuationRollout.path)
        XCTAssertEqual(CodexAppServerMonitor.rolloutPath(from: second[0]), continuationRollout.path)
        XCTAssertEqual(
            CodexAppServerMonitor.rolloutPath(from: oldOnlyAfterContinuation[0]),
            continuationRollout.path
        )
    }

    func testRolloutRecoveryCacheSkipsRepeatedPollsAndSeparatesPaths() {
        var cache = CodexRolloutRecoveryCache()
        let oldPath = "/tmp/codex/../codex/rollout-old.jsonl"
        let normalizedOldPath = "/tmp/codex/rollout-old.jsonl"
        let continuationPath = "/tmp/codex/rollout-continuation.jsonl"

        let first = cache.update(
            threadId: "thread-1",
            rolloutPath: oldPath,
            recoveryVersion: "version-1"
        )
        XCTAssertTrue(first.shouldRequestFileSync)
        XCTAssertNil(first.discardedParserPath)

        for _ in 0..<10 {
            let repeated = cache.update(
                threadId: "thread-1",
                rolloutPath: normalizedOldPath,
                recoveryVersion: "version-1"
            )
            XCTAssertFalse(repeated.shouldRequestFileSync)
            XCTAssertNil(repeated.discardedParserPath)
        }

        let continuation = cache.update(
            threadId: "thread-1",
            rolloutPath: continuationPath,
            recoveryVersion: "version-1"
        )
        XCTAssertTrue(continuation.shouldRequestFileSync)
        XCTAssertEqual(continuation.discardedParserPath, normalizedOldPath)

        let repeatedContinuation = cache.update(
            threadId: "thread-1",
            rolloutPath: continuationPath,
            recoveryVersion: "version-1"
        )
        XCTAssertFalse(repeatedContinuation.shouldRequestFileSync)
        XCTAssertNil(repeatedContinuation.discardedParserPath)
        XCTAssertEqual(cache.versions.count, 2)
    }

    func testUserForkDoesNotCountAsAppServerSubagentWithoutExplicitMetadata() {
        XCTAssertFalse(CodexAppServerMonitor.hasExplicitSubagentMetadata(in: [
            "id": "user-fork",
            "forkedFromId": "parent-thread",
            "source": "vscode",
            "threadSource": "user"
        ]))

        XCTAssertTrue(CodexAppServerMonitor.hasExplicitSubagentMetadata(in: [
            "id": "spawned-agent",
            "forkedFromId": "parent-thread",
            "source": [
                "subagent": [
                    "thread_spawn": [
                        "parent_thread_id": "parent-thread",
                        "depth": 1
                    ]
                ]
            ]
        ]))
    }
}
