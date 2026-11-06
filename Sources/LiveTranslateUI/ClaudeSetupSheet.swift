#if os(macOS)
import AppKit
import SwiftUI

/// File → Connect to Claude…: lets the Claude app you are signed into read your sessions.
/// Claude runs this app with `--mcp`; nothing is sent anywhere until you ask Claude about a session.
struct ClaudeSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var inDesktop = ClaudeConnection.isInDesktopConfig
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Claude").font(.title2.weight(.semibold))
            Text("Claude reads your sessions through Live Translate's MCP server, using the Claude account you're signed into and its other connectors. Ask it things like “Summarize my last meeting and draft the follow-up email”, or “Add the action items from today's supplier call to my tasks”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Claude Desktop", systemImage: inDesktop ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(inDesktop ? Color.green : Color.primary)
                            .font(.headline)
                        Spacer()
                        Button(inDesktop ? "Update" : "Add to Claude Desktop") { addToDesktop() }
                    }
                    Text("Adds “\(MCPServer.name)” to Claude Desktop's MCP servers. Restart Claude Desktop afterwards.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Claude Code", systemImage: "terminal").font(.headline)
                        Spacer()
                        Button(copied ? "Copied" : "Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ClaudeConnection.claudeCodeCommand, forType: .string)
                            copied = true
                        }
                    }
                    Text(verbatim: ClaudeConnection.claudeCodeCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                .padding(6)
            }

            Text("Claude can list, read and search sessions. It can't change or delete them, and it never gets audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let message {
                Text(message).font(.callout)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private func addToDesktop() {
        do {
            try ClaudeConnection.addToDesktopConfig()
            inDesktop = true
            message = "Added. Quit and reopen Claude Desktop to see Live Translate's tools."
        } catch {
            message = "Couldn't update Claude Desktop's settings: \(error.localizedDescription)"
        }
    }
}
#endif
