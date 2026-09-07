import SwiftUI

private struct SessionCompletionContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

nonisolated struct SessionCompletionNotification: Equatable, Identifiable {
    enum Kind: String, Hashable, Sendable {
        case completed
        case ended
        case compacted

        var statusLabelKey: String {
            switch self {
            case .completed:
                return "完成"
            case .ended:
                return "结束"
            case .compacted:
                return "已压缩"
            }
        }

        var fallbackAssistantMessageKey: String {
            switch self {
            case .completed:
                return "会话已完成，点击查看完整结果。"
            case .ended:
                return "会话已结束"
            case .compacted:
                return "上下文已压缩"
            }
        }

        var usesAssistantPreview: Bool {
            switch self {
            case .completed, .ended:
                return true
            case .compacted:
                return false
            }
        }
    }

    enum Identity: Hashable {
        case completed(SessionCompletionKey)
        // End/compaction events have no completed-turn key. Use captured lifecycle
        // identifiers, never lastActivity (metadata polling changes that timestamp).
        case lifecycle(kind: Kind, sessionID: String, incarnationID: UUID, turnID: String?, sequence: UInt64, itemID: String?)
    }

    let id: UUID
    let session: SessionState
    let kind: Kind
    let queuedAt: Date
    let completionKey: SessionCompletionKey?
    let identity: Identity

    init(
        id: UUID = UUID(),
        session: SessionState,
        kind: Kind,
        queuedAt: Date = Date()
    ) {
        self.id = id
        self.session = session
        self.kind = kind
        self.queuedAt = queuedAt
        let completionKey = kind == .completed ? SessionCompletionKey.make(for: session) : nil
        self.completionKey = completionKey
        self.identity = completionKey.map(Identity.completed) ?? .lifecycle(
            kind: kind,
            sessionID: session.sessionId,
            incarnationID: session.lifecycleIncarnationID,
            turnID: session.latestTurnId,
            sequence: session.completionSequence,
            itemID: session.chatItems.last?.id
        )
    }
}

enum SessionCompletionPreviewBuilder {
    static func latestUserText(for session: SessionState) -> String? {
        for item in session.chatItems.reversed() {
            if case .user(let text) = item.type {
                return sanitized(text)
            }
        }
        return sanitized(session.firstUserMessage)
    }

