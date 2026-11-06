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
        .task {
            guard ProcessInfo.processInfo.environment["LIVE_TRANSLATE_IOS_LISTEN"] == "1" else { return }
            await controller.refreshInstall()
            controller.listenOrStop()
            var report = controller.listenDiagnostics()
            report += "\nlisten_title \(controller.listenTitle)"
            report += "\npartials \(controller.engine.turns.map(\.sourceDisplay).joined(separator: " | "))"
            let int8 = SpeechGraphs.directoryName(language: .thai, chunkMS: 1040, precision: "int8")
            report += "\nfailure The simulator cannot load the int8 speech runtime \(int8) or the 4-bit models unless those files are installed in app storage."
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = documents.appendingPathComponent("ios-listen.txt")
                try? report.write(to: url, atomically: true, encoding: .utf8)
            }
            print(report)
        }
    }
}
