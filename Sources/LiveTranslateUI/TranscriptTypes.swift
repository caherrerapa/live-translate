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

extension UTType {
    /// Markdown, so a saved export is a real .md file rather than .md.txt.
    static let markdownText = UTType("net.daringfireball.markdown")
        ?? UTType(filenameExtension: "md", conformingTo: .plainText)
        ?? .plainText
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .markdownText] }
    static var writableContentTypes: [UTType] { [.markdownText, .plainText, .json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}


extension Color {
    /// 0xRRGGBB, as written in the design file.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Values from the "Mac app — live session" design (MacLiveSession.dc.html).
enum Theme {
    static let accent = Color(hex: 0x3A43B8)
    static let accentDark = Color(hex: 0x2B3290)
    /// Pressed summary toggle and Copy button backgrounds.
    static let accentSoft = Color(hex: 0xECEEFB)
    static let accentPressed = Color(hex: 0xE1E4F8)
    static let accentPressedBorder = Color(hex: 0xC7CBEF)
    static let accentOnDark = Color(hex: 0xD9DCF7)
    static let waveQuiet = Color(hex: 0x9AA0E3)
    static let selection = Color(hex: 0xECEEFB)
    static let text = Color(hex: 0x1C1C1E)
    static let secondary = Color(hex: 0x6E6E73)
    static let tertiary = Color(hex: 0x636366)
    static let speakerName = Color(hex: 0x4A4A52)
    static let hairline = Color(hex: 0xEFEFF2)
    static let border = Color(hex: 0xE5E5EA)
    static let chipBorder = Color(hex: 0xE0E0E6)
    static let rowHighlight = Color(hex: 0xF6F6F9)
    static let pillFill = Color(hex: 0xF4F4F7)
    static let pauseFill = Color(hex: 0xF2F2F7)
    static let panel = Color(hex: 0xFAFAFC)
    static let hover = Color(hex: 0xF6F6F9)
    static let sidebar = Color(hex: 0xFAFAFC)
    static let live = Color(hex: 0xD93036)
    static let menuBorder = Color.black.opacity(0.1)
    /// Speaker dots: the design's orange and teal first, then six more.
    static let speakers: [Color] = [
        Color(hex: 0xE8622E), Color(hex: 0x12A397), Color(hex: 0x4F6BD8), Color(hex: 0x9B5BD0),
        Color(hex: 0xD6457E), Color(hex: 0x3A43B8), Color(hex: 0xD99A1E), Color(hex: 0x8A6A4E),
    ]
    /// Captions panel.
    static let captionFill = Color(hex: 0x1C1C1E)
    static let captionBorder = Color(hex: 0x3A3A3C)
    static let captionLive = Color(hex: 0xFF5A5F)
    static let captionMuted = Color(hex: 0xAEAEB2)
    static let captionIcon = Color(hex: 0xD1D1D6)

    /// Body text in a language: Thai uses Sukhumvit Set at 17 pt, the rest SF at 16 pt.
    static func body(_ language: SpeechLanguage, size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        if language == .thai {
            return .custom("Sukhumvit Set", size: size ?? 17).weight(weight)
        }
        return .system(size: size ?? 16, weight: weight)
    }

    /// Extra space between lines so text lands on the design's line heights (1.55 SF, 1.65 Thai).
    /// Calibrated against the design rendered in WebKit.
    static func lineSpacing(_ language: SpeechLanguage, size: CGFloat? = nil) -> CGFloat {
        language == .thai ? (size ?? 17) * 0.09 : (size ?? 16) * 0.27
    }

    /// CSS puts half the extra leading above the first line; SwiftUI's lineSpacing does not.
    static func leadingInset(_ language: SpeechLanguage, size: CGFloat? = nil) -> CGFloat {
        language == .thai ? 2.5 : 3
    }
}

/// The design's 15 pt checkbox: white with a grey outline, accent-filled with a white check when on.
struct DesignCheckbox: View {
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(checked ? Theme.accent : Color.white)
                RoundedRectangle(cornerRadius: 3.5)
                    .strokeBorder(checked ? Theme.accent : Color(hex: 0x8E8E93), lineWidth: 1)
                if checked {
                    Glyph(kind: .check, size: 11, lineWidth: 2)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// The design's 16×16 stroke icons, drawn from its SVG paths.
struct Glyph: View {
    enum Kind {
        case copy, chevronDown, chevronUp, sessions, summary, swap, pause, play, stop
        case lines, columns, bullets, check, keepOnTop, expand, close, mic, speaker
    }

    let kind: Kind
    var size: CGFloat = 16
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, canvas in
            let scale = canvas.width / 16
            context.scaleBy(x: scale, y: scale)
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            let ink = GraphicsContext.Shading.foreground
            switch kind {
            case .stop:
                context.fill(Path(roundedRect: CGRect(x: 2, y: 2, width: 12, height: 12), cornerRadius: 2.5), with: ink)
            case .play:
                var path = Path()
                path.move(to: CGPoint(x: 4.5, y: 3)); path.addLine(to: CGPoint(x: 13, y: 8)); path.addLine(to: CGPoint(x: 4.5, y: 13)); path.closeSubpath()
                context.fill(path, with: ink)
            case .bullets:
                context.stroke(Self.path(kind), with: ink, style: style)
                for y in [4.0, 8.0, 12.0] {
                    // r 0.6 plus the 1.5 stroke the SVG also applies to the dots.
                    context.fill(Path(ellipseIn: CGRect(x: 2.75 - 1.35, y: y - 1.35, width: 2.7, height: 2.7)), with: ink)
                }
            default:
                context.stroke(Self.path(kind), with: ink, style: style)
            }
        }
        .frame(width: size, height: size)
    }

    private static func path(_ kind: Kind) -> Path {
        var p = Path()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            p.move(to: CGPoint(x: first.0, y: first.1))
            for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
        }
        switch kind {
        case .copy:
            p.addRoundedRect(in: CGRect(x: 5.5, y: 5.5, width: 8, height: 8), cornerSize: CGSize(width: 1.5, height: 1.5))
            p.move(to: CGPoint(x: 10.5, y: 5.5)); p.addLine(to: CGPoint(x: 10.5, y: 3.5))
            p.addQuadCurve(to: CGPoint(x: 9.5, y: 2.5), control: CGPoint(x: 10.5, y: 2.5))
            p.addLine(to: CGPoint(x: 3.5, y: 2.5))
            p.addQuadCurve(to: CGPoint(x: 2.5, y: 3.5), control: CGPoint(x: 2.5, y: 2.5))
            p.addLine(to: CGPoint(x: 2.5, y: 9.5))
            p.addQuadCurve(to: CGPoint(x: 3.5, y: 10.5), control: CGPoint(x: 2.5, y: 10.5))
            p.addLine(to: CGPoint(x: 5.5, y: 10.5))
        case .chevronDown: line([(4.5, 6.5), (8, 10), (11.5, 6.5)])
        case .chevronUp: line([(4.5, 9.5), (8, 6), (11.5, 9.5)])
        case .sessions:
            p.addRoundedRect(in: CGRect(x: 2, y: 3, width: 12, height: 10), cornerSize: CGSize(width: 2, height: 2))
            line([(6, 3), (6, 13)])
        case .summary:
            p.addRoundedRect(in: CGRect(x: 2, y: 3, width: 12, height: 10), cornerSize: CGSize(width: 2, height: 2))
            line([(10, 3), (10, 13)])
        case .swap:
            line([(3, 5.5), (13, 5.5)]); line([(10.5, 3), (13, 5.5), (10.5, 8)])
            line([(13, 10.5), (3, 10.5)]); line([(5.5, 8), (3, 10.5), (5.5, 13)])
        case .pause: line([(5.5, 3.5), (5.5, 12.5)]); line([(10.5, 3.5), (10.5, 12.5)])
        case .lines: line([(3, 4), (13, 4)]); line([(3, 8), (13, 8)]); line([(3, 12), (9, 12)])
        case .columns:
            p.addRoundedRect(in: CGRect(x: 2, y: 3, width: 12, height: 10), cornerSize: CGSize(width: 1.5, height: 1.5))
            line([(8, 3), (8, 13)])
        case .bullets: line([(5.5, 4), (13.5, 4)]); line([(5.5, 8), (13.5, 8)]); line([(5.5, 12), (13.5, 12)])
        case .check: line([(3.5, 8.5), (6.5, 11.5), (12.5, 4.5)])
        case .keepOnTop: line([(8, 11), (8, 3)]); line([(4.5, 6.5), (8, 3), (11.5, 6.5)]); line([(3, 13.5), (13, 13.5)])
        case .expand:
            line([(9.5, 2.5), (13.5, 2.5), (13.5, 6.5)]); line([(13.5, 2.5), (9, 7)])
            line([(6.5, 13.5), (2.5, 13.5), (2.5, 9.5)]); line([(2.5, 13.5), (7, 9)])
        case .close: line([(4, 4), (12, 12)]); line([(12, 4), (4, 12)])
        case .mic:
            p.addRoundedRect(in: CGRect(x: 6, y: 2, width: 4, height: 8), cornerSize: CGSize(width: 2, height: 2))
            p.move(to: CGPoint(x: 3.5, y: 7.5)); p.addQuadCurve(to: CGPoint(x: 12.5, y: 7.5), control: CGPoint(x: 8, y: 15))
            line([(8, 11.5), (8, 14)])
        case .speaker:
            line([(2.5, 6), (5, 6), (8.5, 3), (8.5, 13), (5, 10), (2.5, 10), (2.5, 6)])
            p.move(to: CGPoint(x: 11, y: 5.5)); p.addQuadCurve(to: CGPoint(x: 11, y: 10.5), control: CGPoint(x: 13, y: 8))
        case .stop, .play: break
        }
        return p
    }
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
