import SwiftUI

struct IslandOpenedContentView: View {
    let sessionMonitor: SessionMonitor
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared
    let surface: IslandExpandedSurface
    let trigger: IslandExpandedTrigger
    let style: IslandOpenedPresentationStyle
    let activeCompletionNotification: SessionCompletionNotification?
    var highlightedSessionStableID: String? = nil
    var contentWidthOverride: CGFloat? = nil
    var sessionListDensity: SessionListDensity = .regular
    var maximumContentHeight: CGFloat? = nil
    let onAttentionActionCompleted: () -> Void
    let onCompletionNotificationHoverChanged: (Bool) -> Void
    let onDismissCompletionNotification: () -> Void

    var body: some View {
        routeContent
        .frame(width: contentWidth)
        .onAppear {
            sessionMonitor.refreshUsageState()
        }
    }

    private var route: IslandExpandedRoute {
        IslandExpandedRouteResolver.resolve(
            surface: surface,
            trigger: trigger,
            contentType: viewModel.contentType,
            sessions: sessionMonitor.instances,
            activeCompletionNotification: activeCompletionNotification
        )
    }

    private var hoverPreviewSessions: [SessionState] {
        IslandExpandedRouteResolver.activePreviewSessions(from: sessionMonitor.instances)
    }

    @ViewBuilder
    private var routeContent: some View {
        switch route {
        case .sessionList:
            SessionListView(
                sessions: IslandExpandedRouteResolver.sessionListSessions(
                    surface: surface,
                    trigger: trigger,
                    from: sessionMonitor.instances
                ),
                sessionMonitor: sessionMonitor,
                viewModel: viewModel,
                density: sessionListDensity,
                constrainsHeight: surface == .floating,
                enableKeyboardNavigation: surface == .docked,
                highlightedSessionStableID: highlightedSessionStableID
            )
        case .hoverDashboard:
            SessionHoverDashboardView(
                sessions: hoverPreviewSessions,
                sessionMonitor: sessionMonitor,
                density: surface == .floating ? .detachedCompact : .regular,
                hidesSessionPreviews: surface == .floating
                    && DetachedIslandContentModel.hoverDashboardUsesCondensedRows(
                        for: hoverPreviewSessions,
                        viewModel: viewModel,
                        maximumContentHeight: maximumContentHeight
                    ),
                onQuestionInteractionStateChanged: { viewModel.setInlineTextInputActive($0) }
            )
        case .attentionNotification(let session):
            SessionAttentionNotificationView(
                session: liveSession(for: session),
                sessionMonitor: sessionMonitor,
                density: surface == .floating ? .detachedCompact : .regular,
                suppressInAppPromptControls: settings.effectiveRoutePromptsToTerminal,
                onQuestionInteractionStateChanged: { viewModel.setInlineTextInputActive($0) },
                onActionCompleted: onAttentionActionCompleted
            )
        case .completionNotification(let notification):
            if surface == .floating {
                ScrollView(.vertical, showsIndicators: true) {
                    completionContent(notification)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                completionContent(notification)
            }
        case .chat(let session):
            let liveSession = liveSession(for: session)

            if liveSession.provider == .claude || liveSession.provider == .kimi {
                ChatView(
                    sessionId: liveSession.sessionId,
                    initialSession: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            } else {
                CodexSessionView(
                    session: liveSession,
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel
                )
            }
        }
    }

    private func completionContent(_ notification: SessionCompletionNotification) -> some View {
        SessionCompletionNotificationView(
            notification: notification,
            presentationStyle: style == .detached ? .bubble : .panel,
            onHoverChanged: onCompletionNotificationHoverChanged,
            onDismiss: onDismissCompletionNotification
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: OpenedPanelContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
    }

    private func liveSession(for session: SessionState) -> SessionState {
        sessionMonitor.instances.first(where: { $0.sessionId == session.sessionId }) ?? session
    }

    private var contentWidth: CGFloat {
        if let contentWidthOverride {
            return contentWidthOverride
        }

        switch style {
        case .docked:
            return viewModel.openedSize.width - 24
        case .detached:
            return viewModel.detachedSize.width - 24
        }
    }
}
