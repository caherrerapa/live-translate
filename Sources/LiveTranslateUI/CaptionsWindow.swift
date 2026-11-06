#if os(macOS)
import AppKit
import SwiftUI

/// The "Floating captions" design: a 760 pt dark panel that stays above other apps,
/// with the latest original line (14 pt, muted) and its translation (24 pt) below.
struct CaptionsWindow: View {
    static let id = "captions"
    @ObservedObject var controller: SessionController
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var keepOnTop = true
    @State private var window: NSWindow?

    private var turn: SessionTurn? {
        controller.engine.turns.last { !$0.sourceDisplay.isEmpty }
    }

    var body: some View {
        let direction = controller.engine.direction
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.engine.listening ? (controller.paused ? Color.orange : Theme.captionLive) : Theme.captionMuted)
                        .frame(width: 7, height: 7)
                    Text(controller.engine.listening ? (controller.paused ? "Paused" : "Live") : "Not listening")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(subtitle(direction))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.captionMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    captionButton(.keepOnTop, "Keep on top", pressed: keepOnTop) {
                        keepOnTop.toggle()
                        window?.level = keepOnTop ? .floating : .normal
                    }
                    captionButton(.expand, "Open full window") { showMainWindow() }
                    captionButton(.close, "Close captions") { dismissWindow(id: Self.id) }
                }
            }
            .frame(height: 28)
            if let turn {
                Text(verbatim: turn.sourceDisplay)
                    .font(Theme.body(direction.source, size: 14))
                    .foregroundStyle(Theme.captionMuted)
                    .lineLimit(1)
                    .truncationMode(.head)
                let translation = turn.translationCommitted + turn.translationProvisional
                Text(verbatim: translation.isEmpty ? "…" : translation)
                    .font(Theme.body(direction.target, size: 24, weight: .medium))
                    .lineSpacing(24 * 0.12)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(controller.engine.listening ? "Waiting for speech…" : "Press Listen in Live Translate to start captions.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.captionMuted)
                Text(" ")
                    .font(.system(size: 24, weight: .medium))
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 14)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(width: 760, alignment: .topLeading)
        .frame(minHeight: 184, alignment: .topLeading)
        .background(Theme.captionFill, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.captionBorder))
        .environment(\.colorScheme, .dark)
        .background(WindowFinder { window = $0 })
    }

    private func subtitle(_ direction: TranslationDirection) -> String {
        guard let speaker = turn?.speakerLabel, !speaker.isEmpty else { return direction.title }
        return "\(direction.title) · \(speaker)"
    }

    /// 28 pt buttons; pressed ones get a 14% white fill.
    private func captionButton(_ glyph: Glyph.Kind, _ label: String, pressed: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Glyph(kind: glyph)
                .foregroundStyle(pressed ? Color.white : Theme.captionIcon)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(pressed ? Color.white.opacity(0.14) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func showMainWindow() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

/// Hands the hosting NSWindow to SwiftUI, for the Keep on top toggle.
private struct WindowFinder: NSViewRepresentable {
    let found: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
