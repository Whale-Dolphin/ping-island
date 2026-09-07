import Combine
import Foundation
import XCTest
@testable import Ping_Island

/// Exercise the shared queue/registry without launching either UI surface.
@MainActor
final class SessionCompletionNotificationQueueTests: XCTestCase {
    func testBlockedPanelDoesNotConsumeOrExpireCapturedCompletion() throws {
        let registry = SessionCompletionNotificationRegistry()
        let completed = session(turn: "turn-1", text: "First result")
        let notification = SessionCompletionNotification(session: completed, kind: .completed, queuedAt: capturedAt)
        registry.enqueue(notification)

        XCTAssertNil(registry.dequeueNext(in: [completed], isPresentationBlocked: true))
        XCTAssertEqual(registry.pendingNotifications, [notification])
        XCTAssertFalse(registry.isConsumed(notification))
        XCTAssertFalse(SessionCompletionNotificationPolicy.hasRecentNotificationActivity(
            completed, now: capturedAt.addingTimeInterval(3_600)
        ))

        // Recency gates capture, not delayed presentation after a panel closes.
        let shown = try XCTUnwrap(registry.dequeueNext(in: [completed], isPresentationBlocked: false))
        XCTAssertEqual(shown, notification)
        XCTAssertTrue(registry.isConsumed(notification))
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    func testOtherExecutionOrManualAttentionDefersWithoutConsuming() throws {
        let registry = SessionCompletionNotificationRegistry()
        let completed = session(turn: "turn-1", text: "First result")
        let notification = SessionCompletionNotification(session: completed, kind: .completed)
        registry.enqueue(notification)
        var blocker = SessionState(
            sessionId: "other-session", cwd: "/synthetic/workspaces/other", phase: .processing
        )

        for phase in [SessionPhase.processing, .compacting, .waitingForApproval(PermissionContext(
            toolUseId: "tool", toolName: "Read", toolInput: nil, receivedAt: capturedAt
        ))] {
            blocker.phase = phase
            XCTAssertNil(registry.dequeueNext(in: [completed, blocker], isPresentationBlocked: false))
            XCTAssertFalse(registry.isConsumed(notification))
            XCTAssertEqual(registry.pendingNotifications, [notification])
        }
        blocker.phase = .waitingForInput
        blocker.intervention = SessionIntervention(
            id: "question", kind: .question, title: "Choose", message: "Choose a target",
            options: [], questions: [], supportsSessionScope: false, metadata: [:]
        )
        XCTAssertNil(registry.dequeueNext(in: [completed, blocker], isPresentationBlocked: false))
        XCTAssertFalse(registry.isConsumed(notification))

        blocker.intervention = nil
        XCTAssertEqual(
            try XCTUnwrap(registry.dequeueNext(in: [completed, blocker], isPresentationBlocked: false)),
            notification
        )
    }

    func testPendingSnapshotAndKeySurviveNewActivityOnSameSession() throws {
        let registry = SessionCompletionNotificationRegistry()
        let first = session(turn: "turn-1", text: "First result")
        let notification = SessionCompletionNotification(session: first, kind: .completed, queuedAt: capturedAt)
        let capturedKey = try XCTUnwrap(notification.completionKey)
        registry.enqueue(notification)

        var latest = session(turn: "turn-2", text: "Second turn is working")
        latest.phase = .processing
        latest.chatItems.append(ChatHistoryItem(
            id: "new-user", type: .user("Start another task"), timestamp: capturedAt.addingTimeInterval(1)
        ))
        latest.lastActivity = capturedAt.addingTimeInterval(600)
        registry.synchronizePendingNotifications()
        XCTAssertNil(registry.dequeueNext(in: [latest], isPresentationBlocked: false))
        let pending = try XCTUnwrap(registry.pendingNotifications.first)
        XCTAssertEqual(pending.session, first)
        XCTAssertEqual(pending.completionKey, capturedKey)
        XCTAssertEqual(SessionCompletionPreviewBuilder.latestAssistantText(for: pending.session), "First result")
        XCTAssertFalse(registry.isConsumed(pending))

        let second = session(turn: "turn-2", text: "Second result")
        registry.enqueue(SessionCompletionNotification(session: second, kind: .completed))
        registry.synchronizePendingNotifications()
        XCTAssertEqual(registry.pendingNotifications.count, 2)

        let shown = try XCTUnwrap(registry.dequeueNext(in: [second], isPresentationBlocked: false))
        XCTAssertEqual(shown.session, first)
        XCTAssertEqual(shown.completionKey, capturedKey)
        registry.markConsumed(shown) // Dismissal is idempotent and uses the captured key.
        XCTAssertTrue(registry.isConsumed(session: first))
        XCTAssertFalse(registry.isConsumed(session: second))
        XCTAssertEqual(
            try XCTUnwrap(registry.dequeueNext(in: [second], isPresentationBlocked: false)).session,
            second
        )
    }

    func testReplayDeduplicatesByCompletionKeyWithoutReplacingSnapshot() throws {
        let registry = SessionCompletionNotificationRegistry()
        let first = session(turn: "turn-1", text: "Captured result")
        let notification = SessionCompletionNotification(session: first, kind: .completed, queuedAt: capturedAt)
        var refreshed = first
        refreshed.sessionName = "Refreshed metadata"
        refreshed.lastActivity = capturedAt.addingTimeInterval(900)
        refreshed.chatItems[1] = ChatHistoryItem(
            id: "turn-1-assistant", type: .assistant("Replayed text"), timestamp: refreshed.lastActivity
        )
        let replay = SessionCompletionNotification(session: refreshed, kind: .completed)
        XCTAssertNotEqual(notification.id, replay.id)
        XCTAssertEqual(notification.completionKey, replay.completionKey)

        registry.enqueue(notification)
        registry.enqueue(replay)
        registry.synchronizePendingNotifications()
        XCTAssertEqual(registry.pendingNotifications, [notification])
        XCTAssertEqual(
            try XCTUnwrap(registry.dequeueNext(in: [refreshed], isPresentationBlocked: false)),
            notification
        )
    }

    func testTwoSurfacesSharePendingQueueAndClaimACompletionOnlyOnce() throws {
        let registry = SessionCompletionNotificationRegistry()
        let docked = registry
        let floating = registry
        let completed = session(turn: "turn-1", text: "Docked result")
        let notification = SessionCompletionNotification(session: completed, kind: .completed)
        docked.enqueue(notification)
        XCTAssertNil(docked.dequeueNext(in: [completed], isPresentationBlocked: true))

        // The new surface uses the same registry, not a new view-local queue.
        floating.enqueue(SessionCompletionNotification(session: completed, kind: .completed))
        XCTAssertEqual(try XCTUnwrap(floating.dequeueNext(in: [completed], isPresentationBlocked: false)), notification)
        XCTAssertNil(docked.dequeueNext(in: [completed], isPresentationBlocked: false))
        floating.markConsumed(notification)
        docked.markConsumed(notification)
        docked.enqueue(SessionCompletionNotification(session: completed, kind: .completed))
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
        XCTAssertTrue(registry.isConsumed(session: completed))
    }

    func testPendingCompletionSurvivesRemovalFromVisibleSessionList() throws {
        let registry = SessionCompletionNotificationRegistry()
        let notification = SessionCompletionNotification(session: session(turn: "turn-1", text: "Saved result"), kind: .completed)
        registry.enqueue(notification)
        registry.synchronizePendingNotifications()
        XCTAssertEqual(try XCTUnwrap(registry.dequeueNext(in: [], isPresentationBlocked: false)), notification)
    }

    func testDifferentTurnsAtSameActivityTimeAndDifferentKindsRemainDistinct() throws {
        let registry = SessionCompletionNotificationRegistry()
        let first = SessionCompletionNotification(session: session(turn: "turn-1", text: "First"), kind: .completed)
        let second = SessionCompletionNotification(session: session(turn: "turn-2", text: "Second"), kind: .completed)
        var endedSession = second.session
        endedSession.phase = .ended
        let ended = SessionCompletionNotification(session: endedSession, kind: .ended)
        XCTAssertEqual(first.session.lastActivity, second.session.lastActivity)
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertNotEqual(second.identity, ended.identity)
        [first, second, ended].forEach(registry.enqueue)
        XCTAssertEqual(registry.pendingNotifications.count, 3)
        for expected in [first, second, ended] {
            XCTAssertEqual(try XCTUnwrap(registry.dequeueNext(in: [], isPresentationBlocked: false)), expected)
        }
    }

    func testDisconnectedExecutionDoesNotHoldTheQueue() throws {
        let registry = SessionCompletionNotificationRegistry()
        let notification = SessionCompletionNotification(session: session(turn: "turn-1", text: "Result"), kind: .completed)
        var disconnected = SessionState(
            sessionId: "disconnected", cwd: "/synthetic/workspaces/remote", phase: .processing
        )
        disconnected.connectionState = .disconnected
        registry.enqueue(notification)
        XCTAssertEqual(try XCTUnwrap(registry.dequeueNext(in: [disconnected], isPresentationBlocked: false)), notification)
    }

    func testNotchCompletionDeliveryUsesPostPublishedMonitorSnapshot() {
        let monitor = SessionMonitor(observeSharedState: false)
        let registry = SessionCompletionNotificationRegistry()
        let completed = session(turn: "turn-1", text: "Only completion update")
        var processing = completed
        processing.phase = .processing
        monitor.instances = [processing]
        let delivered = expectation(description: "completion delivered after Published storage updates")
        var didDeliver = false
        let subscription = NotchSessionSnapshotDelivery.publisher(for: monitor)
            .dropFirst()
            .sink { snapshots in
                didDeliver = true
                XCTAssertEqual(monitor.instances, snapshots)
                let notification = SessionCompletionNotification(session: snapshots[0], kind: .completed)
                registry.enqueue(notification)
                XCTAssertEqual(
                    registry.dequeueNext(in: monitor.instances, isPresentationBlocked: false),
                    notification
                )
                delivered.fulfill()
            }
        defer { subscription.cancel() }

        monitor.instances = [completed]
        XCTAssertFalse(didDeliver, "willSet must not synchronously run the notch dequeue")
        wait(for: [delivered], timeout: 1)
        XCTAssertTrue(registry.pendingNotifications.isEmpty)
    }

    func testLifecycleFallbackDistinguishesRecreationButNotMetadataRefresh() throws {
        let firstIncarnation = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondIncarnation = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        for kind in [SessionCompletionNotification.Kind.ended, .compacted] {
            let registry = SessionCompletionNotificationRegistry()
            let original = SessionState(
                sessionId: "recreated-session", cwd: "/synthetic/workspaces/recreated",
                phase: kind == .ended ? .ended : .processing,
                lastActivity: capturedAt, createdAt: capturedAt,
                lifecycleIncarnationID: firstIncarnation
            )
            let first = SessionCompletionNotification(session: original, kind: kind)
            registry.markConsumed(first)
            var refreshed = original
            refreshed.createdAt = capturedAt.addingTimeInterval(-100)
            refreshed.lastActivity = capturedAt.addingTimeInterval(100)
            let replay = SessionCompletionNotification(session: refreshed, kind: kind)
            XCTAssertEqual(replay.identity, first.identity)
            XCTAssertTrue(registry.isConsumed(replay))

            let recreated = SessionState(
                sessionId: original.sessionId, cwd: original.cwd, phase: original.phase,
                lastActivity: capturedAt, createdAt: capturedAt,
                lifecycleIncarnationID: secondIncarnation
            )
            let later = SessionCompletionNotification(session: recreated, kind: kind)
            XCTAssertEqual(recreated.completionSequence, original.completionSequence)
            XCTAssertNotEqual(later.identity, first.identity)
            XCTAssertFalse(registry.isConsumed(later))
            registry.enqueue(later)
            XCTAssertEqual(registry.dequeueNext(in: [], isPresentationBlocked: false), later)
        }
    }

    func testCompletedTurnIdentityDoesNotIncludeLifecycleIncarnation() throws {
        let first = session(turn: "canonical-turn", text: "Result")
        let otherIncarnation = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let recreated = SessionState(
            sessionId: first.sessionId, cwd: first.cwd, provider: first.provider,
            clientInfo: first.clientInfo, phase: first.phase, chatItems: first.chatItems,
            latestTurnId: first.latestTurnId, lastActivity: first.lastActivity,
            createdAt: first.createdAt, lifecycleIncarnationID: otherIncarnation
        )
        XCTAssertEqual(SessionCompletionKey.make(for: first), SessionCompletionKey.make(for: recreated))
        XCTAssertEqual(
            SessionCompletionNotification(session: first, kind: .completed).identity,
            SessionCompletionNotification(session: recreated, kind: .completed).identity
        )
    }

    private let capturedAt = Date(timeIntervalSince1970: 100)

    private func session(turn: String, text: String) -> SessionState {
        SessionState(
            sessionId: "queue-session",
            cwd: "/synthetic/workspaces/project",
            provider: .codex,
            clientInfo: SessionClientInfo.codexApp(threadId: "queue-session"),
            phase: .idle,
            chatItems: [
                ChatHistoryItem(id: "\(turn)-user", type: .user("Complete this task"), timestamp: capturedAt),
                ChatHistoryItem(id: "\(turn)-assistant", type: .assistant(text), timestamp: capturedAt)
            ],
            latestTurnId: turn,
            lastActivity: capturedAt,
            createdAt: capturedAt
        )
    }
}
