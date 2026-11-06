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

