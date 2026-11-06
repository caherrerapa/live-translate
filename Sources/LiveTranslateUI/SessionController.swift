import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the speech side is doing, for the status bar.
enum EngineStatus: Equatable {
    case idle
    case loading(String)
    case ready(String)
    case failed(String)
}

@MainActor
final class SessionController: ObservableObject {
    /// Published by hand: `mutate` always notifies, while speech updates notify only when
    /// something on screen changed, so unchanged hypotheses do not re-render the window.
    private(set) var engine: SessionEngine
    @Published var showModels = false
    @Published var renaming = false
    @Published var renameText = ""
    @Published var exportPresented = false
    @Published var statusLine = ""
    @Published var typeScale: Double = 1.15
    @Published var phoneShowsNotes = false
    @Published private(set) var speechStatus: EngineStatus = .idle
    @Published private(set) var translatorStatus: EngineStatus = .idle
    @Published private(set) var notesRunning = false
    @Published private(set) var listenStarted: Date?
    @Published var toast: String?
    /// History for the sidebar, newest first. The live session is `current`.
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var current: SessionRecord
    /// A past session being read. Nil shows the live session.
    @Published var viewingID: UUID?
    @Published var layout: TranscriptLayout = .sideBySide
    @Published var audioSource: AudioSourceKind = .microphone
    @Published private(set) var paused = false
    @Published var summaryLanguage: SpeechLanguage?
    @Published private(set) var translatedNoteText: [String: String] = [:]
    @Published private(set) var exporting = false
    @Published var notionSetupPresented = false
    let levels = LevelMeter()
    #if DEBUG
    /// Automated checks feed a recording here instead of the microphone.
    var automationFeed: URL?
    #endif

    var isTranslating: Bool {
        #if os(macOS)
        translationRunning
        #else
        false
        #endif
    }
    let catalog: ModelCatalog
    let packID: String
    let platform: String
    let installer: PackInstaller
    let library: ModelLibrary
    private var capture: AudioCapturing = MicrophoneCapture()
    private let store: SessionStore
    private var pausedTotal: TimeInterval = 0
    private var pauseStarted: Date?
    private var lastAutosave = Date.distantPast
    private var noteTranslationQueue: [String] = []
    /// Held while listening so App Nap cannot throttle the transcript when the window is in the background.
    private var listenActivity: NSObjectProtocol?
    private var notesPrewarmed = false
    @Published private(set) var stopping = false
    private let worker = SpeechWorker()
    private let storage: URL
    private var ticker: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var preparingListen = false
    private var listenWhenReady = false
    private var activeSpeechKey: String?
    private var speechGeneration = 0
    private var renameTurnID: String?
    private var speakerLabeler = LSEENDSpeakerLabeler()
    private var labelerReady = false
    private let notesQueue = DispatchQueue(label: "live-translate.notes", qos: .utility)
    #if os(macOS)
    private let notesClient = TyphoonNotesClient()
    private var translator: ChindaTranslator?
    private var translationRunning = false
    private var terminationObserver: NSObjectProtocol?
    #endif

