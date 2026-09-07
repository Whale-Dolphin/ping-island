import XCTest
@testable import Ping_Island

final class IslandExpandedRouteResolverTests: XCTestCase {
    func testClickResolvesToSessionList() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .sessionList)
    }

    func testClickWithManualAttentionResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .click,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testHoverWithoutManualAttentionResolvesToHoverDashboard() {
        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing)]
        )

        XCTAssertEqual(route, .hoverDashboard)
    }

    func testHoverWithManualAttentionResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .hover,
            contentType: .instances,
            sessions: [makeSession(id: "active", phase: .processing), attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testDockedNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    func testDockedNotificationWithApprovalResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testNotificationAttentionOverridesPreviouslyOpenChat() {
        let staleChat = makeSession(id: "stale-chat", phase: .processing)
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .chat(staleChat),
            sessions: [staleChat, attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testFloatingNotificationWithApprovalResolvesToAttentionNotification() {
        let attention = makeSession(
            id: "approval",
            phase: .waitingForApproval(
                PermissionContext(
                    toolUseId: "tool-1",
                    toolName: "Bash",
                    toolInput: nil,
                    receivedAt: Date()
                )
            )
        )

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [attention]
        )

        XCTAssertEqual(route, .attentionNotification(attention))
    }

    func testFloatingNotificationWithCompletionResolvesToCompletionNotification() {
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: .notification,
            contentType: .instances,
            sessions: [completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    func testFloatingPreviewsExcludeCompletedWaitingIdleEndedAndDisconnectedSessions() {
        let active = makeSession(id: "active", phase: .processing)
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let idle = makeSession(id: "idle", phase: .idle)
        let ended = makeSession(id: "ended", phase: .ended)
        var disconnected = makeSession(id: "disconnected", phase: .processing)
        disconnected.connectionState = .disconnected

        let sessions = [completed, active, idle, ended, disconnected]
        XCTAssertEqual(
            IslandExpandedRouteResolver.activePreviewSessions(from: sessions).map(\.sessionId),
            ["active"]
        )
        for trigger in [IslandExpandedTrigger.pinnedList, .click] {
            XCTAssertEqual(
                IslandExpandedRouteResolver.sessionListSessions(
                    surface: .floating, trigger: trigger, from: sessions
                ).map(\.sessionId),
                ["active"]
            )
        }
    }

    func testFloatingPreviewRetainsEveryActiveSessionAndExplicitSubagent() {
        var sessions = (1...5).map { makeSession(id: "active-\($0)", phase: .processing) }
        var child = makeSession(id: "child", phase: .processing)
        child.codexParentThreadId = sessions[0].sessionId
        sessions.append(child)

        XCTAssertEqual(
            Set(IslandExpandedRouteResolver.activePreviewSessions(from: sessions).map(\.sessionId)),
            Set(sessions.map(\.sessionId))
        )
    }

    func testFloatingPinnedListRetainsApprovalAndQuestionSessions() {
        let approval = makeSession(
            id: "approval", phase: .waitingForApproval(PermissionContext(
                toolUseId: "approval-tool", toolName: "Read", toolInput: nil, receivedAt: Date()
            ))
        )
        let question = makeSession(
            id: "question", phase: .waitingForInput,
            intervention: makeIntervention(id: "question-1", kind: .question, message: "Choose a target")
        )
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let sessions = IslandExpandedRouteResolver.sessionListSessions(
            surface: .floating, trigger: .pinnedList, from: [completed, approval, question]
        )
        XCTAssertEqual(Set(sessions.map(\.sessionId)), Set(["approval", "question"]))
    }

    func testDockedListKeepsCompletedAndEndedSessionsForArchiving() {
        let sessions = [
            makeSession(id: "active", phase: .processing),
            makeSession(id: "completed", phase: .waitingForInput),
            makeSession(id: "ended", phase: .ended)
        ]
        XCTAssertEqual(
            Set(IslandExpandedRouteResolver.sessionListSessions(
                surface: .docked, trigger: .click, from: sessions
            ).map(\.sessionId)),
            Set(["active", "completed", "ended"])
        )
    }

    func testDisconnectedPromptDoesNotOverrideCapturedCompletion() {
        var disconnected = makeSession(
            id: "disconnected", phase: .waitingForInput,
            intervention: makeIntervention(id: "question-1", kind: .question, message: "Choose a target")
        )
        disconnected.connectionState = .disconnected
        disconnected.suppressInAppPromptControls = true
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)
        for surface in [IslandExpandedSurface.docked, .floating] {
            XCTAssertEqual(
                IslandExpandedRouteResolver.resolve(
                    surface: surface, trigger: .notification, contentType: .instances,
                    sessions: [disconnected, completed], activeCompletionNotification: notification
                ),
                .completionNotification(notification)
            )
        }
    }

    func testFloatingPinnedListKeepsConnectedTerminalRoutedPrompt() {
        var prompt = makeSession(id: "terminal-prompt", phase: .waitingForInput)
        prompt.suppressInAppPromptControls = true
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        XCTAssertTrue(prompt.needsPromptNotification)
        XCTAssertFalse(prompt.needsManualAttention)
        XCTAssertEqual(
            IslandExpandedRouteResolver.sessionListSessions(
                surface: .floating, trigger: .pinnedList, from: [completed, prompt]
            ).map(\.sessionId),
            [prompt.sessionId]
        )
        prompt.connectionState = .disconnected
        XCTAssertTrue(IslandExpandedRouteResolver.activePreviewSessions(from: [completed, prompt]).isEmpty)
    }

    @MainActor
    func testKeyboardSnapshotDropsArchivedRowsAndUsesCurrentOrdering() {
        let monitor = SessionMonitor(observeSharedState: false)
        var first = makeSession(id: "first", phase: .processing)
        var second = makeSession(id: "second", phase: .processing)
        first.lastActivity = Date(timeIntervalSince1970: 2)
        second.lastActivity = Date(timeIntervalSince1970: 1)
        monitor.instances = [first, second]
        // Like the NSEvent handler, this closure outlives its initial list render.
        let currentRows = { SessionListKeyboardNavigation.sessions(from: monitor) }
        XCTAssertEqual(currentRows().map(\.sessionId), ["first", "second"])

        second.lastActivity = Date(timeIntervalSince1970: 3)
        monitor.instances = [first, second]
        XCTAssertEqual(currentRows().map(\.sessionId), ["second", "first"])
        XCTAssertEqual(SessionListKeyboardNavigation.movedSelection(
            from: nil, delta: 1, in: currentRows()
        ), second.stableId)

        monitor.instances = [second]
        XCTAssertNil(SessionListKeyboardNavigation.selectedSession(stableID: first.stableId, in: currentRows()))
        XCTAssertEqual(SessionListKeyboardNavigation.selectedSession(stableID: second.stableId, in: currentRows()), second)
    }

    @MainActor
    func testKeyboardSnapshotMatchesCurrentParentSubagentGrouping() {
        let monitor = SessionMonitor(observeSharedState: false)
        var parent = makeSession(id: "parent", phase: .processing)
        var child = makeSession(id: "child", phase: .processing)
        child.codexParentThreadId = parent.sessionId
        var other = makeSession(id: "other", phase: .processing)
        parent.lastActivity = Date(timeIntervalSince1970: 1)
        child.lastActivity = Date(timeIntervalSince1970: 3)
        other.lastActivity = Date(timeIntervalSince1970: 2)
        monitor.instances = [parent, child, other]
        let rows = SessionListKeyboardNavigation.sessions(from: monitor)
        let rendered = PrimarySessionGroup.groups(from: IslandExpandedRouteResolver.orderedSessions(from: monitor.instances))
            .flatMap { [$0.session] + $0.childSessions }
        XCTAssertEqual(rows, rendered)
        XCTAssertEqual(SessionListKeyboardNavigation.movedSelection(from: parent.stableId, delta: 1, in: rows), child.stableId)
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            intervention: intervention,
            phase: phase
        )
    }

    private func makeIntervention(
        id: String,
        kind: SessionInterventionKind,
        message: String
    ) -> SessionIntervention {
        SessionIntervention(
            id: id,
            kind: kind,
            title: message,
            message: message,
            options: [],
            questions: [],
            supportsSessionScope: false,
            metadata: [:]
        )
    }
}
