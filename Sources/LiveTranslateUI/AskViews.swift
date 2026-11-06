import SwiftUI

/// The design's Ask panel: questions on the right, answers with the turns they come from,
/// cards for what was done in connected apps, and a composer that says where questions go.
struct AskPanel: View {
    enum Style { case mac, phone }

    @ObservedObject var controller: SessionController
    @ObservedObject var engine = AskEngine.shared
    @ObservedObject var ai = AIConnections.shared
    let style: Style
    /// Shows a cited turn (the Mac focuses it; the phone switches to the transcript).
    var showTurn: (String) -> Void = { _ in }
    /// Opens Settings → Connections.
    var openSettings: () -> Void = {}
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var record: SessionRecord { controller.displayedRecord }
    private var phone: Bool { style == .phone }

    var body: some View {
        let messages = engine.messages(for: record.id)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: phone ? 18 : 16) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        row(message).id(message.id)
                    }
                    if engine.thinking.contains(record.id) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(ai.active.isEmpty || ai.provider == .onDevice ? "Thinking…" : "Working…")
                                .font(.system(size: phone ? 15 : 13))
                                .foregroundStyle(AskStyle.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding(phone ? 20 : 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            composer
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ message: AskMessage) -> some View {
        switch message.role {
        case .user:
            Text(verbatim: message.text)
                .font(.system(size: phone ? 17 : 14))
                .lineSpacing(phone ? 17 * 0.4 - 4 : 14 * 0.45 - 3)
                .foregroundStyle(.white)
                .padding(.vertical, phone ? 10 : 9)
                .padding(.horizontal, phone ? 14 : 13)
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: phone ? 18 : 16, bottomLeadingRadius: phone ? 18 : 16,
                        bottomTrailingRadius: 4, topTrailingRadius: phone ? 18 : 16
                    )
                    .fill(Theme.accent)
                )
                .frame(maxWidth: phone ? 270 : 250, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(verbatim: message.text)
                        .font(.system(size: phone ? 17 : 14))
                        .lineSpacing(phone ? 17 * 0.45 - 4 : 14 * 0.55 - 4)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !message.citations.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.citations) { citation in citationChip(citation) }
                    }
                }
                ForEach(message.actions) { action in
                    if phone { phoneCard(action) } else { macCard(action) }
                }
            }
        case .failure:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: phone ? 15 : 13))
                .foregroundStyle(Color(hex: 0xB4232A))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func citationChip(_ citation: AskCitation) -> some View {
        Button { if !citation.turnID.isEmpty { showTurn(citation.turnID) } } label: {
            HStack(spacing: 5) {
                Image(systemName: "play.fill").font(.system(size: phone ? 8 : 7))
                Text(verbatim: phone || citation.speaker.isEmpty ? citation.clock : "\(citation.clock) · \(citation.speaker)")
                    .font(.system(size: phone ? 13 : 12).monospacedDigit())
            }
            .foregroundStyle(AskStyle.chipText)
            .padding(.horizontal, phone ? 10 : 8)
            .frame(height: phone ? 28 : 24)
            .background(phone ? AskStyle.fill : AskStyle.segment, in: RoundedRectangle(cornerRadius: phone ? 8 : 6))
        }
        .buttonStyle(.plain)
        .help("Show this turn")
    }

    /// Mac: app, result in green, the items, and where they went.
    private func macCard(_ action: AskAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(action.app, size: 24)
                Text(verbatim: action.app).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Label(action.result, systemImage: action.failed ? "xmark" : "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(action.failed ? Color(hex: 0xB4232A) : AskStyle.success)
                    .labelStyle(.titleAndIcon)
            }
            if !action.items.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(action.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•")
                            Text(verbatim: item)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: 0x3A3A40))
                    }
                }
                .padding(.leading, 4)
            }
            if let link = action.link {
                Link(destination: link) {
                    Text(action.location.isEmpty ? "Open in \(action.app)" : "Open \(action.location)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            } else if !action.location.isEmpty {
                Text(verbatim: action.location).font(.system(size: 12)).foregroundStyle(AskStyle.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AskStyle.border))
    }

    /// iPhone: one line ("Added 2 tasks to Notion"), where, and Open.
    private func phoneCard(_ action: AskAction) -> some View {
        HStack(spacing: 10) {
            appIcon(action.app, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: Self.phoneTitle(action))
                    .font(.system(size: 15, weight: .semibold))
                if !action.location.isEmpty {
                    Text(verbatim: action.location).font(.system(size: 13)).foregroundStyle(AskStyle.secondary)
                }
            }
            Spacer(minLength: 0)
            if let link = action.link {
                Link(destination: link) {
                    Text("Open")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(AskStyle.fill, in: Capsule())
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AskStyle.border))
    }

    /// "2 tasks added" in Notion reads "Added 2 tasks to Notion" on the phone card.
    static func phoneTitle(_ action: AskAction) -> String {
        if action.failed { return "\(action.app): \(action.result)" }
        let result = action.result.trimmingCharacters(in: .whitespaces)
        for verb in ["added", "created", "updated", "sent", "posted", "saved"] where result.lowercased().hasSuffix(" " + verb) {
            let what = result.dropLast(verb.count + 1)
            return "\(verb.prefix(1).uppercased() + verb.dropFirst()) \(what) to \(action.app)"
        }
        return "\(action.app): \(result)"
    }

    private func appIcon(_ app: String, size: CGFloat) -> some View {
        let symbol = ai.connections.first { $0.name == app }?.symbol ?? "app.connected.to.app.below.fill"
        return Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(AskStyle.fill, in: RoundedRectangle(cornerRadius: size / 4))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this meeting")
                .font(.system(size: phone ? 17 : 14, weight: .semibold))
            Text(ai.active.isEmpty || ai.provider == .onDevice
                 ? "What was decided, who owes what, or what someone said about a topic. Answers point to the turns they come from."
                 : "What was decided, who owes what — or have it add the action items to \(ai.active.map(\.name).joined(separator: ", ")).")
                .font(.system(size: phone ? 15 : 13))
                .foregroundStyle(AskStyle.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.self) { suggestion in
                Button { send(suggestion) } label: {
                    Text(suggestion)
                        .font(.system(size: phone ? 15 : 13))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestions: [String] {
        var list = ["What did we decide?", "Who owes what, and by when?"]
        if ai.provider != .onDevice, let first = ai.active.first { list.append("Add the action items to \(first.name)") }
        return list
    }

    // MARK: Composer

    @ViewBuilder
    private var composer: some View {
        if phone {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Ask about this meeting", text: $draft)
                        .font(.system(size: 17))
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit { send(draft) }
                    sendButton(size: 34)
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .frame(height: 46)
                .background(AskStyle.fill, in: Capsule())
                Menu {
                    providerItems
                } label: {
                    HStack(spacing: 4) {
                        Text(footer).font(.system(size: 13))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(AskStyle.secondary)
                    .frame(height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text("Ask about this meeting…")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(hex: 0xA1A1A8))
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .lineLimit(2...5)
                            .focused($focused)
                            .onSubmit { send(draft) }
                    }
                    .frame(minHeight: 40, alignment: .topLeading)
                    HStack(spacing: 6) {
                        Menu {
                            providerItems
                        } label: {
                            chip(text: ai.provider.title, symbol: nil)
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        Menu {
                            connectionItems
                        } label: {
                            chip(text: connectionsTitle, symbol: "link")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .disabled(ai.provider == .onDevice)
                        Spacer(minLength: 0)
                        sendButton(size: 28)
                    }
                }
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 10))
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent.opacity(0.5) : Color(hex: 0xDCDCE3)))
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(AskStyle.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func chip(text: String, symbol: String?) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 12, weight: .medium))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(AskStyle.secondary)
        }
        .foregroundStyle(Theme.text)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(AskStyle.fill, in: RoundedRectangle(cornerRadius: 7))
    }

    private func sendButton(size: CGFloat) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button { send(draft) } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .disabled(empty || engine.thinking.contains(record.id))
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send")
    }

    @ViewBuilder
    private var providerItems: some View {
        ForEach(AIProvider.allCases) { provider in
            if ai.hasKey(provider) {
                Button {
                    ai.provider = provider
                } label: {
                    if ai.provider == provider { Label(provider.title, systemImage: "checkmark") } else { Text(provider.title) }
                }
            } else {
                Button("Connect \(provider.title)…") { openSettings() }
            }
        }
        Divider()
        Button("Settings…") { openSettings() }
    }

    @ViewBuilder
    private var connectionItems: some View {
        let connected = ai.connections.filter(\.connected)
        if connected.isEmpty {
            Text("No apps connected")
        }
        ForEach(connected) { connection in
            Toggle(connection.name, isOn: Binding(
                get: { connection.enabled },
                set: { ai.setEnabled(connection.id, $0) }
            ))
        }
        Divider()
        Button("Manage connections…") { openSettings() }
    }

    private var connectionsTitle: String {
        let active = ai.active
        switch active.count {
        case 0: return "No apps"
        case 1: return active[0].name
        default: return "\(active.count) apps"
        }
    }

    private var footer: String {
        switch ai.provider {
        case .onDevice:
            return phone ? "Answered on this iPhone" : "Answered on this Mac. Nothing leaves it."
        case .chatGPT, .claude:
            return phone ? "Uses your \(ai.provider.title) API key" : "Questions and the transcript go to \(ai.provider.title) with your API key."
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        engine.ask(question, about: record)
        draft = ""
    }
}

