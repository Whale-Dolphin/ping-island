import Foundation
import XCTest
@testable import Ping_Island

final class SessionMonitorCodexWatcherTests: XCTestCase {
    func testCodexLifecycleLinesRequestImmediateRolloutSync() {
        XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(in: """
        {"type":"event_msg","payload":{"type":"task_started"}}
        """))
        XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(in: """
        {"type": "event_msg", "payload": {"type": "task_complete"}}
        """))
        XCTAssertTrue(JSONLInterruptWatcher.requiresImmediateSessionSync(in: """
        {"type":"response_item","payload":{"type":"function_call","name":"request_user_input"}}
        """))
        XCTAssertFalse(JSONLInterruptWatcher.requiresImmediateSessionSync(in: """
        {"type":"event_msg","payload":{"type":"user_message","message":"task_started"}}
        """))
        XCTAssertFalse(JSONLInterruptWatcher.requiresImmediateSessionSync(in: """
        {"type":"event_msg","payload":{"type":"token_count"}}
        """))
    }

    func testActiveRolloutPhaseWinsOverIdleAppServerPhase() {
        XCTAssertTrue(SessionStore.shouldPreferCodexRolloutPhase(.processing, over: .idle))
        XCTAssertTrue(SessionStore.shouldPreferCodexRolloutPhase(.compacting, over: .idle))
        XCTAssertFalse(SessionStore.shouldPreferCodexRolloutPhase(.idle, over: .processing))
        XCTAssertFalse(SessionStore.shouldPreferCodexRolloutPhase(.processing, over: .processing))
    }

    @MainActor
    func testIdleAppServerSessionProcessesNewRolloutTaskWithoutPolling() async throws {
        let store = SessionStore.shared
        let monitor = SessionMonitor()
        let sessionId = "codex-app-rollout-\(UUID().uuidString)"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let rolloutURL = tempDirectory.appendingPathComponent("rollout-\(sessionId).jsonl")
        let initialRollout = """
        {"timestamp":"2026-08-08T01:00:00Z","type":"session_meta","payload":{"id":"\(sessionId)","cwd":"/tmp/ping-island-project","originator":"Codex Desktop","source":"desktop"}}
        {"timestamp":"2026-08-08T01:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-08-08T01:00:02Z","type":"event_msg","payload":{"type":"user_message","message":"finish the first task"}}
        {"timestamp":"2026-08-08T01:00:03Z","type":"event_msg","payload":{"type":"agent_message","phase":"final","message":"The first task is complete."}}
        {"timestamp":"2026-08-08T01:00:04Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        try initialRollout.write(to: rolloutURL, atomically: true, encoding: .utf8)

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Synthetic Codex session",
            preview: "The first task is complete.",
            cwd: "/tmp/ping-island-project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        let watcherDeadline = ContinuousClock.now + .seconds(1)
        while !InterruptWatcherManager.shared.isWatching(sessionId: sessionId),
              ContinuousClock.now < watcherDeadline {
            await Task.yield()
        }
        XCTAssertTrue(InterruptWatcherManager.shared.isWatching(sessionId: sessionId))

        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2026-08-08T01:01:00Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-08-08T01:01:01Z","type":"event_msg","payload":{"type":"user_message","message":"start the second task"}}

        """.utf8))
        try handle.close()

        let phaseDeadline = ContinuousClock.now + .seconds(2)
        var phase = await store.session(for: sessionId)?.phase
        while phase != .processing, ContinuousClock.now < phaseDeadline {
            await Task.yield()
            phase = await store.session(for: sessionId)?.phase
        }

        XCTAssertEqual(phase, .processing)
        withExtendedLifetime(monitor) {}
        InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        await store.process(.sessionArchived(sessionId: sessionId))
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    @MainActor
    func testCodexWatcherStartsBeforeRolloutFileExists() async {
        let store = SessionStore.shared
        let sessionId = "codex-future-rollout-\(UUID().uuidString)"
        let rolloutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("rollout-\(sessionId).jsonl")

        await store.upsertCodexSession(
            sessionId: sessionId,
            name: "Future rollout",
            preview: nil,
            cwd: "/tmp/ping-island-project",
            phase: .idle,
            intervention: nil,
            clientInfo: SessionClientInfo(
                kind: .codexApp,
                profileID: "codex-app",
                name: "Codex App",
                bundleIdentifier: "com.openai.codex",
                sessionFilePath: rolloutURL.path
            )
        )

        let deadline = ContinuousClock.now + .seconds(1)
        while !InterruptWatcherManager.shared.isWatching(sessionId: sessionId),
              ContinuousClock.now < deadline {
            await Task.yield()
        }

        XCTAssertTrue(InterruptWatcherManager.shared.isWatching(sessionId: sessionId))
        InterruptWatcherManager.shared.stopWatching(sessionId: sessionId)
        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCodexHookBridgeProcessingEventsStartTranscriptWatcher() {
        let event = HookEvent(
            sessionId: "codex-cli-session",
            cwd: "/tmp/project",
            event: "UserPromptSubmit",
            status: "thinking",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )

        XCTAssertTrue(SessionMonitor.shouldWatchTranscript(for: event, phase: .idle))
    }

    func testCodexStopEventsStopTranscriptWatcher() {
        let event = HookEvent(
            sessionId: "codex-cli-session",
            cwd: "/tmp/project",
            event: "Stop",
            status: "completed",
            provider: .codex,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", name: "Codex"),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: .hookBridge
        )

        XCTAssertTrue(SessionMonitor.shouldStopWatchingTranscript(for: event))
    }
}
