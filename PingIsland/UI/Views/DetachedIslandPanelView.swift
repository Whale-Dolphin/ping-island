import AppKit
import Combine
import SwiftUI

struct DetachedIslandPetMetrics: Equatable {
    let scale: CGFloat
    let petVisualFrame: CGFloat
    let petHitFrame: CGFloat
    let mascotDisplaySize: CGFloat
    let badgeOffset: CGSize
    let floatingUsageBoltGap: CGFloat
    let floatingUsageBoltFontSize: CGFloat

    static let minimumScale = CGFloat(AppSettingsStore.minimumFloatingPetScale)
    static let maximumScale = CGFloat(AppSettingsStore.maximumFloatingPetScale)
    static let standard = DetachedIslandPetMetrics(scale: minimumScale)

    init(scale: CGFloat) {
        let sanitizedScale = min(max(scale, Self.minimumScale), Self.maximumScale)
        self.scale = sanitizedScale
        self.petVisualFrame = 74 * sanitizedScale
        self.petHitFrame = 92 * sanitizedScale
        self.mascotDisplaySize = 46 * sanitizedScale
        self.badgeOffset = CGSize(width: 4, height: 2)
        self.floatingUsageBoltGap = 9
        self.floatingUsageBoltFontSize = 8 * sanitizedScale
    }

    func activeCountFontSize(for count: Int) -> CGFloat {
        (count >= 10 ? 8.2 : 9.2) * scale
    }
}

enum DetachedIslandPanelMetrics {
    static let mascotRenderScale: CGFloat = 1.75
    static let bubbleGap: CGFloat = 8
    static let leftBubbleGap: CGFloat = 2
    static let bubbleTailWidth: CGFloat = 30
    static let bubbleTailHeight: CGFloat = 16
    static let bubbleTailOverlap: CGFloat = 7
    static let bubbleTailInset: CGFloat = 4
    static let bubbleCornerRadius: CGFloat = 22
    static let bubbleRenderInset: CGFloat = 1.5
    static let bubbleWindowGutter: CGFloat = 2
    static let bubbleHorizontalPadding: CGFloat = 6
    static let bubbleVerticalPadding: CGFloat = 4
    static let usageFooterReservedHeight: CGFloat = 34
    static let usageFooterVerticalOffset: CGFloat = -3
    static let settingsHintBubbleSize = CGSize(width: 248, height: 92)
    static let completionBubbleMinimumHeight: CGFloat = 120
    static let completionBubbleFallbackHeight: CGFloat = 180

    @MainActor
    static func petMetrics() -> DetachedIslandPetMetrics {
        petMetrics(scale: AppSettings.floatingPetScale)
    }

    static func petMetrics(scale: Double) -> DetachedIslandPetMetrics {
        DetachedIslandPetMetrics(scale: CGFloat(scale))
    }
}

enum DetachedFloatingPetAppearance {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func activeCountColor(isDark: Bool) -> Color {
        isDark ? .white : .black
    }
}

enum DetachedIslandBubblePlacement: CaseIterable, Equatable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    static let priorityOrder: [DetachedIslandBubblePlacement] = [
        .topLeft,
        .topRight,
        .bottomLeft,
        .bottomRight
    ]

    var isBubbleLeftOfPet: Bool {
        switch self {
        case .topLeft, .bottomLeft:
            return true
        case .topRight, .bottomRight:
            return false
        }
    }

    var isBubbleAbovePet: Bool {
        switch self {
        case .topLeft, .topRight:
            return true
        case .bottomLeft, .bottomRight:
            return false
        }
    }

}

enum DetachedIslandBubbleContentMode: Equatable {
    case hoverPreview
    case pinnedList

    init?(bubbleState: DetachedIslandBubbleState) {
        switch bubbleState {
        case .hidden:
            return nil
        case .hoverPreview:
            self = .hoverPreview
        case .pinned:
            self = .pinnedList
        }
    }
}

struct DetachedIslandWindowLayout: Equatable {
    let containerSize: CGSize
    let petFrame: CGRect
    let bubbleFrame: CGRect?
    let bubblePlacement: DetachedIslandBubblePlacement
    let petAnchorInWindow: CGPoint
    let bubbleContentMode: DetachedIslandBubbleContentMode?
    var maximumBubbleContentSize: CGSize? = nil
}

enum DetachedIslandContentModel {
    static func preferredBubblePlacement(
        for petScreenAnchor: CGPoint,
        bubbleSize: CGSize,
        availableFrame: CGRect,
        preferredPlacement: DetachedIslandBubblePlacement = .topLeft,
        petMetrics: DetachedIslandPetMetrics = .standard
    ) -> DetachedIslandBubblePlacement {
        var fallbackPlacement = preferredPlacement
        var fallbackVisibleArea: CGFloat = -.greatestFiniteMagnitude

        for placement in DetachedIslandBubblePlacement.priorityOrder {
            let bubbleFrame = bubbleScreenFrame(
                for: placement,
                petScreenAnchor: petScreenAnchor,
                petMetrics: petMetrics,
                bubbleSize: bubbleSize
            )

            if availableFrame.contains(bubbleFrame) {
                return placement
            }

            let visibleArea = visibleArea(of: bubbleFrame, within: availableFrame)
            if visibleArea > fallbackVisibleArea {
                fallbackVisibleArea = visibleArea
                fallbackPlacement = placement
            }
        }

        return fallbackPlacement
    }

