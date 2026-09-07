import XCTest
@testable import Ping_Island

/// Store-level coverage for several Claude Code sessions sharing one project
/// directory. Restart leftovers must be cleaned up, but sessions that could still
/// be running must survive: reporting activity is not evidence that a sibling has
/// been replaced.
///
/// A leftover and a live sibling are indistinguishable at the instant a new
/// session starts when neither reports a pid — which is every session the Claude
/// desktop app produces. The store waits the leftover out rather than guessing,
/// because guessing the other way made two live agents in one directory delete
/// each other on every hook event.
final class ConcurrentClaudeWorkspaceSessionTests: XCTestCase {

    func testOnlyTheExactSameLocalClaudeProcessIsDeduplicated() {
        let now = Date()
        func session(_ id: String, pid: Int?, ingress: SessionIngress = .hookBridge) -> SessionState {
            SessionState(
                sessionId: id, cwd: "/tmp/shared-project", ingress: ingress,
                pid: pid, phase: .processing, lastActivity: now, createdAt: now
            )
        }
        var duplicate = session("duplicate", pid: 101)
        duplicate.lastActivity = now.addingTimeInterval(-1)
        let sessions = [
            duplicate, session("current", pid: 101), session("independent", pid: 102),
            session("pidless", pid: nil), session("invalid-pid", pid: 0),
            session("remote", pid: 101, ingress: .remoteBridge),
            session("native", pid: 101, ingress: .nativeRuntime)
        ]
        let visible = SessionMonitor.deduplicateSameLocalClaudeProcessSessions(sessions)
        XCTAssertEqual(visible.map(\.sessionId), ["current", "independent", "pidless", "invalid-pid", "remote", "native"])
    }

    func testEqualActivityProcessDedupeIsIndependentOfInputOrder() {
        let now = Date()
        let a = SessionState(sessionId: "a", cwd: "/tmp/project-a", pid: 101, lastActivity: now, createdAt: now)
        let b = SessionState(sessionId: "b", cwd: "/tmp/project-b", pid: 101, lastActivity: now, createdAt: now)
        XCTAssertEqual(SessionMonitor.deduplicateSameLocalClaudeProcessSessions([a, b]).map(\.sessionId), ["a"])
        XCTAssertEqual(SessionMonitor.deduplicateSameLocalClaudeProcessSessions([b, a]).map(\.sessionId), ["a"])
    }

    func testNonClaudeClientSharingAPidIsNotCollapsed() {
        let now = Date()
        let claude = SessionState(sessionId: "claude", cwd: "/tmp/project", pid: 101, lastActivity: now)
        let other = SessionState(
            sessionId: "qwen", cwd: "/tmp/project",
            clientInfo: SessionClientInfo(kind: .custom, profileID: "qwen-code", name: "Qwen Code"),
            pid: 101, lastActivity: now
        )
        XCTAssertEqual(SessionMonitor.deduplicateSameLocalClaudeProcessSessions([claude, other]).count, 2)
    }

    private let clientInfo = SessionClientInfo(kind: .claudeCode, name: "Claude Code")

