import SwiftUI

@main
struct LiveTranslateiOSApp: App {
    private let catalogResult: Result<ModelCatalog, Error> = {
        Result { try ModelCatalog.loadFromBundle() }
    }()

    var body: some Scene {
        WindowGroup {
            switch catalogResult {
            case .success(let catalog):
                PhoneRoot(catalog: catalog)
            case .failure:
                ContentUnavailableView(
                    "Catalog missing",
                    systemImage: "doc.text",
                    description: Text("The app could not read model-catalog.json from its bundle.")
                )
            }
        }
    }
}

struct PhoneRoot: View {
    @StateObject private var controller: SessionController

    init(catalog: ModelCatalog) {
        _controller = StateObject(
            wrappedValue: SessionController(
                catalog: catalog,
                packID: PackPolicy.phonePackID,
                platform: "ios",
                storage: AppStorageRoot.url()
            )
        )
    }

    var body: some View {
        AdaptiveSession(
            controller: controller,
            shell: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
        )
    }
}