    static func availableBubbleContentSize(
        for placement: DetachedIslandBubblePlacement,
        petScreenAnchor: CGPoint,
        availableFrame: CGRect,
        petMetrics: DetachedIslandPetMetrics = .standard
    ) -> CGSize {
        let bounds = availableFrame.insetBy(
            dx: DetachedIslandPanelMetrics.bubbleWindowGutter,
            dy: DetachedIslandPanelMetrics.bubbleWindowGutter
        )
        let halfPet = petMetrics.petHitFrame / 2
        let gap = DetachedIslandPanelMetrics.bubbleGap
        let width = placement.isBubbleLeftOfPet
            ? petScreenAnchor.x - halfPet - DetachedIslandPanelMetrics.leftBubbleGap - bounds.minX
            : bounds.maxX - (petScreenAnchor.x + halfPet + gap)
        // Match the current scaled pet/bubble overlap, not the old above/below
        // approximation. The pet's screen anchor stays fixed while content grows.
        let attachmentY = placement.isBubbleAbovePet
            ? petScreenAnchor.y + halfPet + gap - (placement == .topLeft ? petMetrics.petVisualFrame : 0)
            : petScreenAnchor.y - halfPet - gap + petMetrics.petVisualFrame
        let height = placement.isBubbleAbovePet
            ? bounds.maxY - attachmentY
            : attachmentY - bounds.minY
        return CGSize(width: max(0, width), height: max(0, height))
    }

    static func sortedSessions(from sessions: [SessionState]) -> [SessionState] {
        IslandExpandedRouteResolver.orderedSessions(from: sessions)
    }

    static func representativeSession(from sessions: [SessionState]) -> SessionState? {
        IslandExpandedRouteResolver.highestPriorityAttentionSession(from: sessions)
            ?? sortedSessions(from: sessions).first
    }

    static func activeCount(from sessions: [SessionState]) -> Int {
        sessions.filter(\.isExecutionActive).count
    }

    static func canPresentBubble(
        from sessions: [SessionState],
        mode: DetachedIslandBubbleContentMode,
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> Bool {
        switch mode {
        case .hoverPreview:
            if activeCompletionNotification != nil {
                return true
            }
            return IslandExpandedRouteResolver.highestPriorityAttentionSession(from: sessions) != nil
                || !IslandExpandedRouteResolver.activePreviewSessions(from: sessions).isEmpty
        case .pinnedList:
            return !IslandExpandedRouteResolver.activePreviewSessions(from: sessions).isEmpty
        }
    }

    @MainActor
    static func route(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        mode: DetachedIslandBubbleContentMode,
        activeCompletionNotification: SessionCompletionNotification? = nil
    ) -> IslandExpandedRoute {
        let trigger: IslandExpandedTrigger = switch mode {
        case .hoverPreview:
            activeCompletionNotification == nil ? .hover : .notification
        case .pinnedList: .pinnedList
        }

        return IslandExpandedRouteResolver.resolve(
            surface: .floating,
            trigger: trigger,
            contentType: viewModel.contentType,
            sessions: sessions,
            activeCompletionNotification: activeCompletionNotification
        )
    }

    @MainActor
    static func bubbleContentSize(
        for route: IslandExpandedRoute,
        sessions: [SessionState],
        viewModel: NotchViewModel,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        measuredCompletionBubbleHeight: CGFloat? = nil,
        additionalFooterHeight: CGFloat = 0,
        maximumSize: CGSize? = nil
    ) -> CGSize {
        let widthLimit = max(0, min(viewModel.screenRect.width - 132, maximumSize?.width ?? .greatestFiniteMagnitude))
        let heightLimit = maximumBubbleContentHeight(for: viewModel, availableHeight: maximumSize?.height)

        switch route {
        case .sessionList:
            let width = min(widthLimit, 448)
            let selected = IslandExpandedRouteResolver.activePreviewSessions(from: sessions)
            let density = sessionListDensity(
                for: selected,
                viewModel: viewModel,
                additionalFooterHeight: additionalFooterHeight,
                maximumContentHeight: heightLimit
            )
            let estimatedHeight = sessionListEstimatedHeight(for: selected, density: density)
            let height = min(
                heightLimit,
                max(96, estimatedHeight + additionalFooterHeight)
            )
            return CGSize(width: width, height: height)
        case .hoverDashboard:
            let width = min(widthLimit, 392)
            let count = max(IslandExpandedRouteResolver.activePreviewSessions(from: sessions).count, 1)
            let rowHeight: CGFloat = hoverDashboardUsesCondensedRows(
                for: sessions,
                viewModel: viewModel,
                maximumContentHeight: heightLimit
            ) ? 48 : 94
            let estimatedHeight = 18 + (CGFloat(count) * rowHeight)
            let height = min(heightLimit, max(120, estimatedHeight))
            return CGSize(width: width, height: height)
        case .attentionNotification(let session):
            let width = min(widthLimit, 392)
            let height = measuredAttentionBubbleHeight ?? (session.needsQuestionResponse ? 316 : 228)
            return CGSize(width: width, height: min(heightLimit, max(170, height)))
        case .completionNotification:
            let width = min(widthLimit, 392)
            let height = measuredCompletionBubbleHeight
                ?? DetachedIslandPanelMetrics.completionBubbleFallbackHeight
            return CGSize(
                width: width,
                height: min(
                    heightLimit,
                    max(DetachedIslandPanelMetrics.completionBubbleMinimumHeight, height)
                )
            )
        case .chat:
            let size = viewModel.panelSize(for: .detached)
            return CGSize(width: min(widthLimit, size.width), height: min(heightLimit, size.height))
        }
    }

    @MainActor
    static func sessionListDensity(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        additionalFooterHeight: CGFloat = 0,
        maximumContentHeight: CGFloat? = nil
    ) -> SessionListDensity {
        let selected = IslandExpandedRouteResolver.activePreviewSessions(from: sessions)
        let regularHeight = sessionListEstimatedHeight(for: selected, density: .regular)
            + additionalFooterHeight
        return regularHeight <= maximumBubbleContentHeight(for: viewModel, availableHeight: maximumContentHeight)
            ? .regular : .constrained
    }

    @MainActor
    static func hoverDashboardUsesCondensedRows(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        maximumContentHeight: CGFloat? = nil
    ) -> Bool {
        let count = max(IslandExpandedRouteResolver.activePreviewSessions(from: sessions).count, 1)
        return 18 + (CGFloat(count) * 94) > maximumBubbleContentHeight(
            for: viewModel, availableHeight: maximumContentHeight
        )
    }

    @MainActor
    static func maximumBubbleContentHeight(for viewModel: NotchViewModel, availableHeight: CGFloat? = nil) -> CGFloat {
        let screenLimit = max(96, viewModel.screenRect.height - 160)
        return max(0, min(screenLimit, availableHeight ?? screenLimit))
    }

    private static func sessionListEstimatedHeight(
        for sessions: [SessionState],
        density: SessionListDensity
    ) -> CGFloat {
        guard !sessions.isEmpty else { return 96 }
        let contentHeight = sessions.reduce(CGFloat(0)) { partial, session in
            partial + sessionListRowHeight(for: session, density: density)
        }
        let spacing = CGFloat(max(0, sessions.count - 1)) * 2
        return contentHeight + spacing + 8
    }

    private static func sessionListRowHeight(
        for session: SessionState,
        density: SessionListDensity
    ) -> CGFloat {
        // Preserve both in-app controls and terminal-routed prompt details.
        if session.needsManualAttention || session.needsPromptNotification {
            return 86
        }
        if density == .constrained {
            return session.shouldUseMinimalCompactPresentation || session.usesTitleOnlySubagentPresentation
                ? 40 : 52
        }
        if session.isExecutionActive {
            return 74
        }
        return session.shouldUseMinimalCompactPresentation || session.usesTitleOnlySubagentPresentation
            ? 46 : 56
    }

    static func contentWidth(
        for bubbleFrameWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            bubbleFrameWidth
                - (DetachedIslandPanelMetrics.bubbleRenderInset * 2)
                - (DetachedIslandPanelMetrics.bubbleHorizontalPadding * 2)
        )
    }