enum AskStyle {
    static let secondary = Color(hex: 0x636366)
    static let fill = Color(hex: 0xF2F2F7)
    static let segment = Color(hex: 0xEEEEF2)
    static let segmentText = Color(hex: 0x4A4A52)
    static let chipText = Color(hex: 0x4A4A52)
    static let border = Color(hex: 0xE5E5EA)
    static let success = Color(hex: 0x1F7A4D)
}

/// The design's two-segment switch: 2 pt inset, white selected segment with a soft shadow.
struct DesignSegments<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var height: CGFloat = 26
    var fontSize: CGFloat = 13
    var radius: CGFloat = 8
    var fill = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { title, value in
                let on = selection == value
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: fontSize, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.text : AskStyle.segmentText)
                        .padding(.horizontal, fill ? 0 : 14)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: height)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: radius - 2).fill(.white)
                                    .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(AskStyle.segment, in: RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: Settings: AI and connections

/// "AI for summaries and Ask" and "Connections", laid out for the Mac settings window or the phone.
struct ConnectionsSettings: View {
    @ObservedObject var ai = AIConnections.shared
    var phone = false
    @State private var keyFor: AIProvider?
    @State private var adding: AddServerRequest?
    @State private var problem: String?

    struct AddServerRequest: Identifiable {
        var id = UUID()
        var name = ""
        var url = ""
        var needsClientID = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: phone ? 26 : 24) {
            providerSection
            connectionsSection
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: phone ? 13 : 12))
                    .foregroundStyle(Color(hex: 0xB4232A))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $keyFor) { provider in
            ProviderKeySheet(provider: provider)
        }
        .sheet(item: $adding) { request in
            AddMCPServerSheet(request: request)
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: phone ? 7 : 8) {
            heading("AI for summaries and Ask")
            VStack(spacing: 0) {
                ForEach(Array(AIProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { separator(inset: phone ? 16 : 42) }
                    providerRow(provider)
                }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: phone ? 12 : 10))
            .overlay { if !phone { RoundedRectangle(cornerRadius: 10).stroke(AskStyle.border) } }
            caption(phone
                    ? "ChatGPT and Claude get your question and the transcript. Translation always stays on your phone."
                    : "With ChatGPT or Claude, your question and the transcript are sent to that service with your API key. Translation always stays on this Mac.")
        }
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let selected = ai.provider == provider
        let usable = ai.hasKey(provider)
        return HStack(spacing: 12) {
            if !phone {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.accent : Color(hex: 0xC7C7CC))
            }
            VStack(alignment: .leading, spacing: phone ? 2 : 1) {
                Text(provider.title).font(.system(size: phone ? 17 : 13, weight: phone ? .regular : .medium))
                Text(subtitle(provider)).font(.system(size: phone ? 13 : 12)).foregroundStyle(AskStyle.secondary)
            }
            Spacer(minLength: 0)
            if provider != .onDevice {
                if usable {
                    if phone && selected {
                        Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    } else if !phone {
                        Button("Sign out") { ai.setKey(nil, for: provider) }
                            .buttonStyle(OutlineButton())
                    }
                } else {
                    Button(phone ? "Connect" : "Continue with \(provider.title)") { keyFor = provider }
                        .buttonStyle(FilledButton(phone: phone))
                }
            } else if phone && selected {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, phone ? 16 : 14)
        .padding(.vertical, 10)
        .frame(minHeight: phone ? 60 : 56)
        .contentShape(Rectangle())
        .onTapGesture {
            if usable { ai.provider = provider } else { keyFor = provider }
        }
        .contextMenu {
            if provider != .onDevice && usable {
                Button("Sign Out", role: .destructive) { ai.setKey(nil, for: provider) }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func subtitle(_ provider: AIProvider) -> String {
        switch provider {
        case .onDevice:
            return phone ? "Private, works offline" : "Private and works offline. Shorter answers, no connections."
        case .chatGPT, .claude:
            return ai.hasKey(provider) ? "Connected · your API key" : "Not connected"
        }
    }

    // MARK: Connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: phone ? 7 : 8) {
            if phone {
                heading("Connections")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    heading("Connections")
                    Text("Ask can read from and add to these apps.").font(.system(size: 12)).foregroundStyle(AskStyle.secondary)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(ai.connections.enumerated()), id: \.element.id) { index, connection in
                    if index > 0 { separator(inset: phone ? 58 : 52) }
                    connectionRow(connection)
                }
                separator(inset: phone ? 16 : 14)
                Button {
                    adding = AddServerRequest()
                } label: {
                    HStack(spacing: phone ? 10 : 8) {
                        Image(systemName: "plus").font(.system(size: phone ? 15 : 12, weight: .semibold))
                        Text(phone ? "Add MCP server" : "Add MCP server…").font(.system(size: phone ? 17 : 13, weight: phone ? .regular : .medium))
                        Spacer()
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, phone ? 16 : 14)
                    .frame(height: phone ? 50 : 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: phone ? 12 : 10))
            .overlay { if !phone { RoundedRectangle(cornerRadius: 10).stroke(AskStyle.border) } }
            if phone { caption("Ask can read from and add to these apps. They need ChatGPT or Claude.") }
        }
    }

    private func connectionRow(_ connection: MCPConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.symbol)
                .font(.system(size: phone ? 14 : 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: phone ? 30 : 26, height: phone ? 30 : 26)
                .background(AskStyle.fill, in: RoundedRectangle(cornerRadius: phone ? 7 : 6))
            Text(connection.name).font(.system(size: phone ? 17 : 13, weight: phone ? .regular : .medium))
            Spacer(minLength: 0)
            if ai.connecting == connection.id {
                ProgressView().controlSize(.small)
            } else if connection.connected {
                Text("Connected").font(.system(size: phone ? 15 : 12)).foregroundStyle(phone ? AskStyle.secondary : AskStyle.success)
                if phone {
                    Menu {
                        Toggle("Use in Ask", isOn: Binding(get: { connection.enabled }, set: { ai.setEnabled(connection.id, $0) }))
                        Button("Disconnect", role: .destructive) { ai.disconnect(connection.id) }
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(hex: 0xC7C7CC))
                    }
                } else {
                    Toggle("", isOn: Binding(get: { connection.enabled }, set: { ai.setEnabled(connection.id, $0) }))
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel(connection.name)
                }
            } else {
                Button("Connect") { connect(connection) }
                    .buttonStyle(phone ? AnyButtonStyle(PlainAccentButton()) : AnyButtonStyle(OutlineButton()))
            }
        }
        .padding(.horizontal, phone ? 16 : 14)
        .frame(height: phone ? 50 : 48)
        .contextMenu {
            if connection.connected {
                Button("Disconnect", role: .destructive) { ai.disconnect(connection.id) }
            }
        }
    }

    private func connect(_ connection: MCPConnection) {
        problem = nil
        if connection.url.isEmpty || connection.needsClientID {
            adding = AddServerRequest(name: connection.name, url: connection.url, needsClientID: connection.needsClientID)
            return
        }
        Task {
            do {
                try await ai.connect(connection.id)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Group {
            if phone {
                Text(text.uppercased()).font(.system(size: 13)).kerning(0.26).foregroundStyle(AskStyle.secondary).padding(.horizontal, 16)
            } else {
                Text(text).font(.system(size: 13, weight: .semibold))
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: phone ? 13 : 12))
            .lineSpacing(2)
            .foregroundStyle(AskStyle.secondary)
            .padding(.horizontal, phone ? 16 : 0)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func separator(inset: CGFloat) -> some View {
        Color(hex: phone ? 0xE5E5EA : 0xEFEFF2).frame(height: 1).padding(.leading, inset)
    }
}

/// "Continue with Claude" / "Connect ChatGPT". Neither service lets other apps sign in with a
/// ChatGPT or Claude.ai subscription, so this takes an API key and keeps it in the Keychain.
struct ProviderKeySheet: View {
    let provider: AIProvider
    @ObservedObject var ai = AIConnections.shared
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(provider.title)").font(.title2.weight(.semibold))
            Text("Paste an API key from your \(provider == .claude ? "Claude Console" : "OpenAI") account. \(provider.title) subscriptions (\(provider == .claude ? "Claude Pro, Max" : "ChatGPT Plus, Pro")) can't be used by other apps, so usage is billed to the API account. The key stays in this device's Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField(provider == .claude ? "sk-ant-…" : "sk-…", text: $key)
                .textFieldStyle(.roundedBorder)
            if let page = provider.keyPage {
                Link("Get an API key", destination: page).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    ai.setKey(key, for: provider)
                    ai.provider = provider
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).count < 12)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 460)
        #endif
    }
}

