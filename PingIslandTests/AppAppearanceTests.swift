import AppKit
import SwiftUI
import XCTest
@testable import Ping_Island

@MainActor
final class AppAppearanceTests: XCTestCase {
    func testAppearancePreferenceResolvesWithoutChangingSystemAppearance() {
        XCTAssertNil(AppAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(AppAppearanceMode.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearanceMode.dark.preferredColorScheme, .dark)
        for systemIsDark in [false, true] {
            XCTAssertEqual(AppAppearanceMode.system.isDark(systemIsDark: systemIsDark), systemIsDark)
            XCTAssertFalse(AppAppearanceMode.light.isDark(systemIsDark: systemIsDark))
            XCTAssertTrue(AppAppearanceMode.dark.isDark(systemIsDark: systemIsDark))
        }
    }

    func testFloatingCountHonorsExplicitAppearanceAndSystemFallback() throws {
        for mode in AppAppearanceMode.allCases {
            for systemIsDark in [false, true] {
                let isDark = mode.isDark(systemIsDark: systemIsDark)
                let color = try resolvedColor(
                    DetachedFloatingPetAppearance.activeCountColor(isDark: isDark),
                    scheme: isDark ? .dark : .light
                )
                let expected: CGFloat = isDark ? 1 : 0
                XCTAssertEqual(color.redComponent, expected, accuracy: 0.001)
                XCTAssertEqual(color.greenComponent, expected, accuracy: 0.001)
                XCTAssertEqual(color.blueComponent, expected, accuracy: 0.001)
            }
        }
    }

    func testEveryThemeHasReadablePrimaryAndSecondaryTextInBothAppearances() throws {
        let themes = [
            ExperienceThemeRegistry.theme(for: .standard),
            ExperienceThemeRegistry.theme(for: .macOS),
            ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: .arcadeNeon),
            ExperienceThemeRegistry.theme(for: .pixel, pixelPalette: .gameBoyOlive)
        ]
        for theme in themes {
            for scheme in [ColorScheme.light, .dark] {
                let surface = try resolvedColor(theme.visual.detachedSurface, scheme: scheme)
                for text in [theme.visual.primaryText, theme.visual.secondaryText] {
                    let foreground = try resolvedColor(text, scheme: scheme)
                    XCTAssertGreaterThanOrEqual(
                        contrast(foreground, on: surface), 4.5,
                        "\(theme.id) / \(String(describing: theme.pixelPaletteID)) / \(scheme)"
                    )
                }
            }
        }
    }

    func testSwiftUIResolvesAdaptiveColorsInItsEnvironmentNotTheDesktopAppearance() throws {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content:
                HStack(spacing: 0) {
                    Color.islandForeground.frame(width: 16, height: 16)
                    Color.islandSurface.frame(width: 16, height: 16)
                }
                .environment(\.colorScheme, scheme)
            )
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
            let foreground = try XCTUnwrap(bitmap.colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
            let background = try XCTUnwrap(bitmap.colorAt(x: 24, y: 8)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(foreground.redComponent, scheme == .dark ? 1 : 0, accuracy: 0.01)
            XCTAssertEqual(background.redComponent, scheme == .dark ? 0 : 1, accuracy: 0.01)
        }
    }

    func testNativeInputTextAndPlaceholderFollowEffectiveAppearance() throws {
        let field = IslandNSTextField()
        field.placeholderString = "Enter a reply"
        for scheme in [ColorScheme.light, .dark] {
            field.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            field.configureTextAppearance()
            XCTAssertEqual(field.placeholderAttributedString?.string, "Enter a reply")
            let text = try resolvedColor(Color(nsColor: XCTUnwrap(field.textColor)), scheme: scheme)
            XCTAssertEqual(text.redComponent, scheme == .dark ? 1 : 0, accuracy: 0.01)
            let placeholder = try XCTUnwrap(
                field.placeholderAttributedString?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            )
            let placeholderColor = try resolvedColor(Color(nsColor: placeholder), scheme: scheme)
            XCTAssertEqual(placeholderColor.redComponent, text.redComponent, accuracy: 0.01)
            XCTAssertEqual(placeholderColor.alphaComponent, 0.38, accuracy: 0.01)
        }
    }

    func testSessionRowResultAndActionControlsRenderInBothAppearances() throws {
        let sessions = [
            SessionState(
                sessionId: "appearance-running", cwd: "/synthetic/workspaces/build",
                previewText: "Running the build", phase: .processing
            ),
            SessionState(
                sessionId: "appearance-preview", cwd: "/synthetic/workspaces/review",
                previewText: "Result saved successfully", phase: .ended
            )
        ]
        for theme in ExperienceThemeRegistry.all {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(content:
                    DetachedIslandBubbleChrome(placement: .topLeft) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(sessions, id: \.sessionId) { session in
                                InstanceRow(
                                    session: session, isExpanded: false, isSelected: false,
                                    isHighlighted: false, isYabaiAvailable: false,
                                    onSelect: {}, onActivate: {}, onToggleExpanded: {}, onFocus: {},
                                    onChat: {}, onOpenClient: {}, onArchive: {}, onTerminate: {},
                                    onApprove: {}, onApproveForSession: {}, onReject: {}
                                )
                            }
                            MarkdownContentView("## Completed\nThe result is ready to review.")
                            HStack {
                                ConfirmationActionButton(title: "Allow", role: .approve, action: {})
                                ConfirmationActionButton(title: "Deny", role: .deny, action: {})
                                TerminalButton(isEnabled: true, onTap: {})
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 530, height: 340)
                    .padding(8)
                    // A matching desktop is the worst case: the outline alone
                    // must still separate the panel and its first session card.
                    .background(theme.visual.detachedSurface)
                    .environment(\.islandExperienceTheme, theme)
                    .environment(\.mascotAnimationsEnabled, false)
                    .environment(\.colorScheme, scheme)
                )
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size.width, 546, accuracy: 0.01)
                XCTAssertGreaterThan(image.size.height, 100)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
                let desktop = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
                let panelEdge = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.deviceRGB))
                let cardEdge = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 52)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(abs(panelEdge.redComponent - desktop.redComponent), 0.17,
                                     "Panel boundary disappeared: \(theme.id) / \(scheme)")
                XCTAssertGreaterThan(abs(cardEdge.redComponent - desktop.redComponent), 0.14,
                                     "Session card boundary disappeared: \(theme.id) / \(scheme)")
                let attachment = XCTAttachment(image: image)
                attachment.name = "appearance-\(theme.id.rawValue)-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func resolvedColor(_ color: Color, scheme: ColorScheme) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.deviceRGB)
        }
        return try XCTUnwrap(resolved)
    }

    private func contrast(_ foreground: NSColor, on background: NSColor) -> Double {
        let alpha = foreground.alphaComponent
        let text = [foreground.redComponent, foreground.greenComponent, foreground.blueComponent]
        let surface = [background.redComponent, background.greenComponent, background.blueComponent]
        let composite = zip(text, surface).map { $0 * alpha + $1 * (1 - alpha) }
        let foregroundLuminance = luminance(composite)
        let backgroundLuminance = luminance(surface)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func luminance(_ rgb: [CGFloat]) -> Double {
        let linear = rgb.map { Double($0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)) }
        return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
    }
}
