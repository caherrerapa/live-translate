import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let controller = model.controller {
            MacSessionView(controller: controller)
                .frame(minWidth: SessionLayout.windowMinWidth, minHeight: SessionLayout.windowMinHeight)
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
