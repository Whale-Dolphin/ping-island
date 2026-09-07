import AppKit
import SwiftUI
import XCTest
@testable import Ping_Island

/// Synthetic geometry only: no windows, persisted settings, screenshots or app launch.
@MainActor
final class DetachedIslandGeometryTests: XCTestCase {
    func testFloatingCountUsesSystemAppearanceRatherThanDarkBubbleAppearance() throws {
        XCTAssertFalse(DetachedFloatingPetAppearance.isDark(try XCTUnwrap(NSAppearance(named: .aqua))))
        XCTAssertTrue(DetachedFloatingPetAppearance.isDark(try XCTUnwrap(NSAppearance(named: .darkAqua))))
        XCTAssertEqual(DetachedFloatingPetAppearance.activeCountColor(isDark: false), .black)
        XCTAssertEqual(DetachedFloatingPetAppearance.activeCountColor(isDark: true), .white)
    }

    func testCountAndMascotReflectExecutionNotCompletedOrDisconnectedRows() {
        let active = session("active", phase: .processing)
        let compacting = session("compacting", phase: .compacting)
        let completed = session("completed", phase: .waitingForInput)
        var disconnected = session("disconnected", phase: .processing)
        disconnected.connectionState = .disconnected
        let approval = session("approval", phase: .waitingForApproval(PermissionContext(
            toolUseId: "tool", toolName: "Read", toolInput: nil, receivedAt: Date(timeIntervalSince1970: 100)
        )))

        XCTAssertEqual(DetachedIslandContentModel.activeCount(from: [active, compacting, completed, disconnected, approval]), 2)
        XCTAssertEqual(MascotStatus(session: active), .working)
        XCTAssertEqual(MascotStatus(session: completed), .idle)
        XCTAssertEqual(MascotStatus(session: disconnected), .idle)
        XCTAssertEqual(MascotStatus(session: approval), .warning)
    }

    func testPetMetricsPreserveMainScalingForVisualHitFrameAndCount() {
        let small = DetachedIslandPetMetrics(scale: 1)
        let large = DetachedIslandPetMetrics(scale: 2)
        XCTAssertEqual(large.petVisualFrame, small.petVisualFrame * 2)
        XCTAssertEqual(large.petHitFrame, small.petHitFrame * 2)
        XCTAssertEqual(large.mascotDisplaySize, small.mascotDisplaySize * 2)
        XCTAssertEqual(large.activeCountFontSize(for: 12), small.activeCountFontSize(for: 12) * 2)
        XCTAssertEqual(DetachedIslandPetMetrics(scale: 100).scale, DetachedIslandPetMetrics.maximumScale)
    }

    func testHoverAndPinnedBubbleHeightGrowBeyondThreeSessions() {
        let model = viewModel(width: 1440, height: 900)
        for route in [IslandExpandedRoute.hoverDashboard, .sessionList] {
            let three = DetachedIslandContentModel.bubbleContentSize(
                for: route, sessions: sessions(3), viewModel: model
            )
            let four = DetachedIslandContentModel.bubbleContentSize(
                for: route, sessions: sessions(4), viewModel: model
            )
            XCTAssertGreaterThan(four.height, three.height)
        }
    }

    func testBothListsCapAtScreenBudgetAfterCondensing() {
        let model = viewModel(width: 1440, height: 900)
        for route in [IslandExpandedRoute.hoverDashboard, .sessionList] {
            let size = DetachedIslandContentModel.bubbleContentSize(
                for: route, sessions: sessions(24), viewModel: model
            )
            XCTAssertEqual(size.height, 740)
            XCTAssertLessThan(size.width, model.screenRect.width)
        }
    }

