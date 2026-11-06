import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let controller = model.controller {
            // The split view's toolbar strip (52 pt) sits above this content, so the
            // window's own minimum lands on the spec's 960 × 640.
            MacSessionView(controller: controller)
                .frame(minWidth: SessionLayout.windowMinWidth, minHeight: SessionLayout.windowMinHeight - 52)
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
