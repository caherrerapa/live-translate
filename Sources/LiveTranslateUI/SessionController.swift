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
    @Published private(set) var engine: SessionEngine
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
    let catalog: ModelCatalog
    let packID: String
    let platform: String
    let installer: PackInstaller
    let library: ModelLibrary
    private let capture = MicrophoneCapture()
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
        mutate { $0.packInstalled = installed || hasSelectedSpeech }
        if installed || hasSelectedSpeech {
            statusLine = ""
        } else {
            statusLine = "\(packName) is not on this machine."
        }
        prepareSpeech()
        #if os(macOS)
        prepareTranslator()
        #endif
    }

    // MARK: Listen

    func listenOrStop() {
        if engine.listening || listenWhenReady {
            stopListening()
            return
        }
        guard engine.listenEnabled, engine.packInstalled else { return }
        if preparingListen { return }
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
        capture.stop()
        worker.stop()
        listenStarted = nil
        guard engine.listening else { return }
        mutate { $0.stop(at: Date()) }
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
        setDirection(engine.direction == .thaiToEnglish ? .englishToThai : .thaiToEnglish)
    }

    func setPreset(_ preset: LatencyPreset) {
        mutate { $0.preset = preset }
        prepareSpeech()
    }

    /// The speech graph for the current direction and preset, loaded off the main thread.
    /// The worker keeps it resident, so Listen starts at once and a swap back is free.
    func prepareSpeech() {
        guard let plan = speechPlan() else {
            speechStatus = engine.packInstalled ? .failed("No speech model for \(engine.direction.source == .thai ? "Thai" : "English").") : .idle
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
        guard engine.packInstalled else { return nil }
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
        let worker = self.worker
        do {
            // Samples go from the audio thread to the speech queue. The main thread never decodes.
            try capture.start { samples in
                worker.push(samples)
            }
            listenStarted = Date()
        } catch {
            capture.stop()
            worker.stop()
            library.listening = false
            mutate { $0.setListening(false); $0.microphoneDenied = true }
            Task { await installer.setListening(false) }
        }
    }

    private func apply(_ update: SpeechWorker.Update) {
        guard engine.listening else { return }
        var request: TranslationRequest?
        mutate { engine in
            engine.pushHypothesis(update.step.text, speakerRaw: update.speakerRaw, at: Date(), endpoint: update.step.endpoint)
            request = engine.pendingTranslation
        }
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
    func copyAll(_ part: CopyPart) {
        let lines = engine.turns.compactMap { turn -> String? in
            let speaker = engine.speakers.chipsVisible && !turn.speakerLabel.isEmpty ? "\(turn.speakerLabel): " : ""
            let source = turn.sourceDisplay
            let translation = turn.translationCommitted + turn.translationProvisional
            switch part {
            case .source: return source.isEmpty ? nil : speaker + source
            case .translation: return translation.isEmpty ? nil : speaker + translation
            case .both: return source.isEmpty ? nil : speaker + source + (translation.isEmpty ? "" : "\n" + translation)
            }
        }
        setPasteboard(lines.joined(separator: "\n\n"))
        show(part == .source ? "All detected text copied" : part == .translation ? "All translations copied" : "Transcript copied")
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
        case .thaiSpeech, .englishSpeech:
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
                    "--language", language == .thai ? "th" : "en",
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
    private var translatorModel: URL? {
        if let candidate = library.selected(.translation) {
            return library.modelDirectory(for: candidate)
        }
        return OnDevicePaths.translatorDirectory(packID: engine.packID)
    }

    /// Starts the MLX translator early so its weights are on the GPU before the first turn.
    private func prepareTranslator() {
        guard translator == nil, engine.packInstalled, let model = translatorModel else {
            if translator == nil, engine.packInstalled, translatorModel == nil {
                translatorStatus = .failed("No translation model on this Mac.")
            }
            return
        }
        let chinda = ChindaTranslator()
        if chinda.start(model: model) {
            translator = chinda
            translatorStatus = .ready("\(model.lastPathComponent) · \(ModelRuntime.mlx.accelerator)")
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
    }

    private func shutdown() {
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
        // Only touch the published engine when a notes pass is actually due.
        guard engine.notes.isDue(now: Date()) else { return }
        mutate { $0.tick(now: Date()) }
    }

    private func mutate(_ body: (inout SessionEngine) -> Void) {
        var copy = engine
        body(&copy)
        let pass = copy.notes.takeRequestedPass()
        engine = copy
        if let pass { runNotesPass(pass) }
    }

    private func runNotesPass(_ input: NotesInput) {
        let model = engine.notes.model
        notesRunning = true
        notesQueue.async { [weak self] in
            let draft = model(input)
            DispatchQueue.main.async {
                guard let self else { return }
                self.notesRunning = false
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

    func stopDemoListening() {
        mutate { $0.listening = false }
    }

    func loadDemo() {
        let start = Date()
        mutate { engine in
            engine.direction = .englishToThai
            engine.packInstalled = true
            engine.setListening(true)
            engine.pushHypothesis("Meeting starts at nine. Please send the notes today.", speakerRaw: 0, at: start, endpoint: true)
            if let request = engine.pendingTranslation {
                engine.deliverTranslation(generation: request.generation, text: "การประชุมเริ่มเวลา 09.00 น. กรุณาส่งบันทึกการประชุมในวันนี้", at: start)
            }
            engine.pushHypothesis("We decided to ship the translation on this", speakerRaw: 1, at: start.addingTimeInterval(4), endpoint: false)
            engine.pushHypothesis("We decided to ship the translation on this machine", speakerRaw: 1, at: start.addingTimeInterval(4.2), endpoint: false)
            if let request = engine.pendingTranslation {
                engine.deliverTranslation(generation: request.generation, text: "เราตัดสินใจที่จะส่งการแปล", at: start)
            }
        }
        speechStatus = .ready("Nemotron EN · Neural Engine · Core ML")
        translatorStatus = .ready("chindamt-4b-bf16 · GPU · Metal (MLX)")
        listenStarted = start.addingTimeInterval(-42)
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