    @MainActor
    static func layout(
        for sessions: [SessionState],
        viewModel: NotchViewModel,
        bubbleState: DetachedIslandBubbleState,
        bubblePlacement: DetachedIslandBubblePlacement,
        measuredAttentionBubbleHeight: CGFloat? = nil,
        measuredCompletionBubbleHeight: CGFloat? = nil,
        additionalFooterHeight: CGFloat = 0,
        activeCompletionNotification: SessionCompletionNotification? = nil,
        guideBubbleSize: CGSize? = nil,
        petScreenAnchor: CGPoint? = nil,
        availableFrame: CGRect? = nil,
        petMetrics: DetachedIslandPetMetrics? = nil
    ) -> DetachedIslandWindowLayout {
        let petMetrics = petMetrics ?? DetachedIslandPanelMetrics.petMetrics()
        let petSize = CGSize(
            width: petMetrics.petHitFrame,
            height: petMetrics.petHitFrame
        )
        let hiddenAnchor = CGPoint(x: petSize.width / 2, y: petSize.height / 2)

        guard let mode = DetachedIslandBubbleContentMode(bubbleState: bubbleState),
              canPresentBubble(
                from: sessions,
                mode: mode,
                activeCompletionNotification: activeCompletionNotification
              ) else {
            if let guideBubbleSize {
                return bubbleLayout(
                    petSize: petSize,
                    bubbleSize: guideBubbleSize,
                    bubblePlacement: bubblePlacement,
                    bubbleContentMode: nil,
                    petScreenAnchor: petScreenAnchor,
                    availableFrame: availableFrame,
                    petMetrics: petMetrics
                )
            }

            return DetachedIslandWindowLayout(
                containerSize: petSize,
                petFrame: CGRect(origin: .zero, size: petSize),
                bubbleFrame: nil,
                bubblePlacement: bubblePlacement,
                petAnchorInWindow: hiddenAnchor,
                bubbleContentMode: nil
            )
        }

        let route = route(
            for: sessions,
            viewModel: viewModel,
            mode: mode,
            activeCompletionNotification: activeCompletionNotification
        )
        let preferredSize = bubbleContentSize(
            for: route,
            sessions: sessions,
            viewModel: viewModel,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: measuredCompletionBubbleHeight,
            additionalFooterHeight: additionalFooterHeight
        )
        let resolvedPlacement: DetachedIslandBubblePlacement
        let maximumSize: CGSize?
        if let petScreenAnchor, let availableFrame {
            resolvedPlacement = preferredBubblePlacement(
                for: petScreenAnchor, bubbleSize: preferredSize, availableFrame: availableFrame,
                preferredPlacement: bubblePlacement, petMetrics: petMetrics
            )
            maximumSize = availableBubbleContentSize(
                for: resolvedPlacement, petScreenAnchor: petScreenAnchor,
                availableFrame: availableFrame, petMetrics: petMetrics
            )
        } else {
            resolvedPlacement = bubblePlacement
            maximumSize = nil
        }
        let bubbleSize = bubbleContentSize(
            for: route,
            sessions: sessions,
            viewModel: viewModel,
            measuredAttentionBubbleHeight: measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: measuredCompletionBubbleHeight,
            additionalFooterHeight: additionalFooterHeight,
            maximumSize: maximumSize
        )
        return bubbleLayout(
            petSize: petSize,
            bubbleSize: bubbleSize,
            bubblePlacement: resolvedPlacement,
            bubbleContentMode: mode,
            petScreenAnchor: nil,
            availableFrame: nil,
            petMetrics: petMetrics,
            maximumBubbleContentSize: maximumSize
        )
    }

