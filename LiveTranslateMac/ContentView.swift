import SwiftUI

struct ContentView: View {
    private let catalogResult: Result<ModelCatalog, Error> = {
        Result { try ModelCatalog.loadFromBundle() }
    }()

    var body: some View {
        switch catalogResult {
        case .success(let catalog):
            MacRoot(catalog: catalog)
        case .failure:
            ContentUnavailableView(
                "Catalog missing",
                systemImage: "doc.text",
                description: Text("The app could not read model-catalog.json from its bundle.")
            )
            .frame(minWidth: 960, minHeight: 640)
        }
    }
}

struct MacRoot: View {
    @StateObject private var controller: SessionController

    init(catalog: ModelCatalog) {
        _controller = StateObject(
            wrappedValue: SessionController(
                catalog: catalog,
                packID: PackPolicy.macPackID,
                platform: "macos",
                storage: AppStorageRoot.url()
            )
        )
    }

    var body: some View {
        SessionScreen(controller: controller, shell: .mac, landscape: false, regularWidth: true)
            .frame(minWidth: SessionLayout.windowMinWidth, minHeight: SessionLayout.windowMinHeight)
    }
}
