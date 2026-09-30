import SwiftUI

/// A single component/sound implementation with two classic visual palettes.
enum PixelExperienceTheme {
    static let allDefinitions = PixelThemePaletteID.allCases.map(definition(for:))

    static func definition(for paletteID: PixelThemePaletteID) -> IslandExperienceTheme {
        let palette = Palette(id: paletteID)
        return IslandExperienceTheme(
            id: .pixel,
            pixelPaletteID: paletteID,
            metadata: ExperienceThemeMetadata(
                displayName: "Pixel",
                description: "像素字形、游戏机图标和 AgentIsland 8-bit 音效。",
                extensionNote: "\(paletteID.displayName)：\(paletteID.description)"
            ),
            visual: ExperienceThemeVisualTokens(
                detachedSurface: palette.background,
                settingsSurface: palette.background,
                settingsSidebarSurface: palette.sidebar,
                settingsDetailSurface: palette.detail,
                settingsCardSurface: palette.card,
                settingsCardBorder: palette.border,
                previewSurface: palette.detail,
                previewSidebarSurface: palette.sidebar,
                primaryText: palette.primaryText,
                secondaryText: palette.secondaryText,
                accent: palette.accent,
                controlCornerRadius: 2,
                settingsCornerRadius: 4,
                sectionCornerRadius: 3,
                controlFontDesign: .monospaced,
                customFontName: "Silkscreen-Bold",
                settingsChromeStyle: .pixel,
                usesPixelGrid: true,
                usesGlassMaterial: false
            ),
            interaction: ExperienceThemeInteractionTokens(
                approve: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.08, green: 0.42, blue: 0.22),
                    border: Color(red: 0.32, green: 0.98, blue: 0.53)
                ),
                scopedApproval: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.10, green: 0.28, blue: 0.64),
                    border: Color(red: 0.34, green: 0.70, blue: 1.00)
                ),
                deny: .init(
                    foreground: palette.actionForeground,
                    background: Color(red: 0.58, green: 0.12, blue: 0.20),
                    border: Color(red: 1.00, green: 0.42, blue: 0.48)
                ),
                neutral: .init(
                    foreground: palette.primaryText,
                    background: palette.neutralControl,
                    border: palette.border
                )
            ),
            motion: ExperienceThemeMotionTokens(
                controlPressScale: 0.97,
                controlPressDuration: 0.10,
                panelResponse: 0.24,
                panelDampingFraction: 0.90
            ),
            sound: soundProfile
        )
    }

    /// Exact game-style mappings carried forward from AgentIsland.
    private static let soundProfile = ExperienceThemeSoundProfile(
        recommendedMode: .island8Bit,
        lifecycleCues: [
            .processingStarted: cue(.tink, .menuSelect, .processingStarted),
            .attentionRequired: cue(.glass, .approvalAlert, .attentionRequired),
            .taskCompleted: cue(.blow, .completeDing, .taskCompleted),
            .taskError: cue(.basso, .errorBuzz, .taskError),
            .resourceLimit: cue(.morse, .hurt, .resourceLimit)
        ],
        auxiliaryCues: [
            .clientStarted: cue(.hero, .bootJingle, .processingStarted),
            .islandDetached: cue(.pop, .bubblePop, .processingStarted),
            .sessionStarted: cue(.hero, .bootJingle, .processingStarted),
            .approvalAccepted: cue(.ping, .itemPickup, .attentionRequired),
            .approvalScoped: cue(.glass, .menuSelect, .attentionRequired),
            .approvalRejected: cue(.basso, .errorBuzz, .taskError),
            .idleReminder: cue(.purr, .menuHighlight, .attentionRequired),
            .usageWarning: cue(.submarine, .approvalAlert, .resourceLimit),
            .usageReset: cue(.glass, .powerUp, .taskCompleted),
            .rapidSubmit: cue(.pop, .itemPickup, .processingStarted)
        ]
    )

    private static func cue(
        _ systemSound: NotificationSound,
        _ islandSound: Island8BitSound,
        _ fallback: NotificationEvent
    ) -> ExperienceThemeSoundCue {
        ExperienceThemeSoundCue(
            systemSound: systemSound,
            island8BitSound: islandSound,
            soundPackFallback: fallback
        )
    }

    private struct Palette {
        let background: Color
        let sidebar: Color
        let detail: Color
        let card: Color
        let border: Color
        let primaryText: Color
        let secondaryText: Color
        let accent: Color
        let neutralControl: Color
        let actionForeground: Color

        init(id: PixelThemePaletteID) {
            switch id {
            case .arcadeNeon:
                background = .islandAdaptive(light: Color(red: 0.94, green: 0.97, blue: 1), dark: Color(red: 0.059, green: 0.090, blue: 0.165))
                sidebar = .islandAdaptive(light: Color(red: 0.85, green: 0.92, blue: 0.98), dark: Color(red: 0.098, green: 0.129, blue: 0.204))
                detail = .islandAdaptive(light: Color(red: 0.94, green: 0.97, blue: 1), dark: Color(red: 0.073, green: 0.106, blue: 0.180))
                card = .islandAdaptive(light: .white, dark: Color(red: 0.098, green: 0.129, blue: 0.204))
                border = .islandAdaptive(light: Color(red: 0.10, green: 0.43, blue: 0.49), dark: Color(red: 0.145, green: 0.824, blue: 0.871)).opacity(0.58)
                primaryText = .islandAdaptive(light: Color(red: 0.06, green: 0.13, blue: 0.22), dark: Color(red: 0.925, green: 0.973, blue: 1.00))
                secondaryText = .islandAdaptive(light: Color(red: 0.23, green: 0.35, blue: 0.43), dark: Color(red: 0.580, green: 0.773, blue: 0.843))
                accent = .islandAdaptive(light: Color(red: 0.04, green: 0.40, blue: 0.46), dark: Color(red: 0.145, green: 0.824, blue: 0.871))
                neutralControl = .islandAdaptive(light: Color(red: 0.83, green: 0.90, blue: 0.96), dark: Color(red: 0.115, green: 0.157, blue: 0.235))
                actionForeground = .white
            case .gameBoyOlive:
                background = .islandAdaptive(light: Color(red: 0.91, green: 0.96, blue: 0.79), dark: Color(red: 0.059, green: 0.220, blue: 0.059))
                sidebar = .islandAdaptive(light: Color(red: 0.81, green: 0.89, blue: 0.64), dark: Color(red: 0.129, green: 0.310, blue: 0.129))
                detail = .islandAdaptive(light: Color(red: 0.93, green: 0.97, blue: 0.83), dark: Color(red: 0.086, green: 0.227, blue: 0.094))
                card = .islandAdaptive(light: Color(red: 0.96, green: 0.98, blue: 0.88), dark: Color(red: 0.165, green: 0.341, blue: 0.157))
                border = .islandAdaptive(light: Color(red: 0.29, green: 0.42, blue: 0.08), dark: Color(red: 0.608, green: 0.737, blue: 0.059)).opacity(0.72)
                primaryText = .islandAdaptive(light: Color(red: 0.07, green: 0.22, blue: 0.07), dark: Color(red: 0.878, green: 0.973, blue: 0.812))
                secondaryText = .islandAdaptive(light: Color(red: 0.24, green: 0.34, blue: 0.16), dark: Color(red: 0.722, green: 0.831, blue: 0.643))
                accent = .islandAdaptive(light: Color(red: 0.28, green: 0.41, blue: 0.04), dark: Color(red: 0.608, green: 0.737, blue: 0.059))
                neutralControl = .islandAdaptive(light: Color(red: 0.83, green: 0.90, blue: 0.69), dark: Color(red: 0.137, green: 0.302, blue: 0.125))
                actionForeground = .white
            }
        }
    }
}
