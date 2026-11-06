import SwiftUI

struct LiveTranslateApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            if let controller = model.controller {
                SessionCommands(controller: controller)
            }
        }

        // Always-on-top captions for following a call or a talk while using other apps.
        Window("Live Captions", id: CaptionsWindow.id) {
            if let controller = model.controller {
                CaptionsWindow(controller: controller)
            }
        }
        .windowLevel(.floating)
        .windowStyle(.plain)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentSize)
        .defaultPosition(.bottom)
        .restorationBehavior(.disabled)
    }
}

/// Menu bar commands. The window draws only what the design shows; everything else
/// (export, Notion, audio source, models, captions, layout) lives here with its shortcut.
struct SessionCommands: Commands {
    @ObservedObject var controller: SessionController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { controller.newSession() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .importExport) {
            Menu("Export") {
                ForEach(SessionController.ExportFormat.allCases) { format in
                    Button("\(format.title)…") { controller.exportRequest = format }
                }
            }
            Button("Export to Notion…") { controller.exportToNotion() }
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Original") { controller.copySession(.original) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Copy Translation") { controller.copySession(.translation) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Copy Bilingual") { controller.copySession(.bilingual) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Copy Summary") { controller.copySession(.summary) }
                .keyboardShortcut("4", modifiers: [.command, .option])
        }
        CommandMenu("Session") {
            Button(controller.engine.listening ? "Stop" : "Listen") { controller.listenOrStop() }
                .keyboardShortcut(.return, modifiers: .command)
            Button(controller.paused ? "Resume" : "Pause") { controller.pauseOrResume() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!controller.engine.listening)
            Button("Swap Languages") { controller.swapDirection() }
                .disabled(controller.engine.listening)
            Picker("Listen To", selection: Binding(get: { controller.audioSource }, set: { controller.setAudioSource($0) })) {
                ForEach(AudioSourceKind.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            Divider()
            Button("Highlight Current Turn") { controller.highlight() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(controller.engine.speakers.chipsVisible ? "Hide Speakers" : "Show Speakers") { controller.toggleSpeakers() }
            Divider()
            Button("Manage Languages…") { controller.showModels = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button(controller.showSessions ? "Hide Sessions" : "Show Sessions") { controller.showSessions.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(controller.showSummary ? "Hide Summary" : "Show Summary") { controller.showSummary.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Floating Captions") { openWindow(id: CaptionsWindow.id) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Picker("Layout", selection: $controller.layout) {
                ForEach(TranscriptLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            Menu("Text Size") {
                Button("Larger") { controller.typeScale = min(2.0, controller.typeScale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller") { controller.typeScale = max(0.8, controller.typeScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
            Divider()
        }
    }
}

/// One session controller shared by the main window and the captions window.
@MainActor
final class AppModel: ObservableObject {
    let controller: SessionController?

    init() {
        if let catalog = try? ModelCatalog.loadFromBundle() {
            controller = SessionController(
                catalog: catalog,
                packID: PackPolicy.macPackID,
                platform: "macos",
                storage: AppStorageRoot.url()
            )
        } else {
            controller = nil
        }
    }
}
