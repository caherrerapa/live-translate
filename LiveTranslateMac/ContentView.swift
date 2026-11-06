import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let controller = model.controller {
            // SwiftUI adds the 32 pt title bar to the window's minimum, but the header is
            // drawn inside that strip, so the window's own minimum lands on 960 × 640.
            MacSessionView(controller: controller)
                .frame(minWidth: SessionLayout.windowMinWidth, minHeight: SessionLayout.windowMinHeight - 32)
                .ignoresSafeArea(.container, edges: .top)
        } else {
            ContentUnavailableView(
                "Catalog missing",
                systemImage: "doc.text",
                description: Text("The app could not read model-catalog.json from its bundle.")
            )
            .frame(minWidth: 960, minHeight: 640)
        }
    }
}