    private static func bubbleLayout(
        petSize: CGSize,
        bubbleSize: CGSize,
        bubblePlacement: DetachedIslandBubblePlacement,
        bubbleContentMode: DetachedIslandBubbleContentMode?,
        petScreenAnchor: CGPoint?,
        availableFrame: CGRect?,
        petMetrics: DetachedIslandPetMetrics,
        maximumBubbleContentSize: CGSize? = nil
    ) -> DetachedIslandWindowLayout {
        let resolvedPlacement: DetachedIslandBubblePlacement
        if let petScreenAnchor, let availableFrame {
            resolvedPlacement = preferredBubblePlacement(
                for: petScreenAnchor,
                bubbleSize: bubbleSize,
                availableFrame: availableFrame,
                preferredPlacement: bubblePlacement,
                petMetrics: petMetrics
            )
        } else {
            resolvedPlacement = bubblePlacement
        }

        let horizontalGap = resolvedPlacement.isBubbleLeftOfPet
            ? DetachedIslandPanelMetrics.leftBubbleGap
            : DetachedIslandPanelMetrics.bubbleGap
        let verticalGap = DetachedIslandPanelMetrics.bubbleGap
        let topPlacementVerticalAdjustment = resolvedPlacement == .topLeft
            ? petMetrics.petVisualFrame
            : 0
        let bottomPlacementVerticalAdjustment = resolvedPlacement.isBubbleAbovePet
            ? 0
            : petMetrics.petVisualFrame
        let gutter = DetachedIslandPanelMetrics.bubbleWindowGutter
        let containerWidth = petSize.width + horizontalGap + bubbleSize.width + (gutter * 2)
        let containerHeight = max(
            petSize.height,
            petSize.height + verticalGap + bubbleSize.height
                - topPlacementVerticalAdjustment
                - bottomPlacementVerticalAdjustment
        ) + (gutter * 2)

        let petOriginX: CGFloat
        let bubbleOriginX: CGFloat
        if resolvedPlacement.isBubbleLeftOfPet {
            bubbleOriginX = gutter
            petOriginX = gutter + bubbleSize.width + horizontalGap
        } else {
            petOriginX = gutter
            bubbleOriginX = gutter + petSize.width + horizontalGap
        }

        let petOriginY: CGFloat
        let bubbleOriginY: CGFloat
        if resolvedPlacement.isBubbleAbovePet {
            bubbleOriginY = gutter
            petOriginY = max(gutter, gutter + bubbleSize.height + verticalGap - topPlacementVerticalAdjustment)
        } else {
            petOriginY = gutter
            bubbleOriginY = max(
                gutter,
                gutter + petSize.height + verticalGap - bottomPlacementVerticalAdjustment
            )
        }

        let petFrame = CGRect(
            origin: CGPoint(x: petOriginX, y: petOriginY),
            size: petSize
        )
        let bubbleFrame = CGRect(
            origin: CGPoint(x: bubbleOriginX, y: bubbleOriginY),
            size: bubbleSize
        )

        return DetachedIslandWindowLayout(
            containerSize: CGSize(
                width: containerWidth,
                height: containerHeight
            ),
            petFrame: petFrame,
            bubbleFrame: bubbleFrame,
            bubblePlacement: resolvedPlacement,
            petAnchorInWindow: CGPoint(x: petFrame.midX, y: petFrame.midY),
            bubbleContentMode: bubbleContentMode,
            maximumBubbleContentSize: maximumBubbleContentSize
        )
    }

    static func bubbleScreenFrame(
        for placement: DetachedIslandBubblePlacement,
        petScreenAnchor: CGPoint,
        petMetrics: DetachedIslandPetMetrics = .standard,
        bubbleSize: CGSize
    ) -> CGRect {
        // Use the actual top-origin layout and AppKit anchor conversion so
        // placement selection includes main's scaled visual-overlap offsets.
        let layout = bubbleLayout(
            petSize: CGSize(width: petMetrics.petHitFrame, height: petMetrics.petHitFrame),
            bubbleSize: bubbleSize,
            bubblePlacement: placement,
            bubbleContentMode: nil,
            petScreenAnchor: nil,
            availableFrame: nil,
            petMetrics: petMetrics
        )
        guard let bubble = layout.bubbleFrame else { return .zero }
        return CGRect(
            x: petScreenAnchor.x - layout.petAnchorInWindow.x + bubble.minX,
            y: petScreenAnchor.y + layout.petAnchorInWindow.y - bubble.maxY,
            width: bubble.width,
            height: bubble.height
        )
    }

