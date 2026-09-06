import Darwin
import Foundation
import XCTest
@testable import Ping_Island

/// Tests for the periodic liveness sweep introduced by
/// `fix-claude-sound-triggers`. The sweep removes sessions whose tracked pid
/// is no longer alive (Ctrl-C, OOM, terminal closed) and garbage-collects
/// sessions already in `.ended` phase.
final class SessionStoreLivenessSweepTests: XCTestCase {

    func testSweepRemovesSessionWithDeadPid() async throws {
        let deadPid = try makeDeadPID()

        let sessionId = "liveness-dead-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: deadPid
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertNotNil(beforeSweep, "Session must exist before sweep")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, "Session with dead pid must be removed by the sweep")
    }

    func testSweepLeavesRemoteSessionWithForeignDeadPidAlone() async throws {
        let deadPid = try makeDeadPID()
        let sessionId = "liveness-remote-dead-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: deadPid,
            ingress: .remoteBridge
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(
            afterSweep,
            "A remote pid belongs to the remote host and must not be checked in the Mac process namespace"
        )

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testNewRemoteSessionDoesNotArchiveExistingRemoteSessionInSameWorkspace() async throws {
        let deadPid = try makeDeadPID()
        let firstSessionId = "liveness-remote-first-\(UUID().uuidString)"
        let secondSessionId = "liveness-remote-second-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: firstSessionId,
            pid: deadPid,
            ingress: .remoteBridge
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: firstSessionId,
            pid: deadPid,
            event: "Stop",
            status: "idle",
            ingress: .remoteBridge
        )))

        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: secondSessionId,
            pid: deadPid,
            event: "SessionStart",
            status: "waiting_for_input",
            ingress: .remoteBridge
        )))

        let firstSession = await store.session(for: firstSessionId)
        let secondSession = await store.session(for: secondSessionId)
        XCTAssertNotNil(
            firstSession,
            "A second remote session must not archive another remote session using a Mac-side pid check"
        )
        XCTAssertNotNil(secondSession)

        await store.process(.sessionArchived(sessionId: firstSessionId))
        await store.process(.sessionArchived(sessionId: secondSessionId))
    }

    func testRemoteDisconnectRemovesSessionFromActiveAndAttentionState() async {
        let sessionId = "remote-disconnect-\(UUID().uuidString)"
        let endpointID = UUID()
        let store = SessionStore.shared
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: nil,
            ingress: .remoteBridge,
            remoteHost: "worker-01",
            remoteEndpointID: endpointID
        )))

        await store.markRemoteSessionsDisconnected(
            endpointID: endpointID,
            legacyRemoteHost: "different-alias"
        )

        let disconnected = await store.session(for: sessionId)
        XCTAssertEqual(disconnected?.connectionState, .disconnected)
        XCTAssertFalse(disconnected?.isExecutionActive ?? true)
        XCTAssertFalse(disconnected?.needsManualAttention ?? true)
        XCTAssertEqual(disconnected.map(MascotStatus.init(session:)), .idle)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSweepRemovesEndedSession() async {
        let sessionId = "liveness-ended-\(UUID().uuidString)"
        let store = SessionStore.shared

        // Use a real SessionEnd hook to drive the session into `.ended` phase
        // (the only public way to invoke markSessionEnded).
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "UserPromptSubmit",
            status: "processing"
        )))
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid()),
            event: "SessionEnd",
            status: "ended"
        )))

        let beforeSweep = await store.session(for: sessionId)
        XCTAssertEqual(beforeSweep?.phase, .ended,
                       "Test setup precondition: session must reach .ended phase")

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNil(afterSweep, ".ended sessions must be garbage-collected by the sweep")
    }

    func testSweepLeavesSessionWithoutPidAlone() async {
        let sessionId = "liveness-nopid-\(UUID().uuidString)"
        let store = SessionStore.shared

        // pid: nil means we cannot assert the process is dead.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: nil
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Sessions without a tracked pid must NOT be removed on liveness grounds")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSweepLeavesLiveSessionAlone() async {
        let sessionId = "liveness-live-\(UUID().uuidString)"
        let store = SessionStore.shared

        // getpid() is the test runner itself — guaranteed alive, phase != .ended.
        await store.process(.hookReceived(makeClaudeEvent(
            sessionId: sessionId,
            pid: Int(getpid())
        )))

        await store.sweepDeadOrEndedSessions()

        let afterSweep = await store.session(for: sessionId)
        XCTAssertNotNil(afterSweep,
                        "Live, non-ended sessions must be untouched by the sweep")

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    // MARK: - Helpers

    private func makeClaudeEvent(
        sessionId: String,
        pid: Int?,
        event: String = "UserPromptSubmit",
        status: String = "processing",
        ingress: SessionIngress = .hookBridge,
        remoteHost: String? = nil,
        remoteEndpointID: UUID? = nil
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
                bundleIdentifier: "com.anthropic.claudecode",
                remoteHost: remoteHost,
                remoteEndpointID: remoteEndpointID
            ),
            pid: pid,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: ingress
        )
    }

    private func makeDeadPID() throws -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()

        let deadPid = Int(process.processIdentifier)
        XCTAssertGreaterThan(deadPid, 0)
        XCTAssertTrue(
            Darwin.kill(pid_t(deadPid), 0) != 0 && errno == ESRCH,
            "Test setup precondition: spawned pid must be dead before the sweep runs"
        )
        return deadPid
    }
}