/// Any remote MCP server by URL: signs in with OAuth when the server supports it, or takes a token.
struct AddMCPServerSheet: View {
    let request: ConnectionsSettings.AddServerRequest
    @ObservedObject var ai = AIConnections.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.name.isEmpty ? "Add MCP server" : "Connect \(request.name)").font(.title2.weight(.semibold))
            Text("A remote MCP server (Streamable HTTP). Live Translate signs you in when the server supports it; otherwise paste an access token.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("https://example.com/mcp", text: $url)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            if request.needsClientID {
                TextField("OAuth client ID", text: $clientID).textFieldStyle(.roundedBorder)
                Text("\(request.name) only signs in apps registered with it. Create an app there with redirect URL \(MCPAuth.redirectURI) and paste its client ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecureField("Access token (optional)", text: $token).textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Connecting…" : (token.isEmpty ? "Sign In" : "Add")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || name.isEmpty || URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 480)
        #endif
        .onAppear {
            name = request.name
            url = request.url
        }
    }

    private func add() {
        working = true
        problem = nil
        Task {
            do {
                try await ai.add(name: name, url: url, token: token.isEmpty ? nil : token, clientID: clientID.isEmpty ? nil : clientID)
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: Button styles

private struct OutlineButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xD1D1D6)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct FilledButton: ButtonStyle {
    var phone: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: phone ? 15 : 12, weight: .semibold))
            .foregroundStyle(phone ? Theme.accent : .white)
            .padding(.horizontal, phone ? 14 : 10)
            .frame(height: phone ? 32 : 26)
            .background(phone ? Theme.accentSoft : Theme.accent, in: RoundedRectangle(cornerRadius: phone ? 16 : 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PlainAccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(height: 44)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
