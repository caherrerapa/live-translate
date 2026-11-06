#if os(macOS)
import AppKit
import SwiftUI

/// A dark caption bar that floats above other apps: the latest line in the spoken
/// language, small, and its translation, large. Drag it anywhere.
struct CaptionsWindow: View {
    static let id = "captions"
    @ObservedObject var controller: SessionController
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var large = false

    private var turn: SessionTurn? {
        controller.engine.turns.last { !$0.sourceDisplay.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if controller.engine.listening {
                    HStack(spacing: 5) {
                        Circle().fill(controller.paused ? Color.orange : .red).frame(width: 7, height: 7)
                        Text(controller.paused ? "Paused" : "Live").fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                } else {
                    Text("Not listening").fontWeight(.semibold).foregroundStyle(.white.opacity(0.7))
                }
                Text(subtitle)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer()
                barButton("arrow.up.forward.app", "Show Live Translate") { showMainWindow() }
                barButton(large ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", large ? "Smaller" : "Larger") {
                    withAnimation(.easeOut(duration: 0.15)) { large.toggle() }
                }
                barButton("xmark", "Close captions") { dismissWindow(id: Self.id) }
            }
            .font(.caption)
            if let turn {
                Text(verbatim: turn.sourceDisplay)
                    .font(.system(size: large ? 16 : 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.head)
                let translation = turn.translationCommitted + turn.translationProvisional
                Text(verbatim: translation.isEmpty ? "…" : translation)
                    .font(.system(size: large ? 30 : 22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(controller.engine.listening ? "Waiting for speech…" : "Press Listen in Live Translate to start captions.")
                    .font(.system(size: large ? 22 : 17))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minWidth: 420, idealWidth: large ? 900 : 640, maxWidth: 1400, alignment: .leading)
        .background(Color.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
    }

    private var subtitle: String {
        let direction = controller.engine.direction.title
        guard let speaker = turn?.speakerLabel, !speaker.isEmpty else { return direction }
        return "\(direction) · \(speaker)"
    }

    private func barButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 20)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(help)
    }

    private func showMainWindow() {
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}
#endif
