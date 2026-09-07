import Combine
import Foundation
import XCTest
@testable import Ping_Island

final class SessionMonitorCodexWatcherTests: XCTestCase {
    func testDeferredImmediateRefreshReadsNewTaskAfterInFlightParseFinishes() async throws {
        let store = SessionStore.shared
        let id = "codex-deferred-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rollout = directory.appendingPathComponent("rollout-\(id).jsonl")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let initial = """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(id)","cwd":"\(directory.path)","originator":"codex_cli_rs","source":"cli"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"task_complete","turn_id":"old-turn","last_agent_message":"Previous reply"}}
        """ + "\n"
        try initial.write(to: rollout, atomically: true, encoding: .utf8)
        let client = SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", sessionFilePath: rollout.path)
        let oldSnapshot = await CodexRolloutParser.shared.parseThread(
            threadId: id, fallbackCwd: directory.path, clientInfo: client
        )
        XCTAssertNotNil(oldSnapshot)
        await store.upsertCodexSession(
            sessionId: id, name: "Deferred watcher", preview: "Previous reply", cwd: directory.path,
            phase: .idle, intervention: nil, clientInfo: client
        )
        let reserved = await store.reserveCodexRolloutParseIfNeeded(
            sessionId: id, hasAppServerSnapshot: false, bypassParseThrottle: true
        )
        XCTAssertTrue(reserved)
        let processing = expectation(description: "Deferred watcher refresh sees the new running turn")
        let subscription = store.sessionsPublisher.sink { sessions in
            if sessions.contains(where: { $0.sessionId == id && $0.phase == .processing }) {
                processing.fulfill()
            }
        }
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        let started = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"task_started","turn_id":"new-turn"}}"# + "\n"
        try handle.write(contentsOf: Data(started.utf8))
        try handle.close()
        await store.requestFileSync(for: id, forceCodexRolloutParse: true)
        await store.requestFileSync(for: id) // A routine sync must not discard the forced edge.
        await store.finishCodexRolloutParse(sessionId: id)
        await fulfillment(of: [processing], timeout: 3)
        subscription.cancel()
        let refreshed = await store.session(for: id)
        XCTAssertEqual(refreshed?.phase, .processing)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testForcedRolloutParseBypassesRecentParseThrottle() async {
        let store = SessionStore.shared
        let id = "codex-throttle-\(UUID().uuidString)"
        await store.upsertCodexSession(
            sessionId: id, name: "Throttle", preview: nil, cwd: "/tmp/\(id)",
            phase: .idle, intervention: nil, clientInfo: SessionClientInfo.codexCLI()
        )
        let first = await store.reserveCodexRolloutParseIfNeeded(
            sessionId: id, hasAppServerSnapshot: true, bypassParseThrottle: false
        )
        XCTAssertTrue(first)
        await store.finishCodexRolloutParse(sessionId: id)
        let throttled = await store.reserveCodexRolloutParseIfNeeded(
            sessionId: id, hasAppServerSnapshot: true, bypassParseThrottle: false
        )
        XCTAssertFalse(throttled)
        let forced = await store.reserveCodexRolloutParseIfNeeded(
            sessionId: id, hasAppServerSnapshot: true, bypassParseThrottle: true
        )
        XCTAssertTrue(forced)
        await store.finishCodexRolloutParse(sessionId: id)
        await store.process(.sessionArchived(sessionId: id))
    }

    func testRolloutActivePhaseOutranksAnIdleAppServerSnapshot() {
        XCTAssertTrue(SessionStore.shouldPreferCodexRolloutPhase(.processing, over: .idle))
        XCTAssertTrue(SessionStore.shouldPreferCodexRolloutPhase(.compacting, over: .idle))
        XCTAssertFalse(SessionStore.shouldPreferCodexRolloutPhase(.idle, over: .processing))
        XCTAssertFalse(SessionStore.shouldPreferCodexRolloutPhase(.processing, over: .processing))
    }

    func testIdleCodexRolloutWatcherIsStoppedOnRealArchive() async throws {
        let store = SessionStore.shared
        let id = "codex-idle-watcher-\(UUID().uuidString)"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).jsonl")
        try "{}\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        await store.upsertCodexSession(
            sessionId: id, name: "Idle watcher", preview: nil, cwd: "/tmp/\(id)",
            phase: .idle, intervention: nil,
            clientInfo: SessionClientInfo(kind: .codexCLI, profileID: "codex-cli", sessionFilePath: file.path)
        )
        // Drain the main-actor watcher command that the store schedules.
        var isWatching = false
        for _ in 0..<100 {
            isWatching = await MainActor.run { InterruptWatcherManager.shared.isWatching(sessionId: id) }
            if isWatching { break }
            await Task.yield()
        }
        XCTAssertTrue(isWatching, "Idle rollouts must still detect the next task_started record")
        await store.process(.sessionArchived(sessionId: id))
        for _ in 0..<100 {
            isWatching = await MainActor.run { InterruptWatcherManager.shared.isWatching(sessionId: id) }
            if !isWatching { break }
            await Task.yield()
        }
        XCTAssertFalse(isWatching, "Only a real removal tears down the retained rollout watcher")
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
