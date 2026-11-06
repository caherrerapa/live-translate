import SwiftUI

struct LiveTranslateApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)

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
