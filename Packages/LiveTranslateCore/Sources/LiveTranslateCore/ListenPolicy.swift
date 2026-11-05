import CoreGraphics
import Foundation

enum ListenState: Equatable {
    case packMissing(packName: String)
    case microphoneDenied
    case idle
    case listening
    case listeningSilence
}

enum ListenPolicy {
    static let idleLine = "Listen to translate the room."

    static func state(
        packInstalled: Bool,
        packName: String,
        microphoneDenied: Bool,
        listening: Bool,
        hasLivePartial: Bool
    ) -> ListenState {
        if !packInstalled {
            return .packMissing(packName: packName)
        }
        if microphoneDenied {
            return .microphoneDenied
        }
        if !listening {
            return .idle
        }
        if !hasLivePartial {
            return .listeningSilence
        }
        return .listening
    }

    static func listenEnabled(_ state: ListenState) -> Bool {
        switch state {
        case .packMissing, .microphoneDenied:
            return false
        case .idle, .listening, .listeningSilence:
            return true
        }
    }
}

enum PanelArrangement: String, Equatable {
    case sideBySide
    case stacked
}

enum AppShell: String, Equatable {
    case mac
    case phone
    case pad
}

enum SessionLayout {
    static let notesColumnWidth: CGFloat = 320
    static let notesOpenMinWidth: CGFloat = 1280
    static let windowMinWidth: CGFloat = 960
    static let windowMinHeight: CGFloat = 640

    static func notesVisible(width: CGFloat, userHidden: Bool, shell: AppShell, regularWidth: Bool) -> Bool {
        switch shell {
        case .phone:
            return false
        case .pad:
            guard regularWidth else { return false }
            return width >= notesOpenMinWidth && !userHidden
        case .mac:
            return width >= notesOpenMinWidth && !userHidden
        }
    }

    static func arrangement(shell: AppShell, landscape: Bool, regularWidth: Bool) -> PanelArrangement {
        switch shell {
        case .mac:
            return .sideBySide
        case .phone:
            return landscape ? .sideBySide : .stacked
        case .pad:
            return regularWidth ? .sideBySide : .stacked
        }
    }
}