    func testAirListCondensesBeforeItNeedsScrolling() {
        let model = viewModel(width: 1470, height: 956)
        let selected = sessions(11)
        let footer = DetachedIslandPanelMetrics.usageFooterReservedHeight
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: selected, viewModel: model, additionalFooterHeight: footer
        ), .constrained)
        XCTAssertLessThan(DetachedIslandContentModel.bubbleContentSize(
            for: .sessionList, sessions: selected, viewModel: model, additionalFooterHeight: footer
        ).height, DetachedIslandContentModel.maximumBubbleContentHeight(for: model))
    }

    func testProListKeepsRegularRowsWhenTheyFit() {
        let model = viewModel(width: 1920, height: 1080)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: sessions(11), viewModel: model,
            additionalFooterHeight: DetachedIslandPanelMetrics.usageFooterReservedHeight
        ), .regular)
    }

    func testHoverDensityCondensesOnAirButNotProForSameSessions() {
        let selected = sessions(9)
        XCTAssertTrue(DetachedIslandContentModel.hoverDashboardUsesCondensedRows(
            for: selected, viewModel: viewModel(width: 1470, height: 956)
        ))
        XCTAssertFalse(DetachedIslandContentModel.hoverDashboardUsesCondensedRows(
            for: selected, viewModel: viewModel(width: 1920, height: 1080)
        ))
    }

    func testFooterParticipatesInDensityBudget() {
        let model = viewModel(width: 1440, height: 950)
        let selected = sessions(10)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: selected, viewModel: model
        ), .regular)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: selected, viewModel: model,
            additionalFooterHeight: DetachedIslandPanelMetrics.usageFooterReservedHeight
        ), .constrained)
    }

    func testCompletedRowsDoNotInflateFloatingGeometryOrOpenPinnedList() {
        let model = viewModel(width: 1470, height: 956)
        let active = sessions(4)
        let completed = (1...20).map { session("completed-\($0)", phase: .waitingForInput) }
        XCTAssertFalse(DetachedIslandContentModel.canPresentBubble(from: completed, mode: .pinnedList))
        for route in [IslandExpandedRoute.hoverDashboard, .sessionList] {
            XCTAssertEqual(
                DetachedIslandContentModel.bubbleContentSize(for: route, sessions: active, viewModel: model),
                DetachedIslandContentModel.bubbleContentSize(for: route, sessions: active + completed, viewModel: model)
            )
        }
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: active + completed, viewModel: model
        ), .regular)
    }

    func testCenteredPetCapsTallListsToActualPlacementSpaceWithoutMovingAnchor() throws {
        let model = viewModel(width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 850)
        let anchor = CGPoint(x: 720, y: 450)
        for state in [DetachedIslandBubbleState.hoverPreview, .pinned] {
            let layout = DetachedIslandContentModel.layout(
                for: sessions(24), viewModel: model, bubbleState: state, bubblePlacement: .topLeft,
                petScreenAnchor: anchor, availableFrame: visibleFrame, petMetrics: DetachedIslandPetMetrics.standard
            )
            let bubble = try XCTUnwrap(layout.bubbleFrame)
            let budget = try XCTUnwrap(layout.maximumBubbleContentSize)
            let origin = DetachedIslandWindowController.windowOrigin(preservingPetAnchorAt: anchor, layout: layout)
            let windowFrame = CGRect(origin: origin, size: layout.containerSize)
            let screenBubble = CGRect(
                x: origin.x + bubble.minX, y: windowFrame.maxY - bubble.maxY,
                width: bubble.width, height: bubble.height
            )
            XCTAssertTrue(visibleFrame.contains(screenBubble), "Offscreen bubble: \(screenBubble)")
            XCTAssertLessThan(bubble.height, DetachedIslandContentModel.maximumBubbleContentHeight(for: model))
            XCTAssertLessThanOrEqual(bubble.height, budget.height)
            XCTAssertEqual(DetachedIslandWindowController.petAnchorScreenPoint(for: windowFrame, layout: layout), anchor)

            let renderedState = DetachedIslandBubbleViewState()
            renderedState.setWindowLayout(layout)
            XCTAssertEqual(renderedState.windowLayout, layout)
        }
    }

    func testAnchoredDensityUsesPlacementBudgetInsteadOfWholeProScreen() throws {
        let model = viewModel(width: 1920, height: 1080)
        let layout = DetachedIslandContentModel.layout(
            for: sessions(11), viewModel: model, bubbleState: .pinned, bubblePlacement: .topLeft,
            petScreenAnchor: CGPoint(x: 960, y: 540),
            availableFrame: CGRect(x: 0, y: 24, width: 1920, height: 1032),
            petMetrics: DetachedIslandPetMetrics.standard
        )
        let budget = try XCTUnwrap(layout.maximumBubbleContentSize)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(for: sessions(11), viewModel: model), .regular)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: sessions(11), viewModel: model, maximumContentHeight: budget.height
        ), .constrained)
        XCTAssertEqual(DetachedIslandContentModel.sessionListDensity(
            for: sessions(4), viewModel: model, maximumContentHeight: budget.height
        ), .regular)
        XCTAssertFalse(DetachedIslandContentModel.hoverDashboardUsesCondensedRows(for: sessions(9), viewModel: model))
        XCTAssertTrue(DetachedIslandContentModel.hoverDashboardUsesCondensedRows(
            for: sessions(9), viewModel: model, maximumContentHeight: budget.height
        ))
    }

    func testPlacementBudgetMatchesScaledOverlapOnOffsetDisplay() {
        let visibleFrame = CGRect(x: -1920, y: 32, width: 1920, height: 1000)
        let anchor = CGPoint(x: -960, y: 500)
        for scale: CGFloat in [1, 2.5] {
            let metrics = DetachedIslandPetMetrics(scale: scale)
            for placement in DetachedIslandBubblePlacement.allCases {
                let budget = DetachedIslandContentModel.availableBubbleContentSize(
                    for: placement, petScreenAnchor: anchor, availableFrame: visibleFrame, petMetrics: metrics
                )
                let frame = DetachedIslandContentModel.bubbleScreenFrame(
                    for: placement, petScreenAnchor: anchor, petMetrics: metrics,
                    bubbleSize: CGSize(width: min(392, budget.width), height: min(700, budget.height))
                )
                XCTAssertTrue(visibleFrame.contains(frame), "Offscreen \(placement) at scale \(scale): \(frame)")
            }
        }
    }

    func testSmallPlacementBudgetOverridesNotificationAndListMinimumHeights() {
        let model = viewModel(width: 1440, height: 900)
        let prompt = session("prompt", phase: .waitingForInput)
        let completion = SessionCompletionNotification(session: prompt, kind: .completed)
        for route in [IslandExpandedRoute.sessionList, .hoverDashboard, .attentionNotification(prompt), .completionNotification(completion)] {
            let size = DetachedIslandContentModel.bubbleContentSize(
                for: route, sessions: sessions(2), viewModel: model,
                maximumSize: CGSize(width: 240, height: 70)
            )
            XCTAssertLessThanOrEqual(size.height, 70)
            XCTAssertLessThanOrEqual(size.width, 240)
        }
    }

    private func sessions(_ count: Int) -> [SessionState] {
        (1...count).map { session("active-\($0)", phase: .processing) }
    }

    private func session(_ id: String, phase: SessionPhase) -> SessionState {
        SessionState(sessionId: id, cwd: "/synthetic/workspaces/\(id)", phase: phase)
    }

    private func viewModel(width: CGFloat, height: CGFloat) -> NotchViewModel {
        NotchViewModel(
            deviceNotchRect: .zero,
            screenRect: CGRect(x: 0, y: 0, width: width, height: height),
            windowHeight: 320,
            hasPhysicalNotch: false,
            enableEventMonitoring: false,
            observeSystemEnvironment: false,
            fullscreenActivityProvider: { _ in false }
        )
    }
}
