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

    func testHoverWithManualAttentionShowsAttentionBeforeActiveDashboard() {
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

    func testActivePreviewExcludesCompletedWaitingForInputSession() {
        let active = makeSession(id: "active", phase: .processing)
        let completed = makeSession(id: "completed", phase: .waitingForInput)

        let sessions = IslandExpandedRouteResolver.activePreviewSessions(from: [completed, active])

        XCTAssertEqual(sessions.map(\.sessionId), ["active"])
    }

    func testActivePreviewIncludesApprovalAndQuestionSessions() {
        let approval = makeSession(
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
        let question = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let sessions = IslandExpandedRouteResolver.activePreviewSessions(from: [approval, question])

        XCTAssertEqual(Set(sessions.map(\.sessionId)), Set(["approval", "question"]))
    }

    func testActivePreviewKeepsExplicitSubagentAlongsideActiveParent() {
        let parent = makeSession(id: "parent", phase: .processing)
        let child = makeSession(
            id: "child",
            phase: .processing,
            parentSessionId: parent.sessionId
        )

        let sessions = IslandExpandedRouteResolver.activePreviewSessions(from: [child, parent])

        XCTAssertEqual(Set(sessions.map(\.sessionId)), Set(["parent", "child"]))
    }

    func testFloatingPinnedListIncludesOnlyActiveAndManualAttentionSessions() {
        let active = makeSession(id: "active", phase: .processing)
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let attention = makeSession(
            id: "question",
            phase: .waitingForInput,
            intervention: makeIntervention(
                id: "question-1",
                kind: .question,
                message: "Need your answer"
            )
        )

        let sessions = IslandExpandedRouteResolver.sessionListSessions(
            surface: .floating,
            trigger: .pinnedList,
            from: [completed, attention, active]
        )

        XCTAssertEqual(Set(sessions.map(\.sessionId)), Set(["active", "question"]))
    }

    func testDockedSessionListKeepsCompletedSessionsAvailableForArchiving() {
        let active = makeSession(id: "active", phase: .processing)
        let completed = makeSession(id: "completed", phase: .waitingForInput)

        let sessions = IslandExpandedRouteResolver.sessionListSessions(
            surface: .docked,
            trigger: .click,
            from: [completed, active]
        )

        XCTAssertEqual(Set(sessions.map(\.sessionId)), Set(["active", "completed"]))
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

    func testDisconnectedTerminalRoutedPromptDoesNotOverrideCompletionNotification() {
        let disconnectedPrompt = makeSession(
            id: "disconnected-prompt",
            phase: .waitingForInput,
            connectionState: .disconnected,
            suppressInAppPromptControls: true
        )
        let completed = makeSession(id: "completed", phase: .waitingForInput)
        let notification = SessionCompletionNotification(session: completed, kind: .completed)

        let route = IslandExpandedRouteResolver.resolve(
            surface: .docked,
            trigger: .notification,
            contentType: .instances,
            sessions: [disconnectedPrompt, completed],
            activeCompletionNotification: notification
        )

        XCTAssertEqual(route, .completionNotification(notification))
    }

    private func makeSession(
        id: String,
        phase: SessionPhase,
        intervention: SessionIntervention? = nil,
        parentSessionId: String? = nil,
        connectionState: SessionConnectionState = .connected,
        suppressInAppPromptControls: Bool = false
    ) -> SessionState {
        SessionState(
            sessionId: id,
            cwd: "/tmp/\(id)",
            connectionState: connectionState,
            suppressInAppPromptControls: suppressInAppPromptControls,
            intervention: intervention,
            codexParentThreadId: parentSessionId,
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
