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
    @Environment(\.scenePhase) private var scenePhase

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
        // Auto-lock mid-meeting would background the app; keep the screen on while listening.
        .onChange(of: controller.engine.listening) { _, listening in
            UIApplication.shared.isIdleTimerDisabled = listening
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.saveLiveSession() }
        }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.environment["LT_IOS_PROBE"] != nil {
                let report = await AppleEngines.probe()
                print("PROBE\n" + report)
                if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    try? report.write(to: documents.appendingPathComponent("apple-probe.txt"), atomically: true, encoding: .utf8)
                }
                return
            }
            // LT_DEMO=1 fills the screen with the design's content, for simulator screenshots.
            if ProcessInfo.processInfo.environment["LT_DEMO"] != nil {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                controller.loadDemo()
                controller.phoneShowsNotes = ProcessInfo.processInfo.environment["LT_DEMO"] == "summary"
                if ProcessInfo.processInfo.environment["LT_ORIENT"] == "landscape",
                   let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
                return
            }
            #endif
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
