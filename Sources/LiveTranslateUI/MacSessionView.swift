#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

private let sessionPalette: [Color] = [
    Color(red: 0.93, green: 0.39, blue: 0.20), Color(red: 0.13, green: 0.62, blue: 0.55),
    .blue, .purple, .pink, .indigo, .orange, .brown,
]

/// The Mac window: session history, the live transcript, and the summary inspector.
struct MacSessionView: View {
    @ObservedObject var controller: SessionController
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var exportFormat: SessionController.ExportFormat?
    @State private var focusedTurn: String?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SessionSidebar(controller: controller, columns: $columns)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                TranscriptPane(controller: controller, focusedTurn: $focusedTurn)
                Divider()
                BottomBar(controller: controller, levels: controller.levels)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .inspector(isPresented: $showInspector) {
                SummaryInspector(controller: controller)
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
            }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.2), value: controller.toast)
        .sheet(isPresented: $controller.showModels) {
            ModelScreen(controller: controller, library: controller.library)
        }
        .sheet(isPresented: $controller.notionSetupPresented) {
            NotionSetupSheet(controller: controller)
        }
        .alert("Rename speaker", isPresented: $controller.renaming) {
            TextField("Name", text: $controller.renameText)
            Button("Save") { controller.renameCurrent(to: controller.renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } }),
            document: ExportFile(data: exportFormat.map { controller.exportData($0) } ?? Data()),
            contentType: .plainText,
            defaultFilename: "\(controller.displayedRecord.displayTitle).\(exportFormat?.fileExtension ?? "txt")"
        ) { _ in exportFormat = nil }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = controller.toast {
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
                .padding(.bottom, 76)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Header

    private var header: some View {
        let record = controller.displayedRecord
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                EditableTitle(title: record.displayTitle) { controller.renameDisplayed($0) }
                Text(subtitle(record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 160, alignment: .leading)
            Spacer(minLength: 12)
            LanguagePair(controller: controller)
            Spacer(minLength: 12)
            Picker("Layout", selection: $controller.layout) {
                ForEach(TranscriptLayout.allCases) { layout in
                    Image(systemName: layout.systemImage)
                        .help(layout.title)
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            CopyMenu(controller: controller)
            Menu {
                ForEach(SessionController.ExportFormat.allCases) { format in
                    Button("\(format.title)…") { exportFormat = format }
                }
                Divider()
                Button("Export to Notion…") { controller.exportToNotion() }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
            Button {
                withAnimation { showInspector.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showInspector ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(showInspector ? "Hide summary" : "Show summary")
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
    }

    private func subtitle(_ record: SessionRecord) -> String {
        let day: String
        switch SessionGroup.of(record.started) {
        case .today: day = "Today"
        case .yesterday: day = "Yesterday"
        case .earlier: day = record.started.formatted(date: .abbreviated, time: .omitted)
        }
        let speakers = record.speakerCount
        let time = record.started.formatted(date: .omitted, time: .shortened)
        return speakers > 0 ? "\(day), \(time) · \(speakers) speaker\(speakers == 1 ? "" : "s")" : "\(day), \(time)"
    }
}

/// "Copy this session": one side, both sides line by line, or the summary,
/// with speaker names, timestamps, and Markdown as options.
struct CopyMenu: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let record = controller.displayedRecord
        let source = record.direction.source == .thai ? "Thai" : "English"
        let target = record.direction.target == .thai ? "Thai" : "English"
        Menu {
            Section("Copy this session") {
                Button { controller.copySession(.original) } label: {
                    Label("Original · \(source)", systemImage: "text.alignleft")
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                Button { controller.copySession(.translation) } label: {
                    Label("Translation · \(target)", systemImage: "text.alignleft")
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                Button { controller.copySession(.bilingual) } label: {
                    Label("Bilingual · line by line", systemImage: "rectangle.split.2x1")
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
                Button { controller.copySession(.summary) } label: {
                    Label("Summary", systemImage: "list.bullet")
                }
                .keyboardShortcut("4", modifiers: [.command, .option])
            }
            Section("Include") {
                Toggle("Speaker names", isOn: $controller.copyOptions.speakerNames)
                Toggle("Timestamps", isOn: $controller.copyOptions.timestamps)
                Toggle("Markdown formatting", isOn: $controller.copyOptions.markdown)
            }
            Section {
                Text("Hover any line in the transcript to copy just that line — original, translation or both.")
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        .fixedSize()
    }
}

/// Title that turns into a text field on double-click.
private struct EditableTitle: View {
    let title: String
    let commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .font(.headline)
                .onSubmit {
                    commit(draft)
                    editing = false
                }
                .onExitCommand { editing = false }
        } else {
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    draft = title
                    editing = true
                }
                .help("Double-click to rename")
        }
    }
}

/// English ⇄ Thai: the spoken language, a swap button, and the translation language.
private struct LanguagePair: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let direction = controller.engine.direction
        HStack(spacing: 6) {
            languageMenu(direction.source) { picked in
                controller.setDirection(picked == .thai ? .thaiToEnglish : .englishToThai)
            }
            Button(action: controller.swapDirection) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Swap languages")
            languageMenu(direction.target) { picked in
                controller.setDirection(picked == .thai ? .englishToThai : .thaiToEnglish)
            }
        }
        .disabled(controller.engine.listening || controller.isViewingPast)
        .help(controller.engine.listening ? "Languages stay fixed until Stop." : "Spoken language ⇄ translation")
    }

    private func languageMenu(_ language: SpeechLanguage, pick: @escaping (SpeechLanguage) -> Void) -> some View {
        Menu {
            Button("English") { pick(.english) }
            Button("Thai") { pick(.thai) }
        } label: {
            Text(language == .thai ? "Thai" : "English")
                .frame(minWidth: 64)
        }
        .fixedSize()
    }
}

// MARK: Sidebar

struct SessionSidebar: View {
    @ObservedObject var controller: SessionController
    @Binding var columns: NavigationSplitViewVisibility
    @State private var query = ""

    private var rows: [SessionRecord] {
        var all = controller.sessions
        let live = controller.engine.record(updating: controller.current)
        if !all.contains(where: { $0.id == live.id }) && (controller.engine.listening || !live.turns.isEmpty) {
            all.insert(live, at: 0)
        }
        return all.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search sessions", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                Button(action: controller.newSession) {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .help("New session (⌘N)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            List(selection: selection) {
                ForEach(SessionGroup.allCases, id: \.self) { group in
                    let members = rows.filter { SessionGroup.of($0.started) == group }
                    if !members.isEmpty {
                        Section(group.rawValue.uppercased()) {
                            ForEach(members) { record in
                                row(record)
                                    .tag(record.id)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) { controller.deleteSession(record.id) }
                                    }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if rows.isEmpty {
                    Text(query.isEmpty ? "Sessions you record appear here." : "No matching sessions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }

            OfflineCard(controller: controller)
                .padding(10)
        }
    }

    private var selection: Binding<UUID?> {
        Binding(
            get: { controller.viewingID ?? controller.current.id },
            set: { if let id = $0 { controller.open(id) } }
        )
    }

    private func row(_ record: SessionRecord) -> some View {
        let live = record.id == controller.current.id && controller.engine.listening
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if live {
                    Circle().fill(.red).frame(width: 7, height: 7)
                }
                Text(verbatim: record.displayTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Text(live ? "\(record.directionShort) · Live" : "\(record.directionShort) · \(SessionRecord.durationText(record.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct OfflineCard: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("On-device · works offline", systemImage: "cpu")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(modelLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Manage languages") { controller.showModels = true }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08)))
    }

    private var modelLine: String {
        let source = controller.engine.direction.source == .thai ? "Thai" : "English"
        let target = controller.engine.direction.target == .thai ? "Thai" : "English"
        switch controller.speechStatus {
        case .ready(let name): return "\(source) ⇄ \(target) · \(name)"
        case .loading(let name): return "Loading \(name)…"
        case .failed(let message): return message
        case .idle: return "\(source) ⇄ \(target) · no speech model yet"
        }
    }
}

// MARK: Transcript

struct TranscriptPane: View {
    @ObservedObject var controller: SessionController
    @Binding var focusedTurn: String?

    private var record: SessionRecord { controller.displayedRecord }

    private var turns: [DisplayTurn] {
        if controller.isViewingPast {
            var order: [String: Int] = [:]
            return record.turns.map { turn in
                if !turn.speaker.isEmpty, order[turn.speaker] == nil { order[turn.speaker] = order.count }
                return DisplayTurn(
                    id: turn.id, speaker: turn.speaker, colorIndex: order[turn.speaker],
                    clock: record.started.addingTimeInterval(turn.start),
                    source: turn.source, sourceTail: "", translation: turn.translation,
                    translationProvisional: "", live: false, renamable: false
                )
            }
        }
        let origin = controller.engine.startedAt ?? Date()
        let chips = controller.engine.speakers.chipsVisible
        return controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }.map { turn in
            DisplayTurn(
                id: turn.id,
                speaker: chips ? turn.speakerLabel : "",
                colorIndex: chips ? controller.engine.speakers.colorIndex(ordinal: turn.speakerOrdinal, paletteCount: sessionPalette.count) : nil,
                clock: origin.addingTimeInterval(turn.start),
                source: turn.sourcePrefix,
                sourceTail: turn.committed ? "" : turn.sourceTail,
                translation: turn.translationCommitted,
                translationProvisional: turn.translationProvisional,
                live: !turn.committed,
                renamable: turn.speakerOrdinal != nil
            )
        }
    }

    private var sourceName: String { record.direction.source == .thai ? "Thai" : "English" }
    private var targetName: String { record.direction.target == .thai ? "Thai" : "English" }

    var body: some View {
        let layout = controller.layout
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if layout != .translationOnly {
                    columnHeader(sourceName, "Original", part: .source)
                }
                if layout == .sideBySide {
                    Divider()
                }
                if layout != .stacked {
                    columnHeader(targetName, "Translation", part: .translation)
                }
            }
            .frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        let rows = turns
                        if rows.isEmpty {
                            EmptyTranscript(controller: controller, sourceName: sourceName)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 80)
                        }
                        ForEach(rows) { turn in
                            TurnRow(
                                turn: turn,
                                layout: layout,
                                selected: focusedTurn == turn.id || controller.engine.focusedTurnID == turn.id,
                                controller: controller
                            )
                            .id(turn.id)
                            .onTapGesture { focusedTurn = turn.id }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: controller.engine.focusedTurnID) { _, id in
                    guard let id else { return }
                    focusedTurn = id
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: controller.engine.turns.count) { _, _ in
                    guard controller.engine.listening, let last = controller.engine.turns.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .font(.system(size: 15 * controller.typeScale))
    }

    private func columnHeader(_ language: String, _ role: String, part: SessionController.CopyPart) -> some View {
        HStack(spacing: 8) {
            Text(language).font(.subheadline.weight(.semibold))
            Text(role).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                controller.copyAll(part)
            } label: {
                Label("Copy all", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .disabled(turns.isEmpty)
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}

private struct EmptyTranscript: View {
    @ObservedObject var controller: SessionController
    let sourceName: String

    var body: some View {
        if controller.isViewingPast {
            ContentUnavailableView("No words in this session", systemImage: "text.bubble")
        } else {
            switch controller.engine.listenState {
            case .packMissing:
                ContentUnavailableView {
                    Label("No speech model yet", systemImage: "shippingbox")
                } description: {
                    Text(controller.statusLine.isEmpty ? "Download a pack, or pick a streaming model from Hugging Face." : controller.statusLine)
                } actions: {
                    Button("Manage languages") { controller.showModels = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("missingPackModels")
                }
            case .microphoneDenied:
                ContentUnavailableView {
                    Label("Microphone is off", systemImage: "mic.slash")
                } description: {
                    Text("Live Translate needs the microphone to hear the room. Audio never leaves this Mac.")
                } actions: {
                    Button("Open System Settings", action: controller.openSettings)
                        .buttonStyle(.borderedProminent)
                }
            case .idle:
                ContentUnavailableView {
                    Label(ListenPolicy.idleLine, systemImage: "waveform")
                } description: {
                    Text("Press Listen or ⌘↩. Pick Microphone for the room or System audio for a call on this Mac.")
                }
                .accessibilityIdentifier("idleLine")
            case .listening, .listeningSilence:
                ContentUnavailableView {
                    Label(controller.paused ? "Paused" : "Listening…", systemImage: controller.paused ? "pause.circle" : "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: !controller.paused)
                } description: {
                    Text("Start speaking \(sourceName). Words appear as they are recognized.")
                }
            }
        }
    }
}

struct TurnRow: View {
    let turn: DisplayTurn
    let layout: TranscriptLayout
    let selected: Bool
    @ObservedObject var controller: SessionController
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !turn.speaker.isEmpty {
                    Circle()
                        .fill(turn.colorIndex.map { sessionPalette[$0 % sessionPalette.count] } ?? .gray)
                        .frame(width: 7, height: 7)
                    Text(verbatim: turn.speaker)
                        .font(.subheadline.weight(.semibold))
                        .onTapGesture(count: 2) { if turn.renamable { controller.beginRename(turn.id) } }
                        .help(turn.renamable ? "Double-click to rename" : "")
                }
                Text(turn.clock.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if turn.live {
                    Label("Live", systemImage: "circle.fill")
                        .labelStyle(LiveBadgeStyle())
                }
                Spacer()
                if hovering || selected {
                    copyChip("Original", .source)
                    copyChip("Translation", .translation)
                    copyChip("Both", .both)
                }
            }
            .frame(height: 22)
            switch layout {
            case .sideBySide:
                HStack(alignment: .top, spacing: 0) {
                    sourceText.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).padding(.horizontal, 16)
                    translationText.frame(maxWidth: .infinity, alignment: .leading)
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 6) {
                    sourceText
                    translationText.foregroundStyle(.secondary)
                }
            case .translationOnly:
                translationText
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.08) : (hovering ? Color.primary.opacity(0.035) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy original") { controller.copy(text: turn.sourceText, label: "Original copied") }
            Button("Copy translation") { controller.copy(text: turn.translationText, label: "Translation copied") }
            Button("Copy both") { controller.copy(text: turn.sourceText + "\n" + turn.translationText, label: "Turn copied") }
            if !controller.isViewingPast {
                Divider()
                Button("Highlight") {
                    controller.focus(turn.id)
                    controller.highlight()
                }
                if turn.renamable {
                    Button("Rename speaker…") { controller.beginRename(turn.id) }
                }
            }
        }
    }

    private var sourceText: some View {
        (Text(verbatim: turn.source)
            + Text(verbatim: turn.sourceTail).foregroundStyle(.secondary)
            + Text(verbatim: turn.live ? "▏" : "").foregroundStyle(Color.accentColor))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var translationText: some View {
        if turn.translationText.isEmpty {
            Text(turn.live ? "Translating…" : "")
                .foregroundStyle(.tertiary)
        } else {
            (Text(verbatim: turn.translation) + Text(verbatim: turn.translationProvisional).foregroundStyle(.secondary))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyChip(_ title: String, _ part: SessionController.CopyPart) -> some View {
        Button {
            switch part {
            case .source: controller.copy(text: turn.sourceText, label: "Original copied")
            case .translation: controller.copy(text: turn.translationText, label: "Translation copied")
            case .both: controller.copy(text: turn.sourceText + "\n" + turn.translationText, label: "Turn copied")
            }
        } label: {
            Label(title, systemImage: "doc.on.doc")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

private struct LiveBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.red)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.red.opacity(0.1), in: Capsule())
    }
}

// MARK: Bottom bar

struct BottomBar: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var levels: LevelMeter

    var body: some View {
        HStack(spacing: 14) {
            if controller.isViewingPast {
                Label("Saved session · text only", systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Back to live") { controller.viewingID = nil }
                Button("New session", action: controller.newSession)
                    .buttonStyle(.borderedProminent)
            } else {
                sourceMenu
                CaptionsButton()
                status
                Spacer()
                if controller.engine.listening {
                    Button(action: controller.pauseOrResume) {
                        Label(controller.paused ? "Resume" : "Pause", systemImage: controller.paused ? "play.fill" : "pause.fill")
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .controlSize(.large)
                }
                listenButton
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 60)
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(AudioSourceKind.allCases) { source in
                Button {
                    controller.setAudioSource(source)
                } label: {
                    Label(source.title, systemImage: source.systemImage)
                }
            }
        } label: {
            Label(controller.audioSource.title, systemImage: controller.audioSource.systemImage)
        }
        .fixedSize()
        .help("Microphone hears the room. System audio hears what this Mac plays, such as a call.")
    }

    @ViewBuilder
    private var status: some View {
        if controller.engine.listening {
            HStack(spacing: 8) {
                Circle().fill(controller.paused ? Color.orange : .red).frame(width: 8, height: 8)
                Text(controller.paused ? "Paused" : "Listening").fontWeight(.semibold)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(StatusStrip.elapsed(controller.elapsed(at: context.date)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Waveform(levels: levels.levels)
                    .frame(width: 150, height: 26)
            }
        } else if controller.isPreparing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading the speech model…").foregroundStyle(.secondary)
            }
        } else {
            Text(readyLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var readyLine: String {
        switch controller.speechStatus {
        case .ready(let name): return "Ready · \(name)"
        case .loading(let name): return "Loading \(name)…"
        case .failed(let message): return message
        case .idle: return "No speech model for this language yet"
        }
    }

    private var listenButton: some View {
        Button(action: controller.listenOrStop) {
            Label(controller.engine.listening ? "Stop" : "Listen", systemImage: controller.engine.listening ? "stop.fill" : "mic.fill")
                .fontWeight(.semibold)
                .frame(minWidth: 70)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.engine.listening ? .red : .accentColor)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!controller.engine.listening && !controller.isPreparing && !(controller.engine.listenEnabled && controller.engine.packInstalled))
        .accessibilityIdentifier("listenButton")
    }
}

private struct CaptionsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: CaptionsWindow.id)
        } label: {
            Image(systemName: "captions.bubble")
        }
        .help("Floating captions, always on top (⇧⌘K)")
        .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}

private struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor.opacity(0.35 + Double(level) * 0.65))
                    .frame(width: 3, height: max(3, CGFloat(level) * 26))
            }
        }
        .animation(.linear(duration: 0.06), value: levels)
    }
}

// MARK: Summary inspector

struct SummaryInspector: View {
    @ObservedObject var controller: SessionController
    @State private var notesDraft = ""
    @State private var editingID: UUID?

    private var record: SessionRecord { controller.displayedRecord }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    summary
                    keyPoints
                    actions
                    yourNotes
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(action: controller.copySummary) {
                    Label("Copy summary", systemImage: "doc.on.doc")
                }
                Spacer()
                Button(action: controller.exportToNotion) {
                    if controller.exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Export to Notion", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.exporting)
            }
            .controlSize(.large)
            .padding(14)
        }
        .onAppear { syncDraft() }
        .onChange(of: record.id) { _, _ in syncDraft() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Summary").font(.title3.weight(.semibold))
                Spacer()
                Picker("Language", selection: languageBinding) {
                    Text("EN").tag(SpeechLanguage.english)
                    Text("TH").tag(SpeechLanguage.thai)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(action: controller.copySummary) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help("Copy summary")
            }
            HStack(spacing: 5) {
                if controller.notesRunning {
                    ProgressView().controlSize(.mini)
                    Text("Updating live, on-device")
                } else if controller.engine.listening && !controller.isViewingPast {
                    Image(systemName: "sparkles")
                    Text("Updates live, on-device")
                } else {
                    Image(systemName: "lock")
                    Text("Written on this Mac")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summary: some View {
        let text = record.note.summary.map { controller.noteText($0.text) }.joined(separator: " ")
        if text.isEmpty {
            Text(NotesReducer.emptyLine)
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var keyPoints: some View {
        let points = record.note.decisions + record.note.openQuestions + record.note.highlights
        if !points.isEmpty {
            section("Key points") {
                ForEach(points) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        (Text(verbatim: controller.noteText(item.text))
                            + (item.tentative ? Text("  New").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor) : Text("")))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contextMenu {
                        if !controller.isViewingPast {
                            Button("Jump to turn") { controller.focus(item.turnID) }
                            Button("Delete", role: .destructive) { controller.deleteNote(id: item.id) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !record.note.actions.isEmpty {
            section("Action items") {
                ForEach(record.note.actions) { item in
                    let done = record.checkedActions.contains(item.id)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button {
                            controller.toggleAction(item.id)
                        } label: {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .foregroundStyle(done ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: controller.noteText(item.text))
                                .strikethrough(done)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.speaker.isEmpty {
                                Text(verbatim: item.speaker).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var yourNotes: some View {
        section("Your notes") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notesDraft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .onChange(of: notesDraft) { _, text in
                        if text != record.userNotes { controller.setUserNotes(text) }
                    }
                if notesDraft.isEmpty {
                    Text("Add a note to this session…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var languageBinding: Binding<SpeechLanguage> {
        Binding(
            get: { controller.summaryLanguage ?? controller.noteLanguage },
            set: { controller.setSummaryLanguage($0) }
        )
    }

    private func syncDraft() {
        notesDraft = record.userNotes
    }
}

// MARK: Notion

struct NotionSetupSheet: View {
    @ObservedObject var controller: SessionController
    @Environment(\.dismiss) private var dismiss
    @State private var settings = NotionExport.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export to Notion").font(.title2.weight(.semibold))
            Text("Create an internal integration at notion.so/my-integrations, share a page with it, then paste its token and the page link here. Export sends this session's text — the note, your notes, and the transcript — to that page. Audio never leaves this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Integration token (secret_… or ntn_…)", text: $settings.token)
            TextField("Parent page link or id", text: $settings.parentPageID)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save and export") {
                    NotionExport.save(settings)
                    dismiss()
                    controller.exportToNotion()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!settings.isComplete)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 460)
    }
}
#endif