    private static func visibleArea(of rect: CGRect, within bounds: CGRect) -> CGFloat {
        let intersection = rect.intersection(bounds)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

@MainActor
final class DetachedIslandInteractionModel: ObservableObject {
    @Published private(set) var bubbleState: DetachedIslandBubbleState = .hidden
    @Published private(set) var bubblePlacement: DetachedIslandBubblePlacement = .topLeft
    @Published private(set) var isPetDragging = false
    @Published private(set) var isSettingsHintVisible = false

    var bubbleContentMode: DetachedIslandBubbleContentMode? {
        DetachedIslandBubbleContentMode(bubbleState: bubbleState)
    }

    #if compiler(>=6.3)
    // Match NotchViewModel teardown behavior for Xcode 26 unit-test stability.
    nonisolated deinit {}
    #endif

    func setBubblePlacement(_ placement: DetachedIslandBubblePlacement) {
        guard bubblePlacement != placement else { return }
        bubblePlacement = placement
    }

    func togglePrimaryBubble(
        canPresentPreview: Bool,
        canPresentPinnedBubble: Bool
    ) {
        switch bubbleState {
        case .hidden:
            if canPresentPreview {
                bubbleState = .hoverPreview
            } else if canPresentPinnedBubble {
                bubbleState = .pinned
            }
        case .hoverPreview, .pinned:
            bubbleState = .hidden
        }
    }

    func togglePinned(canPresentBubble: Bool) {
        guard canPresentBubble else { return }

        switch bubbleState {
        case .pinned:
            bubbleState = .hidden
        case .hidden, .hoverPreview:
            bubbleState = .pinned
        }
    }

    func hidePinnedBubble() {
        bubbleState = .hidden
    }

    func presentHoverPreview(canPresentBubble: Bool) {
        guard canPresentBubble else {
            hidePinnedBubble()
            return
        }

        bubbleState = .hoverPreview
    }

    func resetForDragSuppression() {
        hidePinnedBubble()
    }

    func setPetDragging(_ isDragging: Bool) {
        guard isPetDragging != isDragging else { return }
        isPetDragging = isDragging
    }

    func setSettingsHintVisible(_ visible: Bool) {
        guard isSettingsHintVisible != visible else { return }
        isSettingsHintVisible = visible
    }
}

@MainActor
final class DetachedIslandBubbleViewState: ObservableObject {
    @Published var highlightedSessionStableID: String?
    @Published private(set) var activeCompletionNotification: SessionCompletionNotification?
    @Published private(set) var renderedBubbleState: DetachedIslandBubbleState = .hidden
    @Published private(set) var isBubbleVisible = false
    @Published private(set) var measuredAttentionBubbleHeight: CGFloat?
    @Published private(set) var measuredCompletionBubbleHeight: CGFloat?
    @Published private(set) var windowLayout: DetachedIslandWindowLayout?

    var bubbleFadeDuration: TimeInterval { 0.18 }

    #if compiler(>=6.3)
    // Match NotchViewModel teardown behavior for Xcode 26 unit-test stability.
    nonisolated deinit {}
    #endif

    func prepareLayout(for bubbleState: DetachedIslandBubbleState) {
        guard renderedBubbleState != bubbleState else { return }
        renderedBubbleState = bubbleState
    }

    func setBubbleVisible(_ visible: Bool) {
        guard isBubbleVisible != visible else { return }
        isBubbleVisible = visible
    }

    func setMeasuredAttentionBubbleHeight(_ height: CGFloat?) {
        let sanitized = height.map { ceil(max(0, $0)) }
        guard measuredAttentionBubbleHeight != sanitized else { return }
        measuredAttentionBubbleHeight = sanitized
    }

    func setMeasuredCompletionBubbleHeight(_ height: CGFloat?) {
        let sanitized = height.map { ceil(max(0, $0)) }
        guard measuredCompletionBubbleHeight != sanitized else { return }
        measuredCompletionBubbleHeight = sanitized
    }

    func setActiveCompletionNotification(_ notification: SessionCompletionNotification?) {
        guard activeCompletionNotification != notification else { return }
        activeCompletionNotification = notification
    }

    func setWindowLayout(_ layout: DetachedIslandWindowLayout) {
        guard windowLayout != layout else { return }
        windowLayout = layout
    }
}

struct DetachedIslandPanelView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var sessionMonitor: SessionMonitor
    @ObservedObject var interactionModel: DetachedIslandInteractionModel
    @ObservedObject var bubbleViewState: DetachedIslandBubbleViewState
    @ObservedObject private var settings = AppSettings.shared
    @State private var isPetDragging = false

    let onClose: () -> Void
    let onPetTap: () -> Void
    let onPetDragStarted: () -> Void
    let onPetDragChanged: (CGSize) -> Void
    let onPetDragEnded: () -> Void
    let onBubbleHoverChanged: (Bool) -> Void
    let onAttentionActionCompleted: () -> Void
    let onCompletionNotificationHoverChanged: (Bool) -> Void
    let onDismissCompletionNotification: () -> Void

    private var sortedSessions: [SessionState] {
        DetachedIslandContentModel.sortedSessions(from: sessionMonitor.instances)
    }

    private var representativeSession: SessionState? {
        DetachedIslandContentModel.representativeSession(from: sortedSessions)
    }

    private var activeCount: Int {
        DetachedIslandContentModel.activeCount(from: sortedSessions)
    }

    private var bubbleContentMode: DetachedIslandBubbleContentMode? {
        DetachedIslandBubbleContentMode(bubbleState: bubbleViewState.renderedBubbleState)
    }

    private var bubbleRoute: IslandExpandedRoute? {
        guard let bubbleContentMode else { return nil }
        return DetachedIslandContentModel.route(
            for: sortedSessions,
            viewModel: viewModel,
            mode: bubbleContentMode,
            activeCompletionNotification: bubbleViewState.activeCompletionNotification
        )
    }

    private var sessionListDensity: SessionListDensity {
        DetachedIslandContentModel.sessionListDensity(
            for: sortedSessions,
            viewModel: viewModel,
            additionalFooterHeight: shouldShowFloatingUsageFooter
                ? DetachedIslandPanelMetrics.usageFooterReservedHeight : 0,
            maximumContentHeight: layout.maximumBubbleContentSize?.height
        )
    }

    private var layout: DetachedIslandWindowLayout {
        // Render the same placement/budget that sized the AppKit window. Rebuilding
        // here without its screen anchor would restore the whole-screen height.
        if let windowLayout = bubbleViewState.windowLayout { return windowLayout }
        return DetachedIslandContentModel.layout(
            for: sortedSessions,
            viewModel: viewModel,
            bubbleState: bubbleViewState.renderedBubbleState,
            bubblePlacement: interactionModel.bubblePlacement,
            measuredAttentionBubbleHeight: bubbleViewState.measuredAttentionBubbleHeight,
            measuredCompletionBubbleHeight: bubbleViewState.measuredCompletionBubbleHeight,
            additionalFooterHeight: shouldShowFloatingUsageFooter
                ? DetachedIslandPanelMetrics.usageFooterReservedHeight
                : 0,
            activeCompletionNotification: bubbleViewState.activeCompletionNotification,
            guideBubbleSize: interactionModel.isSettingsHintVisible
                ? DetachedIslandPanelMetrics.settingsHintBubbleSize
                : nil
        )
    }

    private var petMetrics: DetachedIslandPetMetrics {
        DetachedIslandPanelMetrics.petMetrics()
    }

    private var usageSummaryProviders: [UsageSummaryProvider] {
        UsageSummaryPresenter.providers(
            claudeSnapshot: sessionMonitor.claudeUsageSnapshot,
            codexSnapshot: sessionMonitor.codexUsageSnapshot,
            mode: settings.usageValueMode,
            locale: settings.locale
        )
    }

    private var floatingPetUsageWindows: [UsageSummaryWindow] {
        guard settings.showUsage else { return [] }
        return usageSummaryProviders
            .flatMap(\.windows)
            .filter(UsageSummaryPresenter.shouldShowFloatingBolt)
    }

    private var shouldShowFloatingUsageFooter: Bool {
        guard let bubbleRoute else { return false }
        return UsageSummaryPresenter.shouldShowSummary(
            for: bubbleRoute,
            showUsage: settings.showUsage,
            providers: usageSummaryProviders
        )
    }

    private var compactMascotKind: MascotKind {
        settings.mascotKind(for: IslandMascotResolver.sourceSession(from: sortedSessions)?.mascotClient)
    }

    private var compactMascotStatus: MascotStatus {
        if isPetDragging {
            return .dragging
        }
        if let session = IslandDetachedContentResolver.preferredSession(from: sortedSessions) {
            return MascotStatus(session: session)
        }
        return .idle
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let bubbleFrame = layout.bubbleFrame,
               let bubbleContentMode,
               let bubbleRoute {
                bubbleView(
                    mode: bubbleContentMode,
                    route: bubbleRoute,
                    contentWidth: DetachedIslandContentModel.contentWidth(for: bubbleFrame.width)
                )
                    .onHover(perform: onBubbleHoverChanged)
                    .onDisappear {
                        onBubbleHoverChanged(false)
                    }
                    .opacity(bubbleViewState.isBubbleVisible ? 1 : 0)
                    .allowsHitTesting(bubbleViewState.isBubbleVisible)
                    .frame(width: bubbleFrame.width, height: bubbleFrame.height)
                    .offset(x: bubbleFrame.minX, y: bubbleFrame.minY)
            } else if let bubbleFrame = layout.bubbleFrame,
                      interactionModel.isSettingsHintVisible {
                DetachedFloatingPetSettingsHintView(placement: layout.bubblePlacement)
                    .allowsHitTesting(false)
                    .frame(width: bubbleFrame.width, height: bubbleFrame.height)
                    .offset(x: bubbleFrame.minX, y: bubbleFrame.minY)
            }

            petButton
                .frame(width: layout.petFrame.width, height: layout.petFrame.height)
                .offset(x: layout.petFrame.minX, y: layout.petFrame.minY)
        }
        .frame(
            width: layout.containerSize.width,
            height: layout.containerSize.height,
            alignment: .topLeading
        )
        .preferredColorScheme(.dark)
        .onAppear {
            if !SessionMonitor.isRunningUnderXCTest {
                sessionMonitor.startMonitoring()
            }
        }
        .onChange(of: bubbleRoute) { _, route in
            switch route {
            case .attentionNotification:
                bubbleViewState.setMeasuredCompletionBubbleHeight(nil)
            case .completionNotification:
                bubbleViewState.setMeasuredAttentionBubbleHeight(nil)
            default:
                bubbleViewState.setMeasuredAttentionBubbleHeight(nil)
                bubbleViewState.setMeasuredCompletionBubbleHeight(nil)
            }
        }
        .onPreferenceChange(OpenedPanelContentHeightPreferenceKey.self) { height in
            switch bubbleRoute {
            case .attentionNotification:
                let measuredHeight = height > 0
                    ? min(
                        viewModel.screenRect.height - 160,
                        max(
                            170,
                            height + (DetachedIslandPanelMetrics.bubbleVerticalPadding * 2)
                        )
                    )
                    : nil
                bubbleViewState.setMeasuredAttentionBubbleHeight(measuredHeight)
            case .completionNotification:
                let measuredHeight = height > 0
                    ? min(
                        viewModel.screenRect.height - 160,
                        max(
                            DetachedIslandPanelMetrics.completionBubbleMinimumHeight,
                            height + (DetachedIslandPanelMetrics.bubbleVerticalPadding * 2)
                        )
                    )
                    : nil
                bubbleViewState.setMeasuredCompletionBubbleHeight(measuredHeight)
            default:
                return
            }
        }
    }