    static func latestAssistantText(for session: SessionState) -> String? {
        var activityFallback: String?
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant(let text):
                if let text = sanitized(text) { return text }
            case .thinking(let text):
                activityFallback = activityFallback ?? sanitized(text)
            case .toolCall(let tool):
                let preview = sanitized(tool.inputPreview)
                let label = MCPToolFormatter.formatToolName(tool.name)
                activityFallback = activityFallback ?? (preview.map { "\(label) \($0)" } ?? label)
            case .interrupted:
                activityFallback = activityFallback ?? "已中断"
            case .user:
                // Unversioned session summaries can still describe the previous
                // turn. At this boundary use only activity from the current turn.
                return sanitized(session.intervention?.summaryText) ?? activityFallback
            }
        }

        if let intervention = session.intervention {
            return sanitized(intervention.summaryText)
        }

        return sanitized(session.previewText) ?? sanitized(session.lastMessage) ?? activityFallback
    }

    static func latestAssistantText(
        for session: SessionState,
        notificationKind: SessionCompletionNotification.Kind
    ) -> String? {
        guard notificationKind.usesAssistantPreview else { return nil }
        return latestAssistantText(for: session)
    }

    static func sanitized(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

nonisolated enum SessionCompletionStateEvaluator {
    // Keep upstream assistant evidence as part of readiness: an early tool-tail
    // completion would capture a different key from the final assistant item.
    static func isCompletedReadySession(_ session: SessionState) -> Bool {
        guard case nil = session.intervention else { return false }
        guard !session.needsPromptNotification, session.connectionState == .connected else { return false }
        guard session.phase == .waitingForInput || isCompletedIdleSession(session) else { return false }
        return hasCompletedAssistantReply(for: session)
    }

    private static func isCompletedIdleSession(_ session: SessionState) -> Bool {
        session.phase == .idle && (session.provider == .codex || session.clientInfo.brand == .opencode)
    }

    static func allowsEndedNotificationAfterWaitingForInput(_ session: SessionState) -> Bool {
        guard session.phase == .ended else { return false }
        guard case nil = session.intervention else { return false }
        // Qoder CLI and Kimi both use "Stop" for turn-end (goes to .waitingForInput)
        // and "SessionEnd" for actual session closure.
        return session.clientInfo.isQoderCLIClient
            || session.clientInfo.isKimiClient
    }

    /// Treat tool-only or commentary-only tails as in-progress for completion side
    /// effects, even when the lifecycle transition arrives before the final reply.
    static func hasCompletedAssistantReply(for session: SessionState) -> Bool {
        for item in session.chatItems.reversed() {
            switch item.type {
            case .assistant:
                return true
            case .user, .thinking, .toolCall, .interrupted:
                return false
            }
        }

        return session.lastMessageRole == "assistant"
    }
}

/// A queue stores event snapshots, not live rows. A session may finish another turn
/// (or leave the visible list) before an older result gets a chance to be presented.
nonisolated struct SessionCompletionNotificationQueue {
    private(set) var notifications: [SessionCompletionNotification] = []

    mutating func enqueue(_ notification: SessionCompletionNotification) {
        guard !notifications.contains(where: { $0.identity == notification.identity }) else { return }
        notifications.append(notification)
    }

    mutating func removeAll(where predicate: (SessionCompletionNotification) -> Bool) {
        notifications.removeAll(where: predicate)
    }

    mutating func dequeueNext(
        isConsumed: (SessionCompletionNotification) -> Bool,
        canPresent: (SessionCompletionNotification) -> Bool
    ) -> SessionCompletionNotification? {
        notifications.removeAll(where: isConsumed)
        guard let index = notifications.firstIndex(where: canPresent) else { return nil }
        return notifications.remove(at: index)
    }
}

@MainActor
final class SessionCompletionNotificationRegistry {
    static let shared = SessionCompletionNotificationRegistry()

    private var consumedCompletionKeys = Set<SessionCompletionKey>()
    private var consumedLifecycleKeys = Set<SessionCompletionNotification.Identity>()
    private var queue = SessionCompletionNotificationQueue()

    // Pending results survive destruction/recreation of either surface's window.
    var pendingNotifications: [SessionCompletionNotification] { queue.notifications }

    func isConsumed(session: SessionState) -> Bool {
        guard let key = SessionCompletionKey.make(for: session) else { return false }
        return consumedCompletionKeys.contains(key)
    }

    func markConsumed(session: SessionState) {
        guard let key = SessionCompletionKey.make(for: session) else { return }
        consumedCompletionKeys.insert(key)
    }

    func isConsumed(_ notification: SessionCompletionNotification) -> Bool {
        if let key = notification.completionKey {
            return consumedCompletionKeys.contains(key)
        }
        return consumedLifecycleKeys.contains(notification.identity)
    }

    func markConsumed(_ notification: SessionCompletionNotification) {
        // Never derive this from a newer live session: it could acknowledge another turn.
        if let key = notification.completionKey {
            consumedCompletionKeys.insert(key)
        } else {
            consumedLifecycleKeys.insert(notification.identity)
        }
    }

    func enqueue(_ notification: SessionCompletionNotification) {
        guard !isConsumed(notification) else { return }
        queue.enqueue(notification)
    }

    func synchronizePendingNotifications() {
        queue.removeAll(where: isConsumed)
    }

    func dequeueNext(
        in sessions: [SessionState],
        isPresentationBlocked: Bool
    ) -> SessionCompletionNotification? {
        guard !isPresentationBlocked else { return nil }
        let next = queue.dequeueNext(isConsumed: isConsumed) { notification in
            !SessionCompletionNotificationPolicy.hasBlockingActiveSession(
                for: notification.session,
                in: sessions
            )
        }
        if let next {
            // Claim on the main actor before either surface can present the same key.
            markConsumed(next)
        }
        return next
    }

    func removePendingNotifications(matching shouldRemove: (SessionCompletionNotification.Kind) -> Bool) {
        let removed = pendingNotifications.filter { shouldRemove($0.kind) }
        queue.removeAll { shouldRemove($0.kind) }
        for notification in removed {
            markConsumed(notification)
        }
    }
}

enum SessionCompletionNotificationPolicy {
    private static let notificationRecencyWindow: TimeInterval = 60

    static func shouldQueueCompletedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard SessionCompletionStateEvaluator.isCompletedReadySession(session) else { return false }

        if session.provider == .codex {
            guard session.phase == .idle else { return false }
            guard let previousPhase, isCodexCompletionSourcePhase(previousPhase) else {
                return false
            }
            return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
        }

        guard previousPhase != session.phase else { return false }
        return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
    }

    static func shouldQueueEndedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard session.phase == .ended else { return false }
        guard previousPhase != .ended else { return false }
        guard wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now) else {
            return false
        }
        if previousPhase == .waitingForInput {
            return SessionCompletionStateEvaluator.allowsEndedNotificationAfterWaitingForInput(session)
        }
        return true
    }

    static func shouldQueueCompactedNotification(
        for session: SessionState,
        previousPhase: SessionPhase?,
        isEnabled: Bool,
        now: Date = Date()
    ) -> Bool {
        guard isEnabled else { return false }
        guard previousPhase == .compacting else { return false }
        guard session.phase != .compacting else { return false }
        return wasTrackedOrRecentlyCreated(session, previousPhase: previousPhase, now: now)
    }

    static func hasRecentNotificationActivity(
        _ session: SessionState,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(session.lastActivity) <= notificationRecencyWindow
    }

    static func hasBlockingActiveSession(
        for session: SessionState,
        in sessions: [SessionState]
    ) -> Bool {
        // A newer turn on the same session also blocks a captured older result.
        sessions.contains { $0.isExecutionActive || $0.needsManualAttention || $0.needsPromptNotification }
    }

    private static func isCodexCompletionSourcePhase(_ phase: SessionPhase) -> Bool {
        switch phase {
        case .processing, .waitingForInput, .waitingForApproval:
            return true
        case .idle, .ended, .compacting:
            return false
        }
    }

    private static func wasTrackedOrRecentlyCreated(
        _ session: SessionState,
        previousPhase: SessionPhase?,
        now: Date
    ) -> Bool {
        guard hasRecentNotificationActivity(session, now: now) else {
            return false
        }

        if previousPhase != nil {
            return true
        }

        return now.timeIntervalSince(session.createdAt) <= notificationRecencyWindow
    }
}

