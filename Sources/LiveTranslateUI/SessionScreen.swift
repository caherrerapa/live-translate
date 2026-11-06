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

struct SessionScreen: View {
    @ObservedObject var controller: SessionController
    var shell: AppShell
    var landscape: Bool
    var regularWidth: Bool
    @State private var showsSecondary = false

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
                    Divider()
                    HStack(spacing: 0) {
                        panels
                        if notesOn {
                            Divider()
                            notesColumn.frame(width: SessionLayout.notesColumnWidth)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $controller.showModels) {
            ModelScreen(controller: controller)
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
                if controller.phoneShowsNotes {
                    notesColumn
                } else {
                    panels
                }
                HStack(spacing: 12) {
                    ForEach(chrome.bottomBeside, id: \.self) { control in
                        phoneBeside(control)
                    }
                    if chrome.bottomProminent == chrome.prominent {
                        listenButton
                            .controlSize(.large)
                    }
                }
                .padding()
            }
            .navigationTitle("Live Translate")
            .toolbar {
                if chrome.navigationBar.contains(.direction) {
                    ToolbarItem { directionMenu }
                }
                if chrome.navigationBar.contains(.models) {
                    ToolbarItem {
                        Button("Models") { controller.showModels = true }
                    }
                }
            }
        }
    }

    private var macBar: some View {
        HStack(spacing: 16) {
            ForEach(chrome.alwaysVisible, id: \.self) { control in
                stripControl(control)
                    .frame(maxWidth: control == chrome.prominent ? .infinity : 240)
            }
            if !chrome.secondary.isEmpty {
                moreButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var moreButton: some View {
        Button {
            showsSecondary = true
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("More")
        .accessibilityIdentifier("secondaryChrome")
        .popover(isPresented: $showsSecondary, arrowEdge: .top) {
            secondaryPanel
                .padding(16)
                .frame(minWidth: 320)
        }
    }

    @ViewBuilder
    private func stripControl(_ control: SessionControl) -> some View {
        switch control {
        case .direction:
            directionMenu
                .frame(maxWidth: 240)
                .accessibilityIdentifier("directionControl")
        case .listenStop where control == chrome.prominent:
            listenButton
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        default:
            EmptyView()
        }
    }

    private var listenButton: some View {
        Button(action: controller.listenOrStop) {
            Label(controller.listenTitle, systemImage: controller.engine.listening ? "stop.fill" : "waveform")
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .disabled(!controller.engine.listenEnabled && !controller.engine.listening)
        .accessibilityIdentifier("listenButton")
    }

    private var secondaryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(chrome.secondary, id: \.self) { control in
                secondaryControl(control)
            }
        }
    }

    @ViewBuilder
    private func secondaryControl(_ control: SessionControl) -> some View {
        switch control {
        case .highlight:
            Button("Highlight", action: controller.highlight)
                .buttonStyle(.bordered)
        case .speakers:
            Button(controller.engine.speakers.chipsVisible ? "Hide speakers" : "Show speakers", action: controller.toggleSpeakers)
                .buttonStyle(.bordered)
        case .notes:
            Button(controller.engine.notesHidden ? "Show notes" : "Hide notes", action: controller.toggleNotes)
                .buttonStyle(.bordered)
        case .fast, .balanced, .accurate:
            if control == chrome.secondary.first(where: { [.fast, .balanced, .accurate].contains($0) }) {
                latencyPicker
            }
        case .models:
            Button("Models") { controller.showModels = true }
                .buttonStyle(.bordered)
        case .type:
            Stepper("Type", value: $controller.typeScale, in: 0.9...1.6, step: 0.1)
                .accessibilityIdentifier("typeControl")
        case .copy:
            Button("Copy", action: controller.copyTranscript)
                .buttonStyle(.bordered)
        case .save:
            Button("Save") { controller.exportPresented = true }
                .buttonStyle(.bordered)
        case .direction, .listenStop, .conversation, .notesPage:
            EmptyView()
        }
    }

    private var latencyPicker: some View {
        Picker("Latency", selection: presetBinding) {
            ForEach(LatencyPreset.allCases, id: \.self) { preset in
                if chrome.secondary.contains(latencyControl(preset)) {
                    Text(preset.title).tag(preset)
                }
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
    }

    private func latencyControl(_ preset: LatencyPreset) -> SessionControl {
        switch preset {
        case .fast: return .fast
        case .balanced: return .balanced
        case .accurate: return .accurate
        }
    }

    @ViewBuilder
    private func phoneBeside(_ control: SessionControl) -> some View {
        switch control {
        case .highlight:
            Button("Highlight", action: controller.highlight)
                .buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }

    private var directionMenu: some View {
        Picker("Direction", selection: directionBinding) {
            Text(TranslationDirection.thaiToEnglish.title).tag(TranslationDirection.thaiToEnglish)
            Text(TranslationDirection.englishToThai.title).tag(TranslationDirection.englishToThai)
        }
        .labelsHidden()
        .disabled(controller.engine.listening)
    }

    private var panels: some View {
        VStack(spacing: 0) {
            panelHeaders
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if controller.engine.turns.isEmpty {
                            emptyRow
                        }
                        ForEach(controller.engine.turns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: controller.engine.focusedTurnID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .font(.system(size: 16 * controller.typeScale))
    }

    private var panelHeaders: some View {
        HStack(spacing: 0) {
            Text(sourceTitle).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            if arrangement == .sideBySide {
                Divider()
                Text(targetTitle).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }
        .font(.headline)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder
    private var emptyRow: some View {
        switch controller.engine.listenState {
        case .packMissing(let packName):
            VStack(alignment: .leading, spacing: 8) {
                paired(Text(packName).font(.title3.weight(.semibold)), Text(packName).font(.title3.weight(.semibold)))
                    .accessibilityIdentifier("packName")
                Text(controller.statusLine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                Button("Models") { controller.showModels = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("missingPackModels")
            }
        case .microphoneDenied:
            VStack(alignment: .leading, spacing: 8) {
                Text("The microphone is off.")
                Button("Settings", action: controller.openSettings)
            }
            .padding(16)
        case .idle:
            paired(
                Text(ListenPolicy.idleLine),
                Text(ListenPolicy.idleLine)
            )
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("idleLine")
        case .listening, .listeningSilence:
            EmptyView()
        }
    }

    private func turnRow(_ turn: SessionTurn) -> some View {
        paired(sourceBlock(turn), translationBlock(turn))
            .padding(.vertical, 6)
            .background(controller.engine.focusedTurnID == turn.id ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func sourceBlock(_ turn: SessionTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.engine.speakers.chipsVisible {
                speakerChip(turn)
            }
            Text(turn.sourcePrefix)
            if !turn.committed && !turn.sourceTail.isEmpty {
                Text(turn.sourceTail + " ▍")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func translationBlock(_ turn: SessionTurn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(turn.translationCommitted)
            if !turn.translationProvisional.isEmpty && turn.translationProvisional != turn.translationCommitted {
                Text(turn.translationProvisional)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func speakerChip(_ turn: SessionTurn) -> some View {
        let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown]
        if let index = controller.engine.speakers.colorIndex(ordinal: turn.speakerOrdinal, paletteCount: colors.count) {
            Button {
                controller.beginRename(turn.id)
            } label: {
                Text(turn.speakerLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(colors[index].opacity(0.2), in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var notesColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Notes")
                    .font(.headline)
                if controller.engine.notes.note.title.text.isEmpty
                    && controller.engine.notes.note.summary.isEmpty
                    && controller.engine.notes.note.highlights.isEmpty {
                    Text(NotesReducer.emptyLine)
                        .foregroundStyle(.secondary)
                }
                noteBlock("Title", items: controller.engine.notes.note.title.text.isEmpty ? [] : [controller.engine.notes.note.title])
                noteBlock("Summary", items: controller.engine.notes.note.summary)
                noteBlock("Decisions", items: controller.engine.notes.note.decisions)
                noteBlock("Actions", items: controller.engine.notes.note.actions)
                noteBlock("Open questions", items: controller.engine.notes.note.openQuestions)
                noteBlock("Highlights", items: controller.engine.notes.note.highlights)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func noteBlock(_ title: String, items: [NoteItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                Text(title).font(.subheadline.weight(.semibold))
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                        HStack {
                            if !item.speaker.isEmpty {
                                Text(item.speaker).font(.caption).foregroundStyle(.secondary)
                            }
                            if item.tentative {
                                Text("Tentative").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Turn") { controller.focus(item.turnID) }
                                .font(.caption)
                            Button("Delete") { controller.deleteNote(id: item.id) }
                                .font(.caption)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func paired(_ source: some View, _ translation: some View) -> some View {
        if arrangement == .stacked {
            VStack(alignment: .leading, spacing: 8) {
                source
                Divider()
                translation
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                source
                Divider()
                translation
            }
        }
    }

    private var sourceTitle: String {
        controller.engine.direction.source == .thai ? "Thai" : "English"
    }

    private var targetTitle: String {
        controller.engine.direction.target == .thai ? "Thai" : "English"
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

struct ModelScreen: View {
    @ObservedObject var controller: SessionController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(controller.platformPacks) { pack in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(pack.title).font(.headline)
                        if pack.recommended {
                            Text("Recommended")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    if let note = pack.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(pack.models, id: \.self) { modelID in
                        if let model = controller.catalog.model(id: modelID) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.title)
                                Text("\(model.task) · \(model.license)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                let pinnedBytes = model.files.compactMap(\.bytes).reduce(0, +)
                                if pinnedBytes > 0 {
                                    Text("\(pinnedBytes) bytes pinned")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text(controller.engine.packInstalled && controller.engine.packID == pack.id
                         ? "Installed"
                         : "\(pack.title) is not on this machine.")
                        .font(.callout)
                    HStack {
                        Button("Download") { Task { await controller.download(pack) } }
                            .disabled(!controller.canDownload(pack))
                        Button("Pause") { Task { await controller.pauseDownload() } }
                        Button("Resume") { Task { await controller.resumeDownload() } }
                        Button("Delete") { Task { await controller.deletePack(pack) } }
                    }
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Models")
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
