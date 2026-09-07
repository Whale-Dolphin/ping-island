import XCTest

final class PingIslandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSettingsWindowLaunchesInUITestMode() throws {
        let app = launchSettingsApp()

        XCTAssertTrue(app.buttons["settings.sidebar.general"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["settings.detail.general"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsSidebarCanSwitchToAboutPage() throws {
        let app = launchSettingsApp()

        selectSidebarCategory("about", in: app)

        XCTAssertTrue(app.scrollViews["settings.detail.about"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSettingsCategoriesSwitchWithoutBlockingContent() throws {
        let app = launchSettingsApp()

        for category in ["display", "analytics", "sound", "general", "display", "sound"] {
            let sidebarButton = selectSidebarCategory(category, in: app)
            XCTAssertTrue(
                sidebarButton.isSelected,
                "Sidebar selection for \(category) should update before detail loading finishes"
            )

            XCTAssertTrue(
                app.scrollViews["settings.detail.\(category)"].waitForExistence(timeout: 2),
                "Settings content for \(category) should become available immediately"
            )
        }
    }

    @MainActor
    func testSettingsSoundPageShowsAllExperienceThemes() throws {
        let app = launchSettingsApp()
        selectSidebarCategory("sound", in: app)

        for themeID in ["standard", "macOS", "pixel"] {
            XCTAssertTrue(
                app.buttons["settings.theme.\(themeID)"].waitForExistence(timeout: 2),
                "The \(themeID) experience theme card should remain visible"
            )
        }

        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Settings-Sound-Experience-Themes"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func launchSettingsApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["PING_ISLAND_UI_TEST_MODE"] = "1"
        app.launch()
        return app
    }

    @MainActor
    @discardableResult
    private func selectSidebarCategory(
        _ category: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let button = app.buttons["settings.sidebar.\(category)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing sidebar category \(category)")

        if !button.isHittable {
            let sidebar = app.scrollViews["settings.sidebar"]
            XCTAssertTrue(sidebar.waitForExistence(timeout: 2), "Missing settings sidebar scroll view")
            for _ in 0..<10 where !button.isHittable {
                sidebar.scroll(byDeltaX: 0, deltaY: -60)
            }
        }

        XCTAssertTrue(button.isHittable, "Sidebar category \(category) did not become hittable")
        button.click()
        return button
    }
}