struct SessionCompletionNotificationView: View {
    static let minimumContentHeight: CGFloat = 172
    static let maximumAssistantContentHeight: CGFloat = 300
    static let bubbleAssistantLineLimit = 9

    let notification: SessionCompletionNotification
    let presentationStyle: SessionCompletionNotificationPresentationStyle
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var measuredAssistantContentHeight: CGFloat = 0

    init(
        notification: SessionCompletionNotification,
        presentationStyle: SessionCompletionNotificationPresentationStyle = .panel,
        onHoverChanged: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.notification = notification
        self.presentationStyle = presentationStyle
        self.onHoverChanged = onHoverChanged
        self.onDismiss = onDismiss
    }

    private var session: SessionState { notification.session }

    private var assistantLabel: String {
        session.providerDisplayName
    }

    private var providerTint: Color {
        session.clientTintColor
    }

    private var assistantPrefixColor: Color {
        providerTint.opacity(session.isExecutionActive ? 0.96 : 0.9)
    }

    private var assistantTextColor: Color {
        .white.opacity(0.82)
    }

    private var bodyFontSize: CGFloat {
        max(12, CGFloat(settings.contentFontSize))
    }

    private var userText: String? {
        SessionCompletionPreviewBuilder.latestUserText(for: session)
    }

    private var assistantText: String? {
        SessionCompletionPreviewBuilder.latestAssistantText(
            for: session,
            notificationKind: notification.kind
        )
    }

    private var assistantContentHeight: CGFloat? {
        guard measuredAssistantContentHeight > 0 else { return nil }
        return min(measuredAssistantContentHeight, Self.maximumAssistantContentHeight)
    }

    private var assistantLabelText: String {
        assistantLabel + "："
    }

    @ViewBuilder
    private var assistantContent: some View {
        if let assistantText {
            MarkdownText(
                assistantText,
                color: assistantTextColor,
                fontSize: bodyFontSize
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(assistantLineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        } else {
            Text(appLocalized: notification.kind.fallbackAssistantMessageKey)
                .font(.system(size: bodyFontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(assistantLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: presentationStyle == .panel)
        }
    }

    private var assistantLineLimit: Int? {
        switch presentationStyle {
        case .panel:
            return nil
        case .bubble:
            return Self.bubbleAssistantLineLimit
        }
    }

    @ViewBuilder
    private var assistantMessageView: some View {
        switch presentationStyle {
        case .panel:
            ScrollView(.vertical, showsIndicators: true) {
                assistantContent
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: SessionCompletionContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            .frame(height: assistantContentHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .bubble:
            assistantContent
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var assistantSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(assistantLabelText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(assistantPrefixColor)

            assistantMessageView
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var containerCornerRadius: CGFloat { 16 }

    @ViewBuilder
    private var contentCard: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(appLocalized: "你：")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.48))

                Text(userText ?? session.titleOnlySubagentDisplayTitle)
                    .font(.system(size: bodyFontSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(AppLocalization.string(notification.kind.statusLabelKey))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1)

            assistantSection
        }

        switch presentationStyle {
        case .panel:
            content
                .background(
                    RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: containerCornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                        )
                )
        case .bubble:
            content
        }
    }

    private var outerHorizontalPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 14
        case .bubble:
            return 0
        }
    }

    private var outerTopPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 8
        case .bubble:
            return 0
        }
    }

    private var outerBottomPadding: CGFloat {
        switch presentationStyle {
        case .panel:
            return 12
        case .bubble:
            return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            contentCard
        }
        .padding(.horizontal, outerHorizontalPadding)
        .padding(.top, outerTopPadding)
        .padding(.bottom, outerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(
            presentationStyle == .bubble
                ? AnyShape(Rectangle())
                : AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .onPreferenceChange(SessionCompletionContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            measuredAssistantContentHeight = height
        }
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onDisappear {
            onHoverChanged(false)
        }
        .onTapGesture {
            onDismiss()
        }
    }
}

enum SessionCompletionNotificationPresentationStyle: Equatable {
    case panel
    case bubble
}
