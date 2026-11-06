#if os(macOS)
import Foundation

/// The worse of the two growing-turn bf16 lags, 0.850 s and 0.867 s.
/// It is inside the Accurate bound, so Listen loads bf16. The catalog pack stays 8-bit.
enum MacTranslationSpike {
    static let bf16LagSeconds = 0.867
}

enum OnDevicePaths {
    static func repoRoot() -> URL? {
        var candidates = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let env = ProcessInfo.processInfo.environment["LIVE_TRANSLATE_ROOT"], !env.isEmpty {
            candidates.insert(URL(fileURLWithPath: env), at: 0)
        }
        candidates.append(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("workspace/live-translate")
        )
        for root in candidates {
            let catalog = root.appendingPathComponent("docs/model-catalog.json")
            if FileManager.default.fileExists(atPath: catalog.path) {
                return root
            }
        }
        return nil
    }

    static func producedSpeechFile(modelID: String, name: String) -> URL? {
        let allowed = ["encoder.onnx", "encoder.data", "decoder.onnx", "joiner.onnx", "tokens.txt"]
        guard allowed.contains(name), let root = repoRoot() else { return nil }
        let folder: String
        switch modelID {
        case "typhoon-asr-streaming-nemotron-0.6b":
            folder = "typhoon-0.6b-1040"
        case "nemotron-3.5-asr-streaming-0.6b-en":
            folder = "nemotron-en-1120"
        default:
            return nil
        }
        let url = root.appendingPathComponent("models/onnx").appendingPathComponent(folder).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Installed pack paths, then a produced graph for this trained chunk.
    /// Int8 does not fall back to the full-precision files.
    static func speechGraph(
        language: SpeechLanguage,
        chunkMS: Int,
        precision: String,
        installRoot: URL,
        packID: String
    ) -> (encoder: URL, decoder: URL, joiner: URL, tokens: URL)? {
        let modelID = language == .thai
            ? "typhoon-asr-streaming-nemotron-0.6b"
            : "nemotron-3.5-asr-streaming-0.6b-en"
        let folder = SpeechGraphs.directoryName(language: language, chunkMS: chunkMS, precision: precision)
        let modelDir = installRoot
            .appendingPathComponent(packID, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
        var directories = [modelDir.appendingPathComponent(folder, isDirectory: true)]
        let accurate = (language == .thai && chunkMS == 1040) || (language == .english && chunkMS == 1120)
        if precision != "int8", accurate {
            directories.append(modelDir)
        }
        if precision != "int8", let root = repoRoot() {
            directories.append(root.appendingPathComponent("models/onnx").appendingPathComponent(folder))
        }
        return SpeechGraphs.existing(directories: directories)
    }

    static func translatorDirectory(packID: String = PackPolicy.macPackID) -> URL? {
        guard let root = repoRoot() else { return nil }
        if packID == PackPolicy.phonePackID {
            let phone = root.appendingPathComponent("models/chindamt-4b-4bit")
            return FileManager.default.fileExists(atPath: phone.appendingPathComponent("config.json").path) ? phone : nil
        }
        let chosen = TranslatorChoice.macModelID(bf16LagSeconds: MacTranslationSpike.bf16LagSeconds)
        let preferred = root.appendingPathComponent("models").appendingPathComponent(chosen)
        if FileManager.default.fileExists(atPath: preferred.appendingPathComponent("config.json").path) {
            return preferred
        }
        let fallback = root.appendingPathComponent("models/chindamt-4b-8bit")
        if FileManager.default.fileExists(atPath: fallback.appendingPathComponent("config.json").path) {
            return fallback
        }
        return nil
    }

    static func notesDirectory(packID: String) -> URL? {
        guard let root = repoRoot() else { return nil }
        let name = packID == PackPolicy.phonePackID
            ? "typhoon2-3b-instruct-4bit"
            : "typhoon2-qwen2.5-7b-instruct-4bit"
        let url = root.appendingPathComponent("models").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) ? url : nil
    }

    /// Python that ships inside the built app. The checkout virtualenv is not used.
    static func python() -> URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let url = resource.appendingPathComponent("mlx-runtime/bin/python3")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func chindaScript() -> URL? {
        guard let resource = Bundle.main.resourceURL else { return nil }
        let bundled = resource.appendingPathComponent("chinda_serve.py")
        return FileManager.default.fileExists(atPath: bundled.path) ? bundled : nil
    }
}

@_silgen_name("lt_open")
private func lt_open(
    _ encoder: UnsafePointer<CChar>,
    _ decoder: UnsafePointer<CChar>,
    _ joiner: UnsafePointer<CChar>,
    _ tokens: UnsafePointer<CChar>,
    _ language: UnsafePointer<CChar>
) -> OpaquePointer?

@_silgen_name("lt_push")
private func lt_push(
    _ handle: OpaquePointer,
    _ samples: UnsafePointer<Float>?,
    _ count: Int32,
    _ out: UnsafeMutablePointer<CChar>,
    _ capacity: Int32,
    _ endpoint: UnsafeMutablePointer<Int32>?
) -> Int32

@_silgen_name("lt_close")
private func lt_close(_ handle: OpaquePointer)

/// Cache-aware sherpa stream linked into the app. Thai and English share this loop.
final class SherpaStreamingDecoder: PartialDecoding {
    let graphDirectory: URL
    private let handle: OpaquePointer
    private var closed = false

