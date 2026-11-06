#if os(macOS)
import SwiftUI

/// Live Translate → Settings… (⌘,): General, Languages, Connections, as in the design.
struct MacSettingsView: View {
    @ObservedObject var controller: SessionController
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            MacGeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag("general")
            ModelScreen(controller: controller, library: controller.library, embedded: true)
                .tabItem { Label("Languages", systemImage: "globe") }
                .tag("languages")
            ScrollView {
                ConnectionsSettings()
                    .padding(.vertical, 24)
                    .padding(.horizontal, 48)
            }
            .background(Color(hex: 0xF5F5F7))
            .tabItem { Label("Connections", systemImage: "powerplug") }
            .tag("connections")
        }
        .frame(width: 760, height: 606)
    }
}

/// Calendar context and the Claude app's access to sessions.
private struct MacGeneralSettings: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var calendar = GoogleCalendar.shared
    @State private var showCalendar = false
    @State private var showClaude = false

    var body: some View {
        Form {
            Section("Meetings") {
                LabeledContent("Google Calendar") {
                    HStack {
                        Text(calendar.account ?? "Not connected").foregroundStyle(.secondary)
                        Button(calendar.isConnected ? "Manage…" : "Connect…") { showCalendar = true }
                    }
                }
                Text("The meeting happening now names each session and gives the summary its attendees and agenda.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("The Claude app") {
                LabeledContent("Sessions in Claude Desktop and Claude Code") {
                    Button("Set Up…") { showClaude = true }
                }
                Text("Claude, signed in with your account, can list, read and search your sessions through Live Translate's MCP server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Copy") {
                Toggle("Include speaker names", isOn: $controller.copyOptions.speakerNames)
                Toggle("Include timestamps", isOn: $controller.copyOptions.timestamps)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCalendar) { CalendarSettingsView() }
        .sheet(isPresented: $showClaude) { ClaudeSetupSheet() }
    }
}
#endif