    private func promptEvent(sessionId: String, cwd: String, pid: Int?, message: String) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: cwd,
            event: "UserPromptSubmit",
            status: "processing",
            provider: .claude,
            clientInfo: clientInfo,
            pid: pid,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: message
        )
    }

    func testConcurrentLiveSessionsInSameWorkspaceRemainIndependent() async {
        let workspace = "/tmp/ping-island-concurrent-\(UUID().uuidString)"
        let firstSessionId = "claude-concurrent-first-\(UUID().uuidString)"
        let secondSessionId = "claude-concurrent-second-\(UUID().uuidString)"
        // The test process itself is a PID that is unambiguously alive.
        let livePid = Int(ProcessInfo.processInfo.processIdentifier)
        let store = SessionStore.shared

        await store.process(.hookReceived(promptEvent(
            sessionId: firstSessionId,
            cwd: workspace,
            pid: livePid,
            message: "First concurrent request"
        )))
        await store.process(.hookReceived(promptEvent(
            sessionId: secondSessionId,
            cwd: workspace,
            pid: livePid,
            message: "Second concurrent request"
        )))

        let first = await store.session(for: firstSessionId)
        let second = await store.session(for: secondSessionId)
        XCTAssertNotNil(
            first,
            "A running Claude session must not be archived because another session started in the same directory"
        )
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.latestHookMessage, "First concurrent request")
        XCTAssertEqual(second?.latestHookMessage, "Second concurrent request")

        await store.process(.sessionArchived(sessionId: firstSessionId))
        await store.process(.sessionArchived(sessionId: secondSessionId))
    }

    func testRestartLeftoverWithoutLiveProcessSurvivesUntilItGoesQuiet() async throws {
        let workspace = "/tmp/ping-island-restart-\(UUID().uuidString)"
        let staleSessionId = "claude-stale-\(UUID().uuidString)"
        let restartedSessionId = "claude-restarted-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(promptEvent(
            sessionId: staleSessionId,
            cwd: workspace,
            pid: nil,
            message: "Before the restart"
        )))
        await store.process(.hookReceived(promptEvent(
            sessionId: restartedSessionId,
            cwd: workspace,
            pid: nil,
            message: "After the restart"
        )))

        let staleSession = await store.session(for: staleSessionId)
        let restarted = await store.session(for: restartedSessionId)
        let stale = try XCTUnwrap(
            staleSession,
            "A session that reported moments ago may still be running, pid or not"
        )
        XCTAssertNotNil(restarted)

        // The leftover is released as soon as its silence proves it: nothing has
        // to happen for that, because a session that really did stop stays quiet.
        XCTAssertTrue(
            SameWorkspaceSessionSupersession.canBeSuperseded(
                stale,
                now: Date().addingTimeInterval(
                    SameWorkspaceSessionSupersession.recentActivityLivenessWindow + 1
                ),
                isProcessAlive: { _, _ in false }
            ),
            "Once it has been quiet past the liveness window, the leftover makes way for its replacement"
        )

        await store.process(.sessionArchived(sessionId: staleSessionId))
        await store.process(.sessionArchived(sessionId: restartedSessionId))
    }

    /// Replayed from a real trace. Two agents working in one directory, neither
    /// reporting a pid, deleted each other from the store on every hook: each
    /// session's next event re-created it — losing its accumulated items — and
    /// archived the sibling in turn. The list held a single row that swapped
    /// identity every few seconds.
    func testConcurrentPidlessSessionsDoNotEvictEachOther() async {
        let workspace = "/tmp/ping-island-pidless-\(UUID().uuidString)"
        let firstSessionId = "claude-pidless-first-\(UUID().uuidString)"
        let secondSessionId = "claude-pidless-second-\(UUID().uuidString)"
        let store = SessionStore.shared

        for round in 1...3 {
            await store.process(.hookReceived(promptEvent(
                sessionId: firstSessionId,
                cwd: workspace,
                pid: nil,
                message: "First, round \(round)"
            )))
            await store.process(.hookReceived(promptEvent(
                sessionId: secondSessionId,
                cwd: workspace,
                pid: nil,
                message: "Second, round \(round)"
            )))

            let first = await store.session(for: firstSessionId)
            let second = await store.session(for: secondSessionId)
            XCTAssertNotNil(first, "Round \(round): the first session kept working and must keep its row")
            XCTAssertNotNil(second, "Round \(round): the second session kept working and must keep its row")
            XCTAssertEqual(first?.latestHookMessage, "First, round \(round)")
            XCTAssertEqual(second?.latestHookMessage, "Second, round \(round)")
        }

        await store.process(.sessionArchived(sessionId: firstSessionId))
        await store.process(.sessionArchived(sessionId: secondSessionId))
    }
}
