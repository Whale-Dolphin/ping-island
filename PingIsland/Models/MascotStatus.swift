import Foundation

/// Mascot animation states
enum MascotStatus: String, Codable, CaseIterable, Sendable {
    case idle = "idle"
    case working = "working"
    case warning = "warning"
    case dragging = "dragging"
    
    var displayName: String {
        switch self {
        case .idle: return "空闲中"
        case .working: return "运行中"
        case .warning: return "警告状态"
        case .dragging: return "拖拽中"
        }
    }
}

/// Extension to map session status to mascot status
extension MascotStatus {
    /// Convert from session phase to mascot status
    init(from sessionPhase: SessionPhase) {
        switch sessionPhase {
        case .idle, .ended:
            self = .idle
        case .waitingForApproval, .waitingForInput:
            self = .warning
        case .processing, .compacting:
            self = .working
        }
    }

    /// Keep the closed-notch mascot aligned with actual execution or intervention state.
    static func closedNotchStatus(
        representativePhase: SessionPhase?,
        hasPendingPermission: Bool,
        hasHumanIntervention: Bool
    ) -> MascotStatus {
        if hasPendingPermission || hasHumanIntervention {
            return .warning
        }

        switch representativePhase {
        case .processing, .compacting:
            return .working
        case .waitingForApproval:
            return .warning
        case .idle, .waitingForInput, .ended, nil:
            return .idle
        }
    }
}