    init(catalog: ModelCatalog, packID: String, platform: String, storage: URL) {
        self.catalog = catalog
        self.packID = packID
        self.platform = platform
        self.storage = storage
        #if os(macOS)
        notesClient.packID = packID
        let client = notesClient
        var notes = NotesReducer { input in
            NotesProductionPass.produce(input: input) { client.draft(for: $0) }
        }
        // The notes model takes seconds per pass. It runs on `notesQueue`, never inline on the main thread.
        notes.defersModel = true
        #else
        let notes = NotesReducer { input in
            NotesProductionPass.produce(input: input) { _ in
                NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
            }
        }
        #endif
        engine = SessionEngine(catalog: catalog, packID: packID, packInstalled: false, notes: notes)
        store = SessionStore(storage: storage)
        sessions = store.loadAll()
        current = SessionRecord(started: Date(), direction: .thaiToEnglish)
        copyOptions = Self.loadCopyOptions()
        installer = PackInstaller(root: storage) { url, offset in
            RangeByteSource(url: url, offset: offset)
        }
        library = ModelLibrary(storage: storage)
        library.verifyInstall = { [weak self] candidate, directory in
            await self?.verifyRuntime(candidate: candidate, directory: directory)
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
        #if os(macOS)
        notesClient.modelOverride = library.selected(.notes).map { library.modelDirectory(for: $0) }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        #endif
        Task { await refreshInstall() }
        Task { await prepareLabeler() }
    }

    func noteRotation() {
        mutate { $0.noteRotation() }
    }

    var packName: String { engine.packName }

    var listenTitle: String { engine.listening ? "Stop" : "Listen" }

    var isPreparing: Bool { preparingListen || listenWhenReady }

    var platformPacks: [ModelPack] {
        PackPolicy.packs(on: platform, catalog: catalog)
    }

    /// Listen works with the pack, or with a downloaded speech model for the source language.
    var canListen: Bool {
        (engine.packInstalled || hasSelectedSpeech) && !engine.microphoneDenied
    }

    private var hasSelectedSpeech: Bool {
        library.selected(.speech(engine.direction.source)) != nil
    }

    // MARK: Install

    func refreshInstall() async {
        #if os(macOS)
        await adoptProducedFiles(packID: engine.packID)
        #endif
        let files = pinnedFiles(packID: engine.packID)
        let installed = await installer.isInstalled(packID: engine.packID, files: files)
        // A downloaded speech model is enough to listen; the session engine gates on this flag.
        // Listen needs a speech model for the spoken language: the pack's (Thai, English) or a downloaded one.
        let source = engine.direction.source
        let speechReady = (installed && source.inPack) || hasSelectedSpeech
        mutate { $0.packInstalled = speechReady }
        if speechReady {
            statusLine = ""
        } else if installed || !source.inPack {
            statusLine = "No \(source.title) speech model yet. Open Manage languages and download one from \(source.title) streaming."
        } else {
            statusLine = "\(packName) is not on this machine."
        }
        prepareSpeech()
        #if os(macOS)
        prepareTranslator()
        if installed && !notesPrewarmed {
            notesPrewarmed = true
            let client = notesClient
            notesQueue.async { client.prewarm() }
        }
        #endif
    }

    // MARK: Listen

    func listenOrStop() {
        if listenWhenReady && !engine.listening {
            stopListening()
            return
        }
        if engine.listening {
            // Stop hearing now, but let the words already captured finish before the turn commits.
            capture.stop()
            stopping = true
            worker.drain { [weak self] in
                self?.stopping = false
                self?.stopListening()
            }
            return
        }
        if stopping { return }
        guard engine.listenEnabled, engine.packInstalled else { return }
        if preparingListen { return }
        #if DEBUG
        // A recorded test feed does not use the microphone.
        if automationFeed != nil {
            beginCapture()
            return
        }
        #endif
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .denied || status == .restricted {
            mutate { $0.microphoneDenied = true }
            return
        }
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.beginCapture()
                    } else {
                        self.mutate { $0.microphoneDenied = true }
                    }
                }
            }
            return
        }
        beginCapture()
    }

    private func stopListening() {
        listenWhenReady = false
        if let listenActivity {
            ProcessInfo.processInfo.endActivity(listenActivity)
            self.listenActivity = nil
        }
        capture.stop()
        worker.stop()
        levels.reset()
        if let started = listenStarted {
            current.duration += Date().timeIntervalSince(started) - pausedTotal - (pauseStarted.map { Date().timeIntervalSince($0) } ?? 0)
        }
        listenStarted = nil
        paused = false
        pauseStarted = nil
        pausedTotal = 0
        guard engine.listening else { return }
        mutate { $0.stop(at: Date()) }
        persistCurrent()
        library.listening = false
        Task { await installer.setListening(false) }
        #if os(macOS)
        if let request = engine.pendingTranslation, !translationRunning {
            translationRunning = true
            runTranslation(request)
        }
        #endif
    }

    func openSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    func setDirection(_ direction: TranslationDirection) {
        guard !engine.listening else { return }
        mutate { $0.direction = direction }
        Task { await refreshInstall() }
    }

    func swapDirection() {
        setDirection(engine.direction.reversed)
    }

    func setPreset(_ preset: LatencyPreset) {
        mutate { $0.preset = preset }
        prepareSpeech()
    }

    /// The speech graph for the current direction and preset, loaded off the main thread.
    /// The worker keeps it resident, so Listen starts at once and a swap back is free.
    func prepareSpeech() {
        guard let plan = speechPlan() else {
            let language = engine.direction.source
            speechStatus = .failed("No \(language.title) speech model yet. Open Manage languages → \(language.title) streaming.")
            return
        }
        if plan.key == activeSpeechKey, case .ready = speechStatus { return }
        speechGeneration += 1
        let generation = speechGeneration
        speechStatus = .loading(plan.title)
        worker.activate(key: plan.key, make: plan.make) { [weak self] decoder in
            guard let self, generation == self.speechGeneration else { return }
            if let decoder {
                self.activeSpeechKey = plan.key
                self.speechStatus = .ready("\(plan.title) · \(decoder.engineLabel)")
                if self.listenWhenReady {
                    self.listenWhenReady = false
                    self.startListening()
                }
            } else {
                self.activeSpeechKey = nil
                self.speechStatus = .failed("\(plan.title) could not be opened.")
                self.listenWhenReady = false
            }
        }
    }

    private struct SpeechPlan {
        var key: String
        var title: String
        var make: () -> LiveSpeechDecoder?
    }

    private func speechPlan() -> SpeechPlan? {
        let language = engine.direction.source
        if let candidate = library.selected(.speech(language)) {
            let directory = library.modelDirectory(for: candidate)
            let title = candidate.repo.split(separator: "/").last.map(String.init) ?? candidate.repo
            switch candidate.runtime {
            case .coreMLNemotron:
                return SpeechPlan(key: "hub:\(candidate.id)", title: title) {
                    CoreMLNemotronDecoder(directory: directory)
                }
            case .sherpaStreaming:
                #if os(macOS)
                let prompted = candidate.featureDim == 128
                return SpeechPlan(key: "hub:\(candidate.id)", title: title) {
                    SherpaStreamingDecoder(
                        directory: directory,
                        language: language,
                        featureDim: candidate.featureDim,
                        prompted: prompted
                    )
                }
                #else
                return nil
                #endif
            case .mlx:
                return nil
            }
        }
        #if os(macOS)
        guard engine.packInstalled, language.inPack else { return nil }
        let chunk = engine.chunkMilliseconds() ?? 1040
        let precision = PackPolicy.speechPrecision(packID: engine.packID)
        let packID = engine.packID
        let storage = self.storage
        let title = language == .thai ? "Typhoon ASR 0.6B" : "Nemotron 3.5 EN"
        return SpeechPlan(key: "pack:\(packID):\(language.rawValue):\(chunk):\(precision)", title: "\(title) \(chunk) ms") {
            SherpaStreamingDecoder(
                language: language,
                chunkMS: chunk,
                precision: precision,
                installRoot: storage,
                packID: packID
            )
        }
        #else
        return nil
        #endif
    }

    private func prepareLabeler() async {
        let labeler = speakerLabeler
        await labeler.prepare()
        labelerReady = true
        worker.setLabeler(labeler)
    }

    private func beginCapture() {
        mutate { $0.microphoneDenied = false }
        if case .ready = speechStatus {
            startListening()
        } else {
            // The graph is still loading. Listen starts the moment it is ready.
            listenWhenReady = true
            prepareSpeech()
        }
    }

    private func startListening() {
        mutate { $0.setListening(true) }
        guard engine.listening, engine.packInstalled else { return }
        library.listening = true
        Task { await installer.setListening(true) }
        #if os(macOS)
        prepareTranslator()
        #endif
        worker.start { [weak self] update in
            DispatchQueue.main.async {
                self?.apply(update)
            }
        }
        if current.turns.isEmpty && engine.turns.isEmpty {
            current.started = Date()
            current.direction = engine.direction
        }
        viewingID = nil
        do {
            try startCapture()
            listenStarted = Date()
            paused = false
            pausedTotal = 0
            listenActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Live translation is listening"
            )
        } catch {
            captureFailed(error)
        }
    }

    /// Samples go from the audio thread to the speech queue and the level meter.
    /// The main thread never decodes.
    private func startCapture() throws {
        #if os(macOS)
        capture = audioSource == .systemAudio ? SystemAudioCapture() : MicrophoneCapture()
        #if DEBUG
        if let automationFeed { capture = FileCapture(url: automationFeed) }
        #endif
        #else
        capture = MicrophoneCapture()
        #endif
        let worker = self.worker
        let meter = levels
        let tap = LevelTap { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { meter.push(level) } }
        }
        try capture.start(onSamples: { samples in
            worker.push(samples)
            tap.feed(samples)
        }, onError: { [weak self] error in
            DispatchQueue.main.async { self?.captureFailed(error) }
        })
    }

    private func captureFailed(_ error: Error) {
        if let listenActivity {
            ProcessInfo.processInfo.endActivity(listenActivity)
            self.listenActivity = nil
        }
        capture.stop()
        worker.stop()
        library.listening = false
        listenStarted = nil
        paused = false
        Task { await installer.setListening(false) }
        if audioSource == .systemAudio {
            mutate { $0.setListening(false) }
            show("System audio needs Screen Recording access in System Settings.")
            #if os(macOS)
            // Shows the system prompt the first time; after a refusal macOS only allows the Settings pane.
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            #endif
        } else {
            mutate { $0.setListening(false); $0.microphoneDenied = true }
        }
    }

    /// Pause keeps the session open and stops hearing. Resume continues the same session.
    func pauseOrResume() {
        guard engine.listening else { return }
        if paused {
            do {
                try startCapture()
                if let since = pauseStarted { pausedTotal += Date().timeIntervalSince(since) }
                pauseStarted = nil
                paused = false
            } catch {
                captureFailed(error)
            }
        } else {
            capture.stop()
            levels.reset()
            pauseStarted = Date()
            paused = true
        }
    }

    /// Switching source mid-session restarts capture on the new source; the session continues.
    func setAudioSource(_ source: AudioSourceKind) {
        guard source != audioSource else { return }
        audioSource = source
        guard engine.listening, !paused else { return }
        capture.stop()
        do {
            try startCapture()
        } catch {
            captureFailed(error)
        }
    }

    /// Listening time, excluding pauses.
    func elapsed(at date: Date) -> TimeInterval {
        guard let started = listenStarted else { return current.duration }
        let pausedNow = pauseStarted.map { date.timeIntervalSince($0) } ?? 0
        return current.duration + date.timeIntervalSince(started) - pausedTotal - pausedNow
    }

    private func apply(_ update: SpeechWorker.Update) {
        guard engine.listening else { return }
        var request: TranslationRequest?
        mutate({ engine in
            engine.pushHypothesis(update.step.text, speakerRaw: update.speakerRaw, at: Date(), endpoint: update.step.endpoint)
            request = engine.pendingTranslation
        }, quietUnlessVisible: true)
        #if os(macOS)
        if let request, !translationRunning {
            translationRunning = true
            runTranslation(request)
        }
        #endif
    }

    // MARK: Session actions

    func toggleNotes() {
        mutate { $0.notesHidden.toggle() }
    }

    func toggleSpeakers() {
        mutate { $0.speakers.chipsVisible.toggle() }
    }

    func highlight() {
        mutate { $0.highlightCurrent(now: Date()) }
        show("Pinned to Highlights")
    }

    func clearSession() {
        guard !engine.listening else { return }
        mutate { $0.clear() }
    }

    // MARK: History

    /// The record the screen shows: a past session, or the live one kept in sync with the engine.
    var displayedRecord: SessionRecord {
        if let viewingID, let past = sessions.first(where: { $0.id == viewingID }) {
            return past
        }
        var live = engine.record(updating: current)
        if let started = engine.startedAt, !live.turns.isEmpty { live.started = started }
        return live
    }

    var isViewingPast: Bool {
        viewingID != nil && viewingID != current.id
    }

    /// Saves the live session and starts an empty one.
    func newSession() {
        if engine.listening { stopListening() }
        persistCurrent()
        mutate { $0.clear() }
        current = SessionRecord(started: Date(), direction: engine.direction)
        translatedNoteText.removeAll()
        viewingID = nil
    }

    func open(_ id: UUID) {
        viewingID = id == current.id ? nil : id
    }

    func deleteSession(_ id: UUID) {
        store.delete(id)
        sessions.removeAll { $0.id == id }
        if viewingID == id { viewingID = nil }
        if id == current.id {
            if engine.listening { stopListening() }
            mutate { $0.clear() }
            current = SessionRecord(started: Date(), direction: engine.direction)
        }
    }

    func renameDisplayed(_ title: String) {
        update { $0.title = title }
    }

    func setUserNotes(_ text: String) {
        update { $0.userNotes = text }
    }

    func toggleAction(_ id: String) {
        update { record in
            if record.checkedActions.contains(id) {
                record.checkedActions.remove(id)
            } else {
                record.checkedActions.insert(id)
            }
        }
    }

    /// Edits the record on screen. Past sessions save at once; the live one saves with the session.
    private func update(_ change: (inout SessionRecord) -> Void) {
        if isViewingPast, let index = sessions.firstIndex(where: { $0.id == viewingID }) {
            change(&sessions[index])
            store.save(sessions[index])
        } else {
            change(&current)
            if !engine.turns.isEmpty || !current.userNotes.isEmpty { persistCurrent() }
        }
    }

    /// Writes the live session to history. Text only.
    private func persistCurrent() {
        var record = engine.record(updating: current)
        if listenStarted != nil {
            // Mid-session autosave: the duration so far, without moving the running clock.
            record.duration = elapsed(at: Date())
        }
        guard !record.isEmpty else { return }
        // Turn times are offsets from the engine's first words; the record's clock starts there too.
        if let started = engine.startedAt, !record.turns.isEmpty {
            record.started = started
        }
        var kept = record
        if listenStarted != nil { kept.duration = current.duration }
        current = kept
        if let index = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[index] = record
        } else {
            sessions.insert(record, at: 0)
        }
        store.save(record)
        lastAutosave = Date()
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Identifiable {
        case markdown, text, json
        var id: String { rawValue }
        var title: String {
            switch self {
            case .markdown: return "Markdown"
            case .text: return "Plain text"
            case .json: return "JSON"
            }
        }
        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .text: return "txt"
            case .json: return "json"
            }
        }
    }

    func exportData(_ format: ExportFormat) -> Data {
        let record = displayedRecord
        switch format {
        case .markdown: return Data(record.markdown().utf8)
        case .text: return Data(record.plainText().utf8)
        case .json: return (try? record.jsonData()) ?? Data()
        }
    }

    func copySummary() {
        copySession(.summary)
    }

    func exportToNotion() {
        let settings = NotionExport.load()
        guard settings.isComplete else {
            notionSetupPresented = true
            return
        }
        let record = displayedRecord
        exporting = true
        Task {
            defer { exporting = false }
            do {
                let url = try await NotionExport.export(record, settings: settings)
                show("Exported to Notion")
                #if os(macOS)
                if let url { NSWorkspace.shared.open(url) }
                #endif
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    // MARK: Summary language

    /// The note is written in the translation language. The other language is translated on demand.
    var noteLanguage: SpeechLanguage {
        displayedRecord.direction.target
    }

    func noteText(_ text: String) -> String {
        guard let wanted = summaryLanguage, wanted != noteLanguage else { return text }
        return translatedNoteText["\(wanted.code)|\(text)"] ?? text
    }

    func setSummaryLanguage(_ language: SpeechLanguage) {
        summaryLanguage = language
        guard language != noteLanguage else { return }
        let note = displayedRecord.note
        let texts = (note.summary + note.decisions + note.openQuestions + note.highlights + note.actions).map(\.text)
        noteTranslationQueue = texts.filter { translatedNoteText["\(language.code)|\($0)"] == nil }
        #if os(macOS)
        translateNextNoteText()
        #endif
    }

    func beginRename(_ turnID: String) {
        guard let turn = engine.turns.first(where: { $0.id == turnID }) else { return }
        renameTurnID = turn.id
        renameText = turn.speakerLabel
        renaming = true
    }

    func renameCurrent(to name: String) {
        guard let turnID = renameTurnID else { return }
        mutate { $0.rename(turnID: turnID, to: name) }
        renaming = false
        renameTurnID = nil
    }

    func focus(_ id: String) {
        mutate { $0.focusedTurnID = id }
    }

    func deleteNote(id: String) {
        mutate { $0.notes.delete(itemID: id) }
    }

    enum CopyPart {
        case source
        case translation
        case both
    }

    func copy(turn: SessionTurn, part: CopyPart) {
        let source = turn.sourceDisplay
        let translation = turn.translationCommitted + turn.translationProvisional
        switch part {
        case .source: setPasteboard(source)
        case .translation: setPasteboard(translation)
        case .both: setPasteboard([source, translation].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        show(part == .translation ? "Translation copied" : part == .source ? "Detected text copied" : "Turn copied")
    }

    /// Whole session as plain text, one turn per paragraph.
    @Published var copyOptions = SessionCopyOptions() {
        didSet { saveCopyOptions() }
    }

    /// The shown session with live text in full: the open turn's tail and provisional translation included.
    private var copyRecord: SessionRecord {
        var record = displayedRecord
        guard !isViewingPast else { return record }
        record.turns = engine.turns.filter { !$0.sourceDisplay.isEmpty }.map { turn in
            SavedTurn(
                id: turn.id,
                source: turn.sourceDisplay,
                translation: turn.translationCommitted + turn.translationProvisional,
                speaker: engine.speakers.chipsVisible ? turn.speakerLabel : "",
                start: turn.start,
                end: turn.end ?? turn.start,
                direction: turn.direction.rawValue
            )
        }
        return record
    }

    func copySession(_ kind: SessionCopyKind) {
        setPasteboard(copyRecord.copyText(kind, options: copyOptions))
        switch kind {
        case .original: show("Original copied")
        case .translation: show("Translation copied")
        case .bilingual: show("Bilingual transcript copied")
        case .summary: show("Summary copied")
        }
    }

    /// Column headers and the phone: whole-session copy of one side.
    func copyAll(_ part: CopyPart) {
        switch part {
        case .source: copySession(.original)
        case .translation: copySession(.translation)
        case .both: copySession(.bilingual)
        }
    }

    func copy(text: String, label: String) {
        setPasteboard(text)
        show(label)
    }

    private func saveCopyOptions() {
        UserDefaults.standard.set(copyOptions.speakerNames, forKey: "copySpeakers")
        UserDefaults.standard.set(copyOptions.timestamps, forKey: "copyTimestamps")
        UserDefaults.standard.set(copyOptions.markdown, forKey: "copyMarkdown")
    }

    private static func loadCopyOptions() -> SessionCopyOptions {
        let defaults = UserDefaults.standard
        var options = SessionCopyOptions()
        if defaults.object(forKey: "copySpeakers") != nil { options.speakerNames = defaults.bool(forKey: "copySpeakers") }
        options.timestamps = defaults.bool(forKey: "copyTimestamps")
        options.markdown = defaults.bool(forKey: "copyMarkdown")
        return options
    }

    func copyTranscript() {
        setPasteboard(engine.saveDocument().plainText())
        show("Transcript copied")
    }

    private func setPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func show(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func saveData() -> Data? {
        try? engine.saveDocument().jsonData()
    }

    // MARK: Packs and models

    func select(packID: String) async {
        if engine.listening { stopListening() }
        #if os(macOS)
        await adoptProducedFiles(packID: packID)
        #endif
        let files = pinnedFiles(packID: packID)
        let installed = await installer.isInstalled(packID: packID, files: files)
        #if os(macOS)
        notesClient.packID = packID
        let client = notesClient
        notesQueue.async { client.stop() }
        #endif
        mutate {
            $0.packID = packID
            $0.packInstalled = installed
            $0.preset = ChunkPolicy.preset(named: catalog.pack(id: packID)?.defaultPreset)
        }
        statusLine = installed ? "" : "\(engine.packName) is not on this machine."
        await refreshInstall()
    }

    /// Use a downloaded model (or nil for the pack's own) for one task.
    func choose(_ candidate: HubCandidate?, for task: ModelTask) {
        if engine.listening { stopListening() }
        library.select(candidate, for: task)
        switch task {
        case .speech:
            activeSpeechKey = nil
            Task { await refreshInstall() }
        case .translation:
            #if os(macOS)
            translator?.stop()
            translator = nil
            translatorStatus = .idle
            prepareTranslator()
            #endif
        case .notes:
            #if os(macOS)
            notesClient.modelOverride = candidate.map { library.modelDirectory(for: $0) }
            #endif
        }
    }

    func deleteHubModel(_ candidate: HubCandidate) {
        let wasSelected = library.selected(candidate.task) == candidate
        library.delete(candidate)
        if wasSelected { choose(nil, for: candidate.task) }
    }

    /// Opens a fresh download once to prove the runtime accepts it. Nil means it opened.
    private func verifyRuntime(candidate: HubCandidate, directory: URL) async -> String? {
        switch candidate.runtime {
        case .sherpaStreaming:
            #if os(macOS)
            guard let language = candidate.task.speechLanguage,
                  let executable = Bundle.main.executableURL else { return "Not a speech model." }
            // sherpa-onnx exits the process on a graph it cannot use, so the first open
            // happens in a child copy of this app, never in the session process.
            return await withCheckedContinuation { continuation in
                let probe = Process()
                probe.executableURL = executable
                probe.arguments = [
                    "--probe-speech", directory.path,
                    "--dim", String(candidate.featureDim),
                    "--language", language.code,
                ]
                probe.standardOutput = FileHandle.nullDevice
                probe.standardError = FileHandle.nullDevice
                probe.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus == 0 ? nil : "sherpa-onnx could not stream with this graph.")
                }
                do {
                    try probe.run()
                } catch {
                    continuation.resume(returning: "Could not start the model check.")
                }
            }
            #else
            return "ONNX streaming runs on the Mac build."
            #endif
        case .coreMLNemotron:
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let decoder = CoreMLNemotronDecoder(directory: directory)
                    decoder?.close()
                    continuation.resume(returning: decoder == nil ? "Core ML could not load the model." : nil)
                }
            }
        case .mlx:
            return MLXSupport.check(directory: directory)
        }
    }

    func canDownload(_ pack: ModelPack) -> Bool {
        !engine.listening && pinnedFiles(packID: pack.id).contains(where: \.hasHash)
    }

    func download(_ pack: ModelPack) async {
        guard !engine.listening else {
            statusLine = "Downloads wait until Listen stops."
            return
        }
        #if os(macOS)
        await installer.allowAdopt(packID: pack.id)
        await adoptProducedFiles(packID: pack.id)
        #endif
        let files = pinnedFiles(packID: pack.id).filter(\.hasHash)
        guard !files.isEmpty else {
            statusLine = "\(pack.title) has no pinned hash yet."
            return
        }
        if await installer.isInstalled(packID: pack.id, files: files) {
            if pack.id == engine.packID {
                await refreshInstall()
            }
            return
        }
        for file in files {
            let result = await installer.download(packID: pack.id, file: file)
            if result != .installed {
                statusLine = "\(pack.title) is not installed."
                await refreshInstall()
                return
            }
        }
        await refreshInstall()
    }

    func pauseDownload() async {
        await installer.pause()
    }

    func resumeDownload() async {
        guard !engine.listening else { return }
        await installer.resume()
    }

    func deletePack(_ pack: ModelPack) async {
        if engine.listening { stopListening() }
        worker.evictAll()
        activeSpeechKey = nil
        await installer.suppressAdopt(packID: pack.id)
        try? await installer.delete(packID: pack.id)
        await refreshInstall()
    }

    // MARK: Translation

    #if os(macOS)
    /// The translator for the current direction: the user's pick if it covers the pair,
    /// the pack's ChindaMT for Thai ⇄ English, else any downloaded multilingual model.
    private var translatorModel: URL? {
        let direction = engine.direction
        if let chosen = library.selected(.translation), chosen.translates(direction) {
            return library.modelDirectory(for: chosen)
        }
        if direction.isThaiEnglish, let pack = OnDevicePaths.translatorDirectory(packID: engine.packID) {
            return pack
        }
        if let multilingual = library.installed.first(where: { $0.task == .translation && $0.multilingual == true }) {
            return library.modelDirectory(for: multilingual)
        }
        return nil
    }

    /// Starts the MLX translator early so its weights are on the GPU before the first turn.
    /// A direction that needs another model restarts the process with that model.
    private func prepareTranslator() {
        guard let model = translatorModel else {
            translator?.stop()
            translator = nil
            let direction = engine.direction
            translatorStatus = .failed("No translator for \(direction.source.title) → \(direction.target.title). Download a multilingual model in Manage languages → Translation.")
            return
        }
        if let translator, translator.modelDirectory == model { return }
        guard !translationRunning else { return }
        translator?.stop()
        translator = nil
        let chinda = ChindaTranslator()
        if chinda.start(model: model) {
            translator = chinda
            translatorStatus = .ready("\(model.lastPathComponent.replacingOccurrences(of: "translation__", with: "")) · \(ModelRuntime.mlx.accelerator)")
        } else {
            translatorStatus = .failed("The MLX runtime is not in this build.")
        }
    }

    private func runTranslation(_ request: TranslationRequest) {
        if translator == nil { prepareTranslator() }
        guard let translator else {
            translationRunning = false
            mutate { _ = $0.deliverTranslation(generation: request.generation, text: "", at: Date()) }
            return
        }
        translator.translate(generation: request.generation, prompt: request.prompt) { [weak self] generation, text in
            self?.finishTranslation(generation: generation, text: text)
        }
    }

    private func finishTranslation(generation: Int, text: String) {
        var followUp: TranslationRequest?
        mutate { engine in
            let accepted = engine.deliverTranslation(generation: generation, text: text, at: Date())
            if accepted {
                followUp = engine.pendingTranslation
            } else {
                followUp = engine.retryTranslation(at: Date())
            }
        }
        if let followUp {
            runTranslation(followUp)
            return
        }
        translationRunning = false
        translateNextNoteText()
    }

    /// Translates note lines one at a time, only while the live translator is idle.
    private func translateNextNoteText() {
        guard !translationRunning, engine.pendingTranslation == nil, !noteTranslationQueue.isEmpty else { return }
        if translator == nil { prepareTranslator() }
        guard let translator else { return }
        let text = noteTranslationQueue.removeFirst()
        let direction = TranslationDirection(source: noteLanguage, target: summaryLanguage ?? noteLanguage)
        translationRunning = true
        translator.translate(generation: -1, prompt: TranslationPrompt.text(source: text, direction: direction)) { [weak self] _, translated in
            guard let self else { return }
            self.translationRunning = false
            if !translated.isEmpty { self.translatedNoteText["\(direction.target.code)|\(text)"] = translated }
            if let request = self.engine.pendingTranslation {
                self.translationRunning = true
                self.runTranslation(request)
            } else {
                self.translateNextNoteText()
            }
        }
    }

    private func shutdown() {
        if engine.listening { stopListening() } else { persistCurrent() }
        capture.stop()
        worker.stop()
        worker.evictAll()
        translator?.stop()
        translator = nil
        notesClient.stop()
    }
    #endif

    // MARK: Engine

    private func tick() {
        if engine.listening, Date().timeIntervalSince(lastAutosave) > 15 {
            persistCurrent()
        }
        // Only touch the published engine when a notes pass is actually due.
        guard engine.notes.isDue(now: Date()) else { return }
        mutate { $0.tick(now: Date()) }
    }

    private func mutate(_ body: (inout SessionEngine) -> Void, quietUnlessVisible: Bool = false) {
        var copy = engine
        body(&copy)
        let pass = copy.notes.takeRequestedPass()
        let visible = !quietUnlessVisible
            || copy.turns != engine.turns
            || copy.notes.note != engine.notes.note
            || copy.listening != engine.listening
        if visible { objectWillChange.send() }
        engine = copy
        if let pass { runNotesPass(pass) }
    }

    #if DEBUG
    /// When notes passes ran, for correlating with stalls in automated checks.
    private(set) var notesActivity: [(start: Date, end: Date?)] = []
    #endif

    private func runNotesPass(_ input: NotesInput) {
        let model = engine.notes.model
        notesRunning = true
        #if DEBUG
        notesActivity.append((Date(), nil))
        #endif
        notesQueue.async { [weak self] in
            let draft = model(input)
            DispatchQueue.main.async {
                guard let self else { return }
                self.notesRunning = false
                #if DEBUG
                if let last = self.notesActivity.indices.last { self.notesActivity[last].end = Date() }
                #endif
                self.mutate { $0.notes.finishDeferredPass(draft, now: Date()) }
            }
        }
    }

    private func pinnedFiles(packID: String) -> [PackFileSpec] {
        guard let pack = catalog.pack(id: packID) else { return [] }
        var files: [PackFileSpec] = []
        for modelID in pack.models {
            guard let model = catalog.model(id: modelID), model.task != "diarization" else { continue }
            for file in model.files where file.hasHash {
                let remote = file.url.flatMap(URL.init(string:)) ?? model.huggingFaceRepo.flatMap {
                    HuggingFaceURL.file(repo: $0, name: file.name)
                }
                files.append(PackFileSpec(modelID: modelID, name: file.name, sha256: file.sha256, url: remote))
            }
        }
        return files
    }

    #if os(macOS)
    private func adoptProducedFiles(packID: String) async {
        for file in pinnedFiles(packID: packID) {
            guard let source = OnDevicePaths.producedSpeechFile(modelID: file.modelID, name: file.name) else { continue }
            await installer.adoptIfMissing(packID: packID, file: file, source: source)
        }
    }
    #endif

    func listenDiagnostics() -> String {
        let chunk = engine.chunkMilliseconds() ?? 0
        let precision = PackPolicy.speechPrecision(packID: engine.packID)
        let graph = SpeechGraphs.directoryName(language: engine.direction.source, chunkMS: chunk, precision: precision)
        let notesName = engine.packID == PackPolicy.phonePackID
            ? "typhoon2-3b-instruct-4bit"
            : "typhoon2-qwen2.5-7b-instruct-4bit"
        let translatorName = engine.packID == PackPolicy.phonePackID ? "chindamt-4b-4bit" : "chindamt-4b-8bit"
        return [
            "pack_id \(engine.packID)",
            "pack_installed \(engine.packInstalled)",
            "listen_enabled \(engine.listenEnabled)",
            "precision \(precision)",
            "chunk_ms \(chunk)",
            "graph \(graph)",
            "notes_model \(notesName)",
            "translator \(translatorName)",
            "labeler LSEENDSpeakerLabeler",
        ].joined(separator: "\n")
    }
}

/// Used when this target has no speech graph loaded. It returns no text.
struct MissingSpeechDecoder: PartialDecoding {
    mutating func decode(pcm: [Float]) -> StreamStep {
        _ = pcm
        return StreamStep(text: "", endpoint: false)
    }
}

#if DEBUG
extension SessionController {
    /// A session with two turns, for previews only.
    static func demo() -> SessionController? {
        let catalog = (try? ModelCatalog.loadFromBundle())
            ?? OnDevicePreviewCatalog.load()
        guard let catalog else { return nil }
        let controller = SessionController(
            catalog: catalog,
            packID: PackPolicy.macPackID,
            platform: "macos",
            storage: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lt-preview")
        )
        controller.loadDemo()
        return controller
    }

    func demoPackMissing() {
        mutate { $0.clear(); $0.packInstalled = false }
        speechStatus = .idle
    }

    func stopDemoListening() {
        mutate { $0.listening = false }
    }

    func loadDemo() {
        let start = Date().addingTimeInterval(-360)
        let lines: [(Int, String, String, Bool)] = [
            (0, "Thanks for joining, everyone. The main thing today is the rollout schedule for the three new stores opening in January.", "ขอบคุณทุกคนที่มาร่วมประชุม เรื่องหลักวันนี้คือกำหนดการเปิดร้านใหม่สามสาขาในเดือนมกราคม", true),
            (1, "We can deliver the kiosks for the first two stores by the fifteenth. The third store depends on the building permit, which we're still waiting on.", "เราส่งตู้คีออสก์สำหรับสองสาขาแรกได้ภายในวันที่ 15 ส่วนสาขาที่สามขึ้นอยู่กับใบอนุญาตก่อสร้าง ซึ่งเรายังรออยู่", true),
            (0, "When do you expect to hear back on the permit?", "คาดว่าจะได้คำตอบเรื่องใบอนุญาตเมื่อไร", true),
            (1, "Sure. I'll also add the staff training dates so everyone can plan around the opening", "ได้เลย จะเพิ่มวันอบรมพนักงานไปด้วย เพื่อให้ทุกคนวางแผน", false),
        ]
        mutate { engine in
            engine.clear()
            engine.direction = .englishToThai
            engine.packInstalled = true
            engine.setListening(true)
            for (index, line) in lines.enumerated() {
                let at = start.addingTimeInterval(Double(index) * 70)
                engine.pushHypothesis(line.1, speakerRaw: line.0, at: at, endpoint: line.3)
                while let request = engine.pendingTranslation {
                    engine.deliverTranslation(generation: request.generation, text: line.2, at: at)
                }
            }
            engine.rename(ordinal: 1, to: "Sarah")
            engine.notes.note.summary = [NoteItem(id: "s1", text: "Supplier call on opening three new stores in January. The first two are on track; the third depends on a building permit.", turnID: "t1", speaker: "", tentative: false)]
            engine.notes.note.decisions = [
                NoteItem(id: "d1", text: "Kiosks for the first two stores arrive by 15 January.", turnID: "t2", speaker: "Speaker 2", tentative: false),
                NoteItem(id: "d2", text: "Staff training dates will be added to the timeline.", turnID: "t4", speaker: "Speaker 2", tentative: true),
            ]
            engine.notes.note.actions = [NoteItem(id: "a1", text: "Send the updated timeline to the team", turnID: "t4", speaker: "Speaker 2", tentative: false)]
        }
        current.title = "Supplier call — January rollout"
        current.userNotes = ""
        speechStatus = .ready("Nemotron EN · Neural Engine · Core ML")
        translatorStatus = .ready("chindamt-4b-bf16 · GPU · Metal (MLX)")
        listenStarted = Date().addingTimeInterval(-768)
        for value in stride(from: 0, to: 1, by: 0.04) {
            levels.push(Float(abs(sin(value * 19)) * 0.8 + 0.1))
        }
    }
}

enum OnDevicePreviewCatalog {
    static func load() -> ModelCatalog? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/model-catalog.json")
        return try? ModelCatalog.load(from: url)
    }
}
#endif