    private var petButton: some View {
        DetachedFloatingPetInteractionView(
            activeCount: activeCount,
            usageWindows: floatingPetUsageWindows,
            mascotKind: compactMascotKind,
            mascotStatus: compactMascotStatus,
            petMetrics: petMetrics,
            isDragging: interactionModel.isPetDragging,
            onTap: onPetTap,
            onDragStarted: {
                isPetDragging = true
                onPetDragStarted()
            },
            onDragChanged: onPetDragChanged,
            onDragEnded: {
                isPetDragging = false
                onPetDragEnded()
            }
        )
    }

    private func bubbleView(
        mode: DetachedIslandBubbleContentMode,
        route: IslandExpandedRoute,
        contentWidth: CGFloat
    ) -> some View {
        DetachedIslandBubbleChrome(placement: layout.bubblePlacement) {
            VStack(alignment: .leading, spacing: shouldShowFloatingUsageFooter ? 4 : 8) {
                IslandOpenedContentView(
                    sessionMonitor: sessionMonitor,
                    viewModel: viewModel,
                    surface: .floating,
                    trigger: mode == .pinnedList
                        ? .pinnedList
                        : (bubbleViewState.activeCompletionNotification == nil ? .hover : .notification),
                    style: .detached,
                    activeCompletionNotification: bubbleViewState.activeCompletionNotification,
                    highlightedSessionStableID: route == .sessionList
                        ? bubbleViewState.highlightedSessionStableID
                        : nil,
                    contentWidthOverride: contentWidth,
                    sessionListDensity: sessionListDensity,
                    maximumContentHeight: layout.maximumBubbleContentSize?.height,
                    onAttentionActionCompleted: onAttentionActionCompleted,
                    onCompletionNotificationHoverChanged: onCompletionNotificationHoverChanged,
                    onDismissCompletionNotification: onDismissCompletionNotification
                )

                if shouldShowFloatingUsageFooter {
                    HStack {
                        Spacer(minLength: 0)
                        UsageSummaryStripView(
                            providers: usageSummaryProviders,
                            inline: true,
                            alignment: .trailing,
                            displayStyle: .battery,
                            batteryHoverDetailStyle: .currentWindow,
                            batteryPopoverPlacement: .above,
                            locale: settings.locale
                        )
                        .zIndex(200)
                    }
                    .padding(.top, -2)
                    .offset(y: DetachedIslandPanelMetrics.usageFooterVerticalOffset)
                    .zIndex(200)
                }
            }
        }
    }
}

