import SwiftUI
import UniformTypeIdentifiers

struct TranscriptFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum AppStorageRoot {
    static func url() -> URL {
        // A separate root for automated checks, so they never touch the user's packs or sessions.
        if let override = ProcessInfo.processInfo.environment["LT_STORAGE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = base.appendingPathComponent("LiveTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct AdaptiveSession: View {
    @ObservedObject var controller: SessionController
    var shell: AppShell
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical

    var body: some View {
        SessionScreen(
            controller: controller,
            shell: shell,
            landscape: vertical == .compact,
            regularWidth: horizontal == .regular
        )
        .onChange(of: vertical) { _, _ in controller.noteRotation() }
        .onChange(of: horizontal) { _, _ in controller.noteRotation() }
    }
}

/// Eight stable speaker colors, in order of first appearance.
private let speakerPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]

struct SessionScreen: View {
    @ObservedObject var controller: SessionController
    var shell: AppShell
    var landscape: Bool
    var regularWidth: Bool

    private var arrangement: PanelArrangement {
        SessionLayout.arrangement(shell: shell, landscape: landscape, regularWidth: regularWidth)
    }

    private var chrome: SessionChrome {
        SessionChrome.describe(shell: shell)
    }

    var body: some View {
        GeometryReader { geo in
            let notesOn = SessionLayout.notesVisible(
                width: geo.size.width,
                userHidden: controller.engine.notesHidden,
                shell: shell,
                regularWidth: regularWidth
            )
            VStack(spacing: 0) {
                if shell == .phone {
                    phoneBody
                } else {
                    macBar
                    StatusStrip(controller: controller)
                    Divider()
                    HStack(spacing: 0) {
                        panels
                        if notesOn {
                            Divider()
                            NotesColumn(controller: controller)
                                .frame(width: SessionLayout.notesColumnWidth)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.2), value: controller.toast)
        .sheet(isPresented: $controller.showModels) {
            ModelScreen(controller: controller, library: controller.library)
        }
        .alert("Rename speaker", isPresented: $controller.renaming) {
            TextField("Name", text: $controller.renameText)
            Button("Save") { controller.renameCurrent(to: controller.renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $controller.exportPresented,
            document: TranscriptFile(data: controller.saveData() ?? Data()),
            contentType: .json,
            defaultFilename: "transcript.json"
        ) { _ in }
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
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Phone

    private var phoneBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !chrome.pageSwitch.isEmpty {
                    Picker("Page", selection: $controller.phoneShowsNotes) {
                        if chrome.pageSwitch.contains(.conversation) {
                            Text("Conversation").tag(false)
                        }
                        if chrome.pageSwitch.contains(.notesPage) {
                            Text("Notes").tag(true)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                StatusStrip(controller: controller)
                if controller.phoneShowsNotes {
                    NotesColumn(controller: controller)
                } else {
                    panels
                }
                HStack(spacing: 12) {
                    ForEach(chrome.bottomBeside, id: \.self) { control in
                        if control == .highlight {
                            Button(action: controller.highlight) {
                                Label("Highlight", systemImage: "pin")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                    if chrome.bottomProminent == chrome.prominent {
                        listenButton
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding()
            }
            .navigationTitle("Live Translate")
            .toolbar {
                if chrome.navigationBar.contains(.direction) {
                    ToolbarItem { directionPicker }
                }
                ToolbarItem { copyMenu }
                if chrome.navigationBar.contains(.models) {
                    ToolbarItem {
                        Button { controller.showModels = true } label: { Image(systemName: "shippingbox") }
                            .accessibilityLabel("Models")
                    }
                }
            }
        }
    }

    // MARK: Mac bar

    private var macBar: some View {
        HStack(spacing: 12) {
            directionPicker
                .frame(maxWidth: 300)
                .accessibilityIdentifier("directionControl")
            listenButton
                .keyboardShortcut(.return, modifiers: .command)
                .controlSize(.large)
            if chrome.secondary.contains(.accurate) {
                latencyPicker
                    .frame(maxWidth: 240)
                    .help("Fast, Balanced and Accurate pick the streaming chunk the speech model was trained with.")
            }
            Spacer(minLength: 8)
            ForEach(chrome.secondary, id: \.self) { control in
                barButton(control)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func barButton(_ control: SessionControl) -> some View {
        switch control {
        case .highlight:
            iconButton("pin", "Highlight the current turn (⇧⌘H)", action: controller.highlight)
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(controller.engine.turns.isEmpty)
        case .speakers:
            iconButton(
                controller.engine.speakers.chipsVisible ? "person.2.fill" : "person.2",
                controller.engine.speakers.chipsVisible ? "Hide speakers" : "Show speakers",
                action: controller.toggleSpeakers
            )
        case .copy:
            copyMenu
        case .save:
            iconButton("square.and.arrow.down", "Save transcript and note") { controller.exportPresented = true }
                .disabled(controller.engine.turns.isEmpty)
        case .type:
            Menu {
                Button("Larger") { controller.typeScale = min(2.0, controller.typeScale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller") { controller.typeScale = max(0.8, controller.typeScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Default") { controller.typeScale = 1.15 }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text size")
            .accessibilityIdentifier("typeControl")
        case .models:
            iconButton("shippingbox", "Models", action: { controller.showModels = true })
                .keyboardShortcut("m", modifiers: [.command, .shift])
        case .notes:
            iconButton("sidebar.right", controller.engine.notesHidden ? "Show notes" : "Hide notes", action: controller.toggleNotes)
        case .direction, .listenStop, .fast, .balanced, .accurate, .conversation, .notesPage:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    private var copyMenu: some View {
        Menu {
            Button("Copy detected text") { controller.copyAll(.source) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy translation") { controller.copyAll(.translation) }
            Button("Copy both") { controller.copyAll(.both) }
            Divider()
            Button("Copy transcript with times") { controller.copyTranscript() }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy")
        .disabled(controller.engine.turns.isEmpty)
    }

    private var listenButton: some View {
        Button(action: controller.listenOrStop) {
            HStack(spacing: 6) {
                if controller.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                } else if controller.engine.listening {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                } else {
                    Image(systemName: "mic.fill")
                    Text("Listen")
                }
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 96)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.engine.listening ? .red : .accentColor)
        .disabled(!controller.engine.listening && !controller.isPreparing && !(controller.engine.listenEnabled && controller.engine.packInstalled))
        .help(controller.engine.listening ? "Stop (⌘↩)" : "Listen (⌘↩)")
        .accessibilityIdentifier("listenButton")
    }

    private var latencyPicker: some View {
        Picker("Latency", selection: presetBinding) {
            ForEach(LatencyPreset.allCases, id: \.self) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var directionPicker: some View {
        Picker("Direction", selection: directionBinding) {
            Text(TranslationDirection.thaiToEnglish.title).tag(TranslationDirection.thaiToEnglish)
            Text(TranslationDirection.englishToThai.title).tag(TranslationDirection.englishToThai)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(controller.engine.listening)
        .help(controller.engine.listening ? "Direction stays fixed until Stop." : "Which language is spoken")
    }

    // MARK: Panels

    private var panels: some View {
        VStack(spacing: 0) {
            panelHeaders
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let visible = controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }
                        if visible.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                                .padding(.top, 60)
                        }
                        ForEach(visible) { turn in
                            TurnCard(
                                turn: turn,
                                arrangement: arrangement,
                                showSpeaker: controller.engine.speakers.chipsVisible,
                                colorIndex: controller.engine.speakers.colorIndex(
                                    ordinal: turn.speakerOrdinal,
                                    paletteCount: speakerPalette.count
                                ),
                                focused: controller.engine.focusedTurnID == turn.id,
                                controller: controller
                            )
                            .id(turn.id)
                        }
                    }
                    .padding(12)
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .onChange(of: controller.engine.focusedTurnID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: controller.engine.turns.count) { _, _ in
                    guard controller.engine.listening, let last = controller.engine.turns.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .font(.system(size: 16 * controller.typeScale))
    }

    private var panelHeaders: some View {
        HStack(spacing: 0) {
            panelHeader(sourceTitle, systemImage: "waveform", part: .source)
            if arrangement == .sideBySide {
                Divider()
                panelHeader(targetTitle, systemImage: "character.bubble", part: .translation)
            }
        }
        .frame(height: 36)
        .background(.quaternary.opacity(0.35))
    }

    private func panelHeader(_ title: String, systemImage: String, part: SessionController.CopyPart) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            Button {
                controller.copyAll(part)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(part == .source ? "Copy all detected text" : "Copy all translations")
            .disabled(controller.engine.turns.isEmpty)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch controller.engine.listenState {
        case .packMissing(let packName):
            ContentUnavailableView {
                Label("No speech model yet", systemImage: "shippingbox")
            } description: {
                VStack(spacing: 6) {
                    Text(verbatim: packName)
                        .font(.headline)
                        .accessibilityIdentifier("packName")
                    Text(controller.statusLine.isEmpty ? "Download a pack, or pick a streaming model from Hugging Face." : controller.statusLine)
                }
            } actions: {
                Button("Open Models") { controller.showModels = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("missingPackModels")
            }
        case .microphoneDenied:
            ContentUnavailableView {
                Label("Microphone is off", systemImage: "mic.slash")
            } description: {
                Text("Live Translate needs the microphone to hear the room. Audio never leaves this device.")
            } actions: {
                Button("Open System Settings", action: controller.openSettings)
                    .buttonStyle(.borderedProminent)
            }
        case .idle:
            ContentUnavailableView {
                Label(ListenPolicy.idleLine, systemImage: "mic")
            } description: {
                Text("Press Listen or ⌘↩. Speech appears on the left; the translation follows on the right. Select any text to copy it.")
            }
            .accessibilityIdentifier("idleLine")
        case .listening, .listeningSilence:
            ContentUnavailableView {
                Label("Listening…", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
            } description: {
                Text("Start speaking \(sourceTitle). Words appear as they are recognized.")
            }
        }
    }

    private var sourceTitle: String {
        controller.engine.direction.source.title
    }

    private var targetTitle: String {
        controller.engine.direction.target.title
    }

    private var directionBinding: Binding<TranslationDirection> {
        Binding(
            get: { controller.engine.direction },
            set: { controller.setDirection($0) }
        )
    }

    private var presetBinding: Binding<LatencyPreset> {
        Binding(
            get: { controller.engine.preset },
            set: { controller.setPreset($0) }
        )
    }
}

// MARK: Status

/// One line under the bar: what is listening, and which model runs where.
struct StatusStrip: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        HStack(spacing: 14) {
            if let started = controller.listenStarted, controller.engine.listening {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(context.date.timeIntervalSince(started)))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.red)
            }
            status("waveform", "Speech", controller.speechStatus)
            #if os(macOS)
            status("character.bubble", "Translation", controller.translatorStatus)
            #endif
            if controller.notesRunning {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Updating notes")
                }
            }
            Spacer(minLength: 0)
            Text("On-device · audio stays on this Mac")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func status(_ symbol: String, _ title: String, _ status: EngineStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .loading(let name):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("\(title): loading \(name)…")
            }
        case .ready(let name):
            Label("\(title): \(name)", systemImage: symbol)
        case .failed(let message):
            Label("\(title): \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: Turn

struct TurnCard: View {
    let turn: SessionTurn
    let arrangement: PanelArrangement
    let showSpeaker: Bool
    let colorIndex: Int?
    let focused: Bool
    @ObservedObject var controller: SessionController
    @State private var hovering = false

    var body: some View {
        Group {
            if arrangement == .stacked {
                VStack(alignment: .leading, spacing: 10) {
                    sourceSide
                    Divider()
                    translationSide
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    sourceSide
                    Divider()
                    translationSide
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(focused ? Color.accentColor.opacity(0.10) : Color.primary.opacity(hovering ? 0.05 : 0.03))
        )
        .overlay(alignment: .leading) {
            if showSpeaker, let colorIndex {
                RoundedRectangle(cornerRadius: 2)
                    .fill(speakerPalette[colorIndex])
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy detected text") { controller.copy(turn: turn, part: .source) }
            Button("Copy translation") { controller.copy(turn: turn, part: .translation) }
            Button("Copy both") { controller.copy(turn: turn, part: .both) }
            Divider()
            Button("Highlight") {
                controller.focus(turn.id)
                controller.highlight()
            }
            if turn.speakerOrdinal != nil {
                Button("Rename speaker…") { controller.beginRename(turn.id) }
            }
        }
    }

    private var sourceSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if showSpeaker, let colorIndex, !turn.speakerLabel.isEmpty {
                    Button {
                        controller.beginRename(turn.id)
                    } label: {
                        Text(verbatim: turn.speakerLabel)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(speakerPalette[colorIndex].opacity(0.18), in: Capsule())
                            .foregroundStyle(speakerPalette[colorIndex])
                    }
                    .buttonStyle(.plain)
                    .help("Rename this speaker")
                }
                Text(StatusStrip.elapsed(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if !turn.committed {
                    Text("live")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                copyButton(.source, help: "Copy detected text")
            }
            // One Text so a selection can run across the committed words and the live tail.
            (Text(verbatim: turn.sourcePrefix)
                + Text(verbatim: turn.committed ? "" : turn.sourceTail).foregroundStyle(.secondary)
                + Text(verbatim: turn.committed ? "" : " ▍").foregroundStyle(.tertiary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var translationSide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                copyButton(.translation, help: "Copy translation")
            }
            .frame(height: 18)
            let committed = turn.translationCommitted
            let provisional = turn.translationProvisional
            if committed.isEmpty && provisional.isEmpty {
                Text(turn.committed ? "…" : "Translating…")
                    .foregroundStyle(.tertiary)
            } else {
                (Text(verbatim: committed) + Text(verbatim: provisional).foregroundStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyButton(_ part: SessionController.CopyPart, help: String) -> some View {
        Button {
            controller.copy(turn: turn, part: part)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        #if os(macOS)
        .opacity(hovering ? 1 : 0)
        #endif
    }
}

// MARK: Notes

struct NotesColumn: View {
    @ObservedObject var controller: SessionController

    private var note: MeetingNote { controller.engine.notes.note }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("Notes", systemImage: "list.bullet.rectangle")
                        .font(.headline)
                    if controller.notesRunning {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if note.title.text.isEmpty && note.summary.isEmpty && note.highlights.isEmpty
                    && note.decisions.isEmpty && note.actions.isEmpty && note.openQuestions.isEmpty {
                    Text(NotesReducer.emptyLine)
                        .foregroundStyle(.secondary)
                }
                if !note.title.text.isEmpty {
                    Text(verbatim: note.title.text)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                }
                block("Summary", "text.alignleft", note.summary)
                block("Decisions", "checkmark.seal", note.decisions)
                block("Actions", "checklist", note.actions)
                block("Open questions", "questionmark.circle", note.openQuestions)
                block("Highlights", "pin", note.highlights)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func block(_ title: String, _ symbol: String, _ items: [NoteItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: item.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if !item.speaker.isEmpty {
                                Text(verbatim: item.speaker).font(.caption).foregroundStyle(.secondary)
                            }
                            if item.tentative {
                                Text("Tentative")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            Spacer()
                            Button { controller.focus(item.turnID) } label: { Image(systemName: "arrow.turn.down.left") }
                                .buttonStyle(.borderless)
                                .help("Jump to the turn")
                            Button { controller.deleteNote(id: item.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete this card")
                        }
                        .font(.caption)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .opacity(item.tentative ? 0.85 : 1)
                }
            }
        }
    }
}

// MARK: Models

struct ModelScreen: View {
    @ObservedObject var controller: SessionController
    @ObservedObject var library: ModelLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .speech
    @State private var speechLanguage: SpeechLanguage = .thai

    enum Page: Hashable {
        case speech
        case translation
        case notes
        case packs
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $page) {
                    Label("Speech", systemImage: "waveform").tag(Page.speech)
                    Label("Translation", systemImage: "character.bubble").tag(Page.translation)
                    Label("Notes", systemImage: "list.bullet.rectangle").tag(Page.notes)
                    Label("Packs", systemImage: "shippingbox").tag(Page.packs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                if page == .speech {
                    // Only streaming models for the chosen language are listed.
                    Picker("Language", selection: $speechLanguage) {
                        ForEach(SpeechLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .frame(maxWidth: 260)
                    .padding(.bottom, 8)
                }
                if controller.engine.listening {
                    Label("Downloads wait until Listen stops.", systemImage: "mic.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 6)
                }
                Divider()
                switch page {
                case .packs:
                    packList
                case .speech:
                    TaskModelList(task: .speech(speechLanguage), controller: controller, library: library)
                        .id(speechLanguage)
                case .translation:
                    TaskModelList(task: .translation, controller: controller, library: library)
                case .notes:
                    TaskModelList(task: .notes, controller: controller, library: library)
                }
            }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            speechLanguage = controller.engine.direction.source
        }
    }

    private var packList: some View {
        List(controller.platformPacks) { pack in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(verbatim: pack.title).font(.headline)
                    if pack.recommended {
                        Text("Recommended")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if controller.engine.packInstalled && controller.engine.packID == pack.id {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                if let note = pack.note {
                    Text(verbatim: note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(pack.models, id: \.self) { modelID in
                    if let model = controller.catalog.model(id: modelID) {
                        HStack {
                            Text(verbatim: model.title)
                            Spacer()
                            let pinnedBytes = Int64(model.files.compactMap(\.bytes).reduce(0, +))
                            if pinnedBytes > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: pinnedBytes, countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: model.license).foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                }
                HStack {
                    Button("Download") { Task { await controller.download(pack) } }
                        .disabled(!controller.canDownload(pack))
                    Button("Pause") { Task { await controller.pauseDownload() } }
                    Button("Resume") { Task { await controller.resumeDownload() } }
                    Button("Delete", role: .destructive) { Task { await controller.deletePack(pack) } }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

/// Models for one task: what is in use, what is downloaded, and what the Hub
/// has that this app's runtimes can load. Nothing else is listed.
struct TaskModelList: View {
    let task: ModelTask
    @ObservedObject var controller: SessionController
    @ObservedObject var library: ModelLibrary

    private var installedHere: [HubCandidate] {
        library.installed.filter { $0.task == task }
    }

    private var available: [HubCandidate] {
        (library.results[task] ?? []).filter { candidate in !installedHere.contains { $0.repo == candidate.repo } }
    }

    var body: some View {
        List {
            Section {
                Text(task.subtitle + " Only Hugging Face models that this app can run for this task are listed. Files download to this device and are checked against the Hub's sha256.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("In use") {
                builtInRow
                ForEach(installedHere) { candidate in
                    CandidateRow(candidate: candidate, controller: controller, library: library)
                }
            }
            Section {
                if library.searching.contains(task) && available.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Searching Hugging Face…").foregroundStyle(.secondary)
                    }
                } else if let error = library.searchErrors[task] {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                } else if available.isEmpty {
                    Text("No other compatible models found.").foregroundStyle(.secondary)
                }
                ForEach(available) { candidate in
                    CandidateRow(candidate: candidate, controller: controller, library: library)
                }
            } header: {
                HStack {
                    Text("Available on Hugging Face")
                    Spacer()
                    Button {
                        Task { await library.search(task) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(library.searching.contains(task))
                }
            }
        }
        .task {
            if library.results[task] == nil { await library.search(task) }
        }
    }

    private var builtInTitle: String {
        guard let pack = controller.catalog.pack(id: controller.engine.packID) else { return "Pack model" }
        let id: String?
        switch task {
        case .speech(let language):
            guard language.inPack else { return "None in the pack" }
            id = PackPolicy.speechID(pack: pack, catalog: controller.catalog, language: language)
        case .translation: id = PackPolicy.translatorID(pack: pack, catalog: controller.catalog)
        case .notes: id = PackPolicy.notesID(pack: pack, catalog: controller.catalog)
        }
        return id.flatMap { controller.catalog.model(id: $0)?.title } ?? "Pack model"
    }

    private var builtInRow: some View {
        let selected = library.selected(task) == nil
        return HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: builtInTitle)
                Text("From the \(controller.packName) pack · \(task == .translation || task == .notes ? ModelRuntime.mlx.accelerator : ModelRuntime.sherpaStreaming.accelerator)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !selected {
                Button("Use") { controller.choose(nil, for: task) }
            }
        }
        .contentShape(Rectangle())
    }
}

struct CandidateRow: View {
    let candidate: HubCandidate
    @ObservedObject var controller: SessionController
    @ObservedObject var library: ModelLibrary

    var body: some View {
        let status = library.status(of: candidate)
        let inUse = library.selected(candidate.task) == candidate
        HStack(alignment: .top, spacing: 10) {
            if status == .installed {
                Image(systemName: inUse ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(inUse ? Color.accentColor : .secondary)
            } else {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let url = URL(string: "https://huggingface.co/\(candidate.repo)") {
                        Link(destination: url) {
                            Text(verbatim: candidate.repo)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .help(candidate.repo)
                    }
                    badge(candidate.runtime.accelerator, tint: candidate.runtime == .coreMLNemotron ? .green : .blue)
                }
                HStack(spacing: 10) {
                    if candidate.totalBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: candidate.totalBytes, countStyle: .file))
                    }
                    Label("\(candidate.downloads)", systemImage: "arrow.down.circle")
                    if let license = candidate.license {
                        Text(verbatim: license)
                    }
                    if candidate.runtime == .coreMLNemotron {
                        Text("Lowest CPU use")
                    }
                    if candidate.task == .translation {
                        Text(candidate.multilingual == true ? "Many languages" : "Thai ⇄ English")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                statusLine(status)
            }
            Spacer()
            actions(status, inUse: inUse)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLine(_ status: ModelLibrary.Status) -> some View {
        switch status {
        case .downloading(let fraction, let bytes):
            ProgressView(value: fraction) {
                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: candidate.totalBytes, countStyle: .file))")
                    .font(.caption)
            }
            .frame(maxWidth: 320)
        case .paused(let bytes):
            Text("Paused at \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))").font(.caption)
        case .verifying:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking hashes and opening the model…").font(.caption)
            }
        case .failed(let message):
            Text(verbatim: message).font(.caption).foregroundStyle(.red)
        case .installed, .notInstalled:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(_ status: ModelLibrary.Status, inUse: Bool) -> some View {
        HStack {
            switch status {
            case .notInstalled, .failed:
                Button("Download") { library.download(candidate) }
                    .disabled(controller.engine.listening)
            case .downloading:
                Button("Pause") { library.pause(candidate) }
                Button("Cancel", role: .destructive) { controller.deleteHubModel(candidate) }
            case .paused:
                Button("Resume") { library.download(candidate) }
                    .disabled(controller.engine.listening)
                Button("Cancel", role: .destructive) { controller.deleteHubModel(candidate) }
            case .verifying:
                EmptyView()
            case .installed:
                if !inUse {
                    Button("Use") { controller.choose(candidate, for: candidate.task) }
                        .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    controller.deleteHubModel(candidate)
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete the downloaded files")
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

#if DEBUG
#Preview("Session", traits: .fixedLayout(width: 1280, height: 640)) {
    if let controller = SessionController.demo() {
        SessionScreen(controller: controller, shell: .mac, landscape: false, regularWidth: true)
    }
}

#Preview("Models", traits: .fixedLayout(width: 760, height: 600)) {
    if let controller = SessionController.demo() {
        ModelScreen(controller: controller, library: controller.library)
    }
}
#endif
