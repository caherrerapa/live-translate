import Foundation

enum SessionControl: String, Equatable, Hashable, CaseIterable {
    case direction
    case listenStop
    case highlight
    case speakers
    case notes
    case fast
    case balanced
    case accurate
    case models
    case type
    case copy
    case save
    case conversation
    case notesPage

    var title: String {
        switch self {
        case .direction: return "direction"
        case .listenStop: return "Listen/Stop"
        case .highlight: return "Highlight"
        case .speakers: return "speakers"
        case .notes: return "notes"
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        case .models: return "Models"
        case .type: return "Type"
        case .copy: return "Copy"
        case .save: return "Save"
        case .conversation: return "Conversation"
        case .notesPage: return "Notes"
        }
    }
}

struct SessionChrome: Equatable {
    var alwaysVisible: [SessionControl]
    var secondary: [SessionControl]
    var navigationBar: [SessionControl]
    var bottomProminent: SessionControl?
    var bottomBeside: [SessionControl]
    var pageSwitch: [SessionControl]
    var prominent: SessionControl

    static func describe(shell: AppShell) -> SessionChrome {
        switch shell {
        case .mac, .pad:
            return SessionChrome(
                alwaysVisible: [.direction, .listenStop],
                secondary: [
                    .highlight, .speakers, .notes,
                    .fast, .balanced, .accurate,
                    .models, .type, .copy, .save,
                ],
                navigationBar: [],
                bottomProminent: nil,
                bottomBeside: [],
                pageSwitch: [],
                prominent: .listenStop
            )
        case .phone:
            return SessionChrome(
                alwaysVisible: [],
                secondary: [],
                navigationBar: [.direction, .models],
                bottomProminent: .listenStop,
                bottomBeside: [.highlight],
                pageSwitch: [.conversation, .notesPage],
                prominent: .listenStop
            )
        }
    }
}
