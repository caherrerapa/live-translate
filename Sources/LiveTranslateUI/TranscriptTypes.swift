import SwiftUI
import UniformTypeIdentifiers

/// How the transcript columns are arranged.
enum TranscriptLayout: String, CaseIterable, Identifiable {
    case sideBySide
    case stacked
    case translationOnly

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .sideBySide: return "rectangle.split.2x1"
        case .stacked: return "rectangle.split.1x2"
        case .translationOnly: return "text.alignleft"
        }
    }

    var title: String {
        switch self {
        case .sideBySide: return "Side by side"
        case .stacked: return "Stacked"
        case .translationOnly: return "Translation only"
        }
    }
}

/// One row of the transcript, from the live engine or from a saved session.
struct DisplayTurn: Identifiable, Equatable {
    var id: String
    var speaker: String
    var colorIndex: Int?
    var clock: Date
    var source: String
    var sourceTail: String
    var translation: String
    var translationProvisional: String
    var live: Bool
    var renamable: Bool

    var sourceText: String { source + sourceTail }
    var translationText: String { translation + translationProvisional }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, UTType(filenameExtension: "md") ?? .plainText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


/// Colors from the Mac live-session design.
enum Theme {
    /// Indigo used for primary actions, links, and selection.
    static let accent = Color(red: 0.23, green: 0.29, blue: 0.71)
    /// Light indigo behind the selected session and the focused turn.
    static let selection = Color(red: 0.23, green: 0.29, blue: 0.71).opacity(0.10)
    static let hover = Color.primary.opacity(0.035)
    static let sidebar = Color(red: 0.965, green: 0.965, blue: 0.972)
    static let hairline = Color.primary.opacity(0.10)
    static let live = Color(red: 0.89, green: 0.22, blue: 0.21)
    /// Speaker dots: the first two match the design (warm orange, teal), then six more.
    static let speakers: [Color] = [
        Color(red: 0.91, green: 0.42, blue: 0.22), Color(red: 0.16, green: 0.62, blue: 0.56),
        Color(red: 0.33, green: 0.45, blue: 0.86), Color(red: 0.58, green: 0.36, blue: 0.80),
        Color(red: 0.86, green: 0.33, blue: 0.56), Color(red: 0.25, green: 0.30, blue: 0.70),
        Color(red: 0.85, green: 0.62, blue: 0.16), Color(red: 0.52, green: 0.40, blue: 0.30),
    ]
}

/// White, hairline-bordered control used for pickers and menus in the header and bottom bar.
struct OutlinedControl: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(white: 1).opacity(0.001))
            .background(.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
    }
}

extension View {
    func outlined() -> some View { modifier(OutlinedControl()) }
}
