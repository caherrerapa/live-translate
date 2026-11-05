import AVFoundation
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    let catalog: ModelCatalog
    let packID: String
    let platform: String
    let installer: PackInstaller
    private let capture = MicrophoneCapture()
    private let storage: URL
    private var ticker: Task<Void, Never>?
    private var preparingListen = false
    private var renameTurnID: String?
    #if os(macOS)
    private var speech: SherpaStreamingDecoder?
    private var translator: ChindaTranslator?
    private var translationRunning = false
    private var speakerLabeler = LSEENDSpeakerLabeler()
    #endif

    init(catalog: ModelCatalog, packID: String, platform: String, storage: URL) {
        self.catalog = catalog
        self.packID = packID
        self.platform = platform
        self.storage = storage
        let notes = NotesReducer { input in
            SessionController.draft(from: input)
        }
        engine = SessionEngine(catalog: catalog, packID: packID, packInstalled: false, notes: notes)
        installer = PackInstaller(root: storage) { url, offset in
            RangeByteSource(url: url, offset: offset)
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.tick()
            }
        }
        Task { await refreshInstall() }
    }

    func noteRotation() {
        mutate { $0.noteRotation() }
    }

    var packName: String { engine.packName }

    var listenTitle: String { engine.listening ? "Stop" : "Listen" }

    var platformPacks: [ModelPack] {
        PackPolicy.packs(on: platform, catalog: catalog)
    }

    func refreshInstall() async {
        #if os(macOS)
        await adoptProducedFiles(packID: engine.packID)
        #endif
        let files = pinnedFiles(packID: engine.packID)
        let installed = await installer.isInstalled(packID: engine.packID, files: files)
        mutate { $0.packInstalled = installed }
        if installed {
            statusLine = ""
        } else {
            statusLine = "\(packName) is not on this machine."
        }
    }

    func listenOrStop() {
        if engine.listening {
            capture.stop()
            #if os(macOS)
            speech?.close()
            speech = nil
            #endif
            mutate { $0.stop(at: Date()) }
            Task { await installer.setListening(false) }
            #if os(macOS)
            if let request = engine.pendingTranslation, !translationRunning {
                translationRunning = true
                runTranslation(request)
            } else if !translationRunning {
                translator?.stop()
                translator = nil
            }
            #endif
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
    }

    func setPreset(_ preset: LatencyPreset) {
        mutate { $0.preset = preset }
    }

    func toggleNotes() {
        mutate { $0.notesHidden.toggle() }
    }

    func toggleSpeakers() {
        mutate { $0.speakers.chipsVisible.toggle() }
    }

    func highlight() {
        mutate { $0.highlightCurrent(now: Date()) }
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

    func copyTranscript() {
        let text = engine.saveDocument().plainText()
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    func saveData() -> Data? {
        try? engine.saveDocument().jsonData()
    }

    func select(packID: String) async {
        if engine.listening {
            capture.stop()
            mutate { $0.stop(at: Date()); $0.setListening(false) }
            await installer.setListening(false)
        }
        #if os(macOS)
        await adoptProducedFiles(packID: packID)
        #endif
        let files = pinnedFiles(packID: packID)
        let installed = await installer.isInstalled(packID: packID, files: files)
        mutate {
            $0.packID = packID
            $0.packInstalled = installed
            $0.preset = ChunkPolicy.preset(named: catalog.pack(id: packID)?.defaultPreset)
        }
        statusLine = installed ? "" : "\(engine.packName) is not on this machine."
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
                mutate { $0.packInstalled = true }
                statusLine = ""
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
        if engine.listening {
            capture.stop()
            #if os(macOS)
            speech?.close()
            speech = nil
            #endif
            mutate { $0.stop(at: Date()) }
            await installer.setListening(false)
            #if os(macOS)
            if let request = engine.pendingTranslation, !translationRunning {
                translationRunning = true
                runTranslation(request)
            } else if !translationRunning {
                translator?.stop()
                translator = nil
            }
            #endif
        }
        await installer.suppressAdopt(packID: pack.id)
        try? await installer.delete(packID: pack.id)
        await refreshInstall()
    }

    private func beginCapture() {
        #if os(macOS)
        preparingListen = true
        Task {
            await speakerLabeler.prepare()
            preparingListen = false
            guard !engine.listening else { return }
            startListening()
        }
        #else
        startListening()
        #endif
    }

    private func startListening() {
        mutate { $0.microphoneDenied = false; $0.setListening(true) }
        guard engine.listening, engine.packInstalled else { return }
        Task { await installer.setListening(true) }
        #if os(macOS)
        speech = SherpaStreamingDecoder(language: engine.direction.source, installRoot: storage, packID: engine.packID)
        let chinda = ChindaTranslator()
        if chinda.start() {
            translator = chinda
        }
        #endif
        do {
            try capture.start { [weak self] samples in
                Task { @MainActor in
                    self?.keepInMemory(samples)
                }
            }
        } catch {
            capture.stop()
            #if os(macOS)
            speech?.close()
            speech = nil
            translator?.stop()
            translator = nil
            #endif
            mutate { $0.setListening(false); $0.microphoneDenied = true }
            Task { await installer.setListening(false) }
        }
    }

    /// The buffer lives on the heap. A missing pack never reaches this, and a
    /// missing graph does not invent a partial. With a graph, the same samples
    /// go through the cache-aware stream and the ChindaMT scheduler.
    private func keepInMemory(_ samples: [Float]) {
        guard engine.packInstalled, engine.listening else { return }
        guard let buffer = AudioBuffer.capture(samples: samples, sampleRate: AudioBuffer.captureRate, filePath: nil) else {
            return
        }
        #if os(macOS)
        guard var decoder = speech else { return }
        var request: TranslationRequest?
        mutate { engine in
            _ = engine.push(buffer: buffer, decoder: &decoder, speakers: &speakerLabeler, at: Date())
            request = engine.pendingTranslation
        }
        if let request, !translationRunning {
            translationRunning = true
            runTranslation(request)
        }
        #else
        _ = buffer.samples
        #endif
    }

    #if os(macOS)
    private func runTranslation(_ request: TranslationRequest) {
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
        if !engine.listening {
            translator?.stop()
            translator = nil
        }
    }
    #endif

    private func tick() {
        mutate { $0.tick(now: Date()) }
    }

    private func mutate(_ body: (inout SessionEngine) -> Void) {
        var copy = engine
        body(&copy)
        engine = copy
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

    private static func draft(from input: NotesInput) -> NotesDraft {
        let turn = input.turns.last
        let text = turn?.translation ?? ""
        let item = DraftItem(text: text, turnID: turn?.id ?? "", speaker: turn?.speaker ?? "", contradictsTurnID: nil)
        return NotesDraft(
            title: text.isEmpty ? "" : String(text.prefix(48)),
            titleTurnID: turn?.id ?? "",
            summary: text.isEmpty ? [] : [item],
            decisions: [],
            actions: [],
            openQuestions: []
        )
    }
}
