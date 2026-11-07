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
    @State private var folder = MarkdownFolder.folder
    @AppStorage(GlobalHotKey.enabledKey) private var hotKeyOn = true

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        panel.message = "Live Translate saves each finished session here as a Markdown file."
        if panel.runModal() == .OK, let url = panel.url {
            MarkdownFolder.folder = url
            folder = url
        }
    }

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
            Section("Shortcut") {
                Toggle("⌃⌥Space starts and stops listening from any app", isOn: $hotKeyOn)
                Text("Live Translate also sits in the menu bar, with Listen, Stop and the latest translated line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Save sessions") {
                Toggle("Save each session as Markdown to a folder", isOn: Binding(
                    get: { folder != nil },
                    set: { on in
                        if on { chooseFolder() } else { MarkdownFolder.folder = nil; folder = nil }
                    }
                ))
                if let folder {
                    LabeledContent("Folder") {
                        HStack {
                            Text(folder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button("Change…") { chooseFolder() }
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                }
                Text("When a session ends, it is written there with its summary, who spoke, and the transcript, and updated when the summary finishes. Works well with an Obsidian vault or an iCloud Drive folder.")
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