private struct DetachedFloatingPetSettingsHintView: View {
    let placement: DetachedIslandBubblePlacement

    var body: some View {
        DetachedIslandBubbleChrome(placement: placement) {
            VStack(alignment: .leading, spacing: 8) {
                Text(appLocalized: "最后一步：右键宠物形象")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)

                Text(appLocalized: "需要重新打开设置面板时，直接右键宠物形象就可以。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text(
                AppLocalization.string("最后一步：右键宠物形象")
                + " "
                + AppLocalization.string("需要重新打开设置面板时，直接右键宠物形象就可以。")
            )
        )
    }
}

private struct DetachedFloatingPetInteractionView: View {
    let activeCount: Int
    let usageWindows: [UsageSummaryWindow]
    let mascotKind: MascotKind
    let mascotStatus: MascotStatus
    let petMetrics: DetachedIslandPetMetrics
    let isDragging: Bool
    let onTap: () -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    // The bubble intentionally stays dark, but the count sits on the desktop.
    // Observe the system appearance rather than its forced-dark SwiftUI parent.
    @State private var isDarkSystemAppearance = DetachedFloatingPetAppearance.isDark(
        NSApplication.shared.effectiveAppearance
    )

    var body: some View {
        DetachedFloatingMascotView(
            kind: mascotKind,
            status: mascotStatus,
            petMetrics: petMetrics,
            isDragging: isDragging
        )
        .overlay(alignment: .bottomTrailing) {
            if activeCount > 0 {
                activeCountBadge
                    .offset(
                        x: petMetrics.badgeOffset.width,
                        y: petMetrics.badgeOffset.height
                    )
            }
        }
        .overlay(alignment: .top) {
            if !usageWindows.isEmpty {
                DetachedFloatingUsageBoltView(
                    windows: usageWindows,
                    fontSize: petMetrics.floatingUsageBoltFontSize
                )
                    .offset(
                        y: -(petMetrics.floatingUsageBoltFontSize + petMetrics.floatingUsageBoltGap)
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(
            width: petMetrics.petVisualFrame,
            height: petMetrics.petVisualFrame
        )
        .frame(
            width: petMetrics.petHitFrame,
            height: petMetrics.petHitFrame
        )
        .rotationEffect(.degrees(isDragging ? -7 : 0))
        .scaleEffect(isDragging ? 1.08 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.68), value: isDragging)
        .overlay {
            DetachedPetInteractionBridge(
                size: CGSize(
                    width: petMetrics.petHitFrame,
                    height: petMetrics.petHitFrame
                ),
                onTap: onTap,
                onDragStarted: onDragStarted,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded
            )
            .frame(
                width: petMetrics.petHitFrame,
                height: petMetrics.petHitFrame
            )
        }
        .onReceive(NSApplication.shared.publisher(for: \.effectiveAppearance)) { appearance in
            isDarkSystemAppearance = DetachedFloatingPetAppearance.isDark(appearance)
        }
    }

    @ViewBuilder
    private var activeCountBadge: some View {
        PixelNumberView(
            value: activeCount,
            color: DetachedFloatingPetAppearance.activeCountColor(isDark: isDarkSystemAppearance),
            fontSize: petMetrics.activeCountFontSize(for: activeCount),
            weight: .semibold,
            tracking: activeCount >= 10 ? -0.15 : -0.05
        )
    }
}

private struct DetachedFloatingUsageBoltView: View {
    let windows: [UsageSummaryWindow]
    let fontSize: CGFloat

    @ObservedObject private var energyGovernor = EnergyGovernor.shared

    private let cycleInterval: TimeInterval = 1.8

    var body: some View {
        if energyGovernor.policy.animationLevel == .staticFrames {
            boltBody(date: .now, isAnimated: false)
        } else {
            TimelineView(.periodic(from: .now, by: boltInterval)) { context in
                boltBody(date: context.date, isAnimated: true)
            }
        }
    }

    @ViewBuilder
    private func boltBody(date: Date, isAnimated: Bool) -> some View {
        if let window = window(for: date) {
            let phase = date.timeIntervalSinceReferenceDate
            let pulse = isAnimated ? 1 + (sin(phase * .pi * 2 / 1.2) * 0.05) : 1
            let lift = isAnimated ? sin(phase * .pi * 2 / 1.6) * 1.2 : 0

            Image(systemName: "bolt.fill")
                .font(.system(size: fontSize, weight: .black))
                .foregroundColor(color(for: window.severity))
                .scaleEffect((window.severity == .critical ? 1.08 : 1) * pulse)
                .offset(y: lift)
                .id(window.id)
                .help(window.resetText ?? window.valueText)
                .accessibilityLabel(Text(accessibilityLabel(for: window)))
        }
    }

    private var boltInterval: TimeInterval {
        switch energyGovernor.policy.animationLevel {
        case .full:
            1.0 / 24.0
        case .reduced:
            1.0 / 8.0
        case .staticFrames:
            1.0 / 24.0
        }
    }

    private func window(for date: Date) -> UsageSummaryWindow? {
        guard !windows.isEmpty else { return nil }
        let index = Int(date.timeIntervalSinceReferenceDate / cycleInterval) % windows.count
        return windows[index]
    }

    private func color(for severity: UsageSummarySeverity) -> Color {
        switch severity {
        case .healthy:
            return Color(red: 0.42, green: 0.92, blue: 0.60)
        case .warning:
            return Color(red: 0.98, green: 0.82, blue: 0.32)
        case .critical:
            return Color(red: 0.98, green: 0.44, blue: 0.38)
        }
    }

    private func accessibilityLabel(for window: UsageSummaryWindow) -> String {
        [window.label, window.valueText, window.resetText]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct DetachedPetInteractionBridge: NSViewRepresentable {
    let size: CGSize
    let onTap: () -> Void
    let onDragStarted: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> DetachedPetInteractionView {
        let view = DetachedPetInteractionView(frame: NSRect(origin: .zero, size: size))
        update(view)
        return view
    }

    func updateNSView(_ nsView: DetachedPetInteractionView, context: Context) {
        nsView.frame = NSRect(origin: .zero, size: size)
        update(nsView)
    }

    private func update(_ view: DetachedPetInteractionView) {
        view.onTap = onTap
        view.onDragStarted = onDragStarted
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

private final class DetachedPetInteractionView: NSView {
    var onTap: () -> Void = {}
    var onDragStarted: () -> Void = {}
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    private let dragThreshold: CGFloat = 3
    private var mouseDownPoint: CGPoint?
    private var hasStartedDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint else { return }

        let currentPoint = convert(event.locationInWindow, from: nil)
        let translation = CGSize(
            width: currentPoint.x - mouseDownPoint.x,
            height: currentPoint.y - mouseDownPoint.y
        )

        if !hasStartedDrag, hypot(translation.width, translation.height) >= dragThreshold {
            hasStartedDrag = true
            onDragStarted()
        }

        guard hasStartedDrag else { return }
        onDragChanged(translation)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            hasStartedDrag = false
        }

        if hasStartedDrag {
            onDragEnded()
            return
        }

        onTap()
    }
}

private struct DetachedFloatingMascotView: View {
    let kind: MascotKind
    let status: MascotStatus
    let petMetrics: DetachedIslandPetMetrics
    let isDragging: Bool

    private var renderSize: CGFloat {
        petMetrics.mascotDisplaySize * DetachedIslandPanelMetrics.mascotRenderScale
    }

    private var displayScale: CGFloat {
        petMetrics.mascotDisplaySize / renderSize
    }

    var body: some View {
        MascotView(
            kind: kind,
            status: status,
            size: renderSize,
            isDragging: isDragging
        )
        .frame(width: renderSize, height: renderSize)
        .scaleEffect(displayScale)
        .frame(
            width: petMetrics.mascotDisplaySize,
            height: petMetrics.mascotDisplaySize
        )
        .compositingGroup()
        .drawingGroup(opaque: false, colorMode: .linear)
        .allowsHitTesting(false)
    }
}

private struct DetachedIslandBubbleChrome<Content: View>: View {
    let placement: DetachedIslandBubblePlacement
    @ViewBuilder let content: Content
    @Environment(\.islandExperienceTheme) private var theme

    var body: some View {
        let shape = DetachedIslandBubbleShape(placement: placement)

        ZStack(alignment: .topLeading) {
            shape.fill(theme.visual.detachedSurface)

            ExperienceThemeGridTexture()
                .mask(shape)

            content
                .padding(.horizontal, DetachedIslandPanelMetrics.bubbleHorizontalPadding)
                .padding(.vertical, DetachedIslandPanelMetrics.bubbleVerticalPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
            .compositingGroup()
            .mask(shape)
            .padding(DetachedIslandPanelMetrics.bubbleRenderInset)
    }
}

struct DetachedIslandBubbleShape: Shape {
    let placement: DetachedIslandBubblePlacement

    func path(in rect: CGRect) -> Path {
        let radius = min(
            DetachedIslandPanelMetrics.bubbleCornerRadius,
            min(rect.width, rect.height) / 2
        )
        return Path(roundedRect: rect, cornerRadius: radius)
    }
}
