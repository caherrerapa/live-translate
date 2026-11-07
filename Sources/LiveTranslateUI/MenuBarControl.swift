#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The menu bar icon: filled while listening.
struct MenuBarLabel: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        Image(systemName: controller.engine.listening ? (controller.paused ? "pause.circle.fill" : "waveform.circle.fill") : "waveform.circle")
            .accessibilityLabel(controller.engine.listening ? "Live Translate, listening" : "Live Translate")
    }
}

/// The menu bar panel: status, the latest translated line, and the main controls, without
/// bringing the window forward. Handy during a call in another app.
struct MenuBarPanel: View {
    @ObservedObject var controller: SessionController
    @Environment(\.openWindow) private var openWindow
    @AppStorage(GlobalHotKey.enabledKey) private var hotKeyOn = true

    private var lastTurn: SessionTurn? {
        controller.engine.turns.last { !$0.sourceDisplay.isEmpty }
    }

    var body: some View {
        let direction = controller.engine.direction
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.engine.listening ? (controller.paused ? Color.orange : Theme.live) : Theme.secondary)
                    .frame(width: 8, height: 8)
                Text(controller.engine.listening ? (controller.paused ? "Paused" : "Listening") : "Not listening")
                    .font(.system(size: 13, weight: .semibold))
                if controller.engine.listening {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(verbatim: StatusStrip.elapsed(controller.elapsed(at: context.date)))
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(Theme.secondary)
                    }
                }
                Spacer()
                Text("\(direction.source.title) → \(direction.target.title)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            if let turn = lastTurn {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: turn.sourceDisplay)
                        .font(Theme.body(direction.source, size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                    let translation = turn.translationCommitted + turn.translationProvisional
                    Text(verbatim: translation.isEmpty ? "…" : translation)
                        .font(Theme.body(direction.target, size: 15, weight: .medium))
                        .lineLimit(3)
                        .truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.rowHighlight, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button {
                    controller.listenOrStop()
                } label: {
                    Label(controller.engine.listening ? "Stop" : "Listen", systemImage: controller.engine.listening ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(controller.engine.listening ? Theme.live : Theme.accent)
                .disabled(!controller.engine.listening && !controller.engine.listenEnabled && !controller.isPreparing)
                if controller.engine.listening {
                    Button { controller.pauseOrResume() } label: {
                        Image(systemName: controller.paused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.large)
                    .help(controller.paused ? "Resume" : "Pause")
                }
            }
            if hotKeyOn {
                Text("⌃⌥Space starts and stops listening from any app.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Divider()
            HStack {
                Button("Captions") { openWindow(id: CaptionsWindow.id) }
                Button("Open Live Translate") {
                    NSApp.activate()
                    NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// ⌃⌥Space from any app, through the system hot-key API (no Accessibility permission needed).
@MainActor
final class GlobalHotKey {
    static let enabledKey = "globalHotKey"
    private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        Self.action = action
    }

    var isRegistered: Bool { reference != nil }

    func update() {
        let wanted = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        if wanted, reference == nil { register() }
        if !wanted, reference != nil { unregister() }
    }

    private func register() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.action?() } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C54_484B), id: 1) // "LTHK"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }
}
#endif