    init?(language: SpeechLanguage, chunkMS: Int, precision: String, installRoot: URL, packID: String) {
        guard let graph = OnDevicePaths.speechGraph(
            language: language,
            chunkMS: chunkMS,
            precision: precision,
            installRoot: installRoot,
            packID: packID
        ) else {
            return nil
        }
        let opened = graph.encoder.path.withCString { encoder in
            graph.decoder.path.withCString { decoder in
                graph.joiner.path.withCString { joiner in
                    graph.tokens.path.withCString { tokens in
                        language.prompt.withCString { prompt in
                            lt_open(encoder, decoder, joiner, tokens, prompt)
                        }
                    }
                }
            }
        }
        guard let opened else { return nil }
        handle = opened
        graphDirectory = graph.encoder.deletingLastPathComponent()
    }

    func decode(pcm: [Float]) -> StreamStep {
        var endpoint: Int32 = 0
        var bytes = [CChar](repeating: 0, count: 8192)
        let code = pcm.withUnsafeBufferPointer { samples in
            bytes.withUnsafeMutableBufferPointer { out -> Int32 in
                guard let base = out.baseAddress else { return -1 }
                return lt_push(handle, samples.baseAddress, Int32(samples.count), base, Int32(out.count), &endpoint)
            }
        }
        guard code == 0 else { return StreamStep(text: "", endpoint: false) }
        return StreamStep(text: String(cString: bytes), endpoint: endpoint == 1)
    }

    func close() {
        guard !closed else { return }
        closed = true
        lt_close(handle)
    }
}

/// One local ChindaMT process. It receives the translation prompt, never audio.
final class ChindaTranslator {
    private let queue = DispatchQueue(label: "live-translate.chinda")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var ready = false
    private var dead = false
    private var waiter: ((Int, String) -> Void)?
    private var pendingGeneration: Int?
    private var queued: (Int, String)?

    func start() -> Bool {
        guard process == nil,
              let python = OnDevicePaths.python(),
              let script = OnDevicePaths.chindaScript(),
              let model = OnDevicePaths.translatorDirectory() else { return false }
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, model.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.absorb(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.failPending() }
        }
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process
        input = stdinPipe.fileHandleForWriting
        return true
    }

    func translate(generation: Int, prompt: String, done: @escaping (Int, String) -> Void) {
        queue.async {
            if self.dead || self.process == nil {
                DispatchQueue.main.async { done(generation, "") }
                return
            }
            self.waiter = done
            self.pendingGeneration = generation
            guard self.ready, let input = self.input else {
                self.queued = (generation, prompt)
                return
            }
            self.write(generation: generation, prompt: prompt, to: input)
        }
    }

    func stop() {
        queue.async {
            if let input = self.input {
                let line = Data("{\"cmd\":\"stop\"}\n".utf8)
                try? input.write(contentsOf: line)
            }
            self.dead = true
            self.process?.terminate()
            self.process = nil
            self.input = nil
            self.ready = false
            self.waiter = nil
            self.pendingGeneration = nil
            self.queued = nil
        }
    }

    private func failPending() {
        dead = true
        ready = false
        process = nil
        input = nil
        queued = nil
        let generation = pendingGeneration ?? -1
        let done = waiter
        waiter = nil
        pendingGeneration = nil
        if let done {
            DispatchQueue.main.async { done(generation, "") }
        }
    }

    private func write(generation: Int, prompt: String, to input: FileHandle) {
        let body: [String: Any] = ["id": generation, "prompt": prompt]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var line = data
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func absorb(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let chunk = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(chunk)) as? [String: Any] else { continue }
            if object["ready"] as? Bool == true {
                ready = true
                if let queued, let input {
                    write(generation: queued.0, prompt: queued.1, to: input)
                    self.queued = nil
                }
                continue
            }
            let generation = object["id"] as? Int ?? pendingGeneration ?? -1
            let text = object["text"] as? String ?? ""
            let done = waiter
            waiter = nil
            pendingGeneration = nil
            if let done {
                DispatchQueue.main.async { done(generation, text) }
            }
        }
    }
}
#endif
