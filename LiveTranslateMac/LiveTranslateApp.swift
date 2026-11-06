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
/// (export, audio source, models, captions, layout) lives here with its shortcut.
struct SessionCommands: Commands {
    /// Not observed: an observed controller would rebuild the whole menu bar on every
    /// transcript update. Titles are fixed and each item reads the state when chosen.
    let controller: SessionController
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
            Button("Copy as Markdown") { controller.copyMarkdown() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
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
            Button("Listen / Stop") { controller.listenOrStop() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Pause / Resume") { controller.pauseOrResume() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Swap Languages") { controller.swapDirection() }
            Menu("Listen To") {
                ForEach(AudioSourceKind.allCases) { source in
                    Button(source.title) { controller.setAudioSource(source) }
                }
            }
            Divider()
            Button("Highlight Current Turn") { controller.highlight() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Show or Hide Speakers") { controller.toggleSpeakers() }
            Divider()
            Button("Manage Languages…") { controller.showModels = true }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button("Show or Hide Sessions") { controller.showSessions.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Show or Hide Summary") { controller.showSummary.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Floating Captions") { openWindow(id: CaptionsWindow.id) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Menu("Layout") {
                ForEach(TranscriptLayout.allCases) { layout in
                    Button(layout.title) { controller.layout = layout }
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
