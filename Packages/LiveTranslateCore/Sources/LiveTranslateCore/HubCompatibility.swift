import Foundation

/// One job a downloadable model can do in a session. The model screen lists
/// Hugging Face repos per task, and only repos this app's runtimes can load.
enum ModelTask: Hashable, Identifiable, Sendable {
    case speech(SpeechLanguage)
    case translation
    case notes

    static let thaiSpeech = ModelTask.speech(.thai)
    static let englishSpeech = ModelTask.speech(.english)

    static var allCases: [ModelTask] {
        SpeechLanguage.allCases.map { .speech($0) } + [.translation, .notes]
    }

    var id: String { rawValue }

    /// Stored in manifests and selections. Thai and English keep their original names.
    var rawValue: String {
        switch self {
        case .speech(.thai): return "thaiSpeech"
        case .speech(.english): return "englishSpeech"
        case .speech(let language): return "speech-\(language.code)"
        case .translation: return "translation"
        case .notes: return "notes"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "thaiSpeech": self = .speech(.thai)
        case "englishSpeech": self = .speech(.english)
        case "translation": self = .translation
        case "notes": self = .notes
        default:
            guard rawValue.hasPrefix("speech-"), let language = SpeechLanguage(code: String(rawValue.dropFirst(7))) else {
                return nil
            }
            self = .speech(language)
        }
    }

    var title: String {
        switch self {
        case .speech(let language): return "\(language.title) streaming"
        case .translation: return "Translation"
        case .notes: return "Notes"
        }
    }

    var subtitle: String {
        switch self {
        case .speech(let language): return "Streaming speech recognition for \(language.title)."
        case .translation: return "Text translation. ChindaMT covers Thai ⇄ English; multilingual instruct models cover the other pairs."
        case .notes: return "Instruct model that writes the live meeting note."
        }
    }

    var systemImage: String {
        switch self {
        case .speech: return "waveform"
        case .translation: return "character.bubble"
        case .notes: return "list.bullet.rectangle"
        }
    }

    var speechLanguage: SpeechLanguage? {
        if case .speech(let language) = self { return language }
        return nil
    }

    /// Hub searches that surface candidates for this task. Every result still has
    /// to pass `HubCompatibility.candidate`, so a broad query cannot leak through.
    var searchQueries: [String] {
        switch self {
        case .speech(.thai):
            return [
                "search=typhoon-asr-streaming",
                "search=sherpa-onnx-streaming&limit=100",
                "search=streaming&filter=th&filter=onnx",
            ]
        case .speech(.english):
            return [
                "search=nemotron-speech-streaming-en",
                "search=sherpa-onnx-streaming-zipformer-en",
                "search=sherpa-onnx-streaming&limit=100",
                "search=sherpa-onnx-nemo-streaming",
            ]
        case .speech(let language):
            return [
                "search=sherpa-onnx-streaming&limit=100",
                "search=sherpa-onnx-streaming-zipformer-\(language.code)",
                "search=streaming&filter=\(language.code)&filter=onnx",
            ]
        case .translation:
            return [
                "search=chindamt&filter=mlx",
                "search=typhoon-translate&filter=mlx",
                "search=Qwen2.5-7B-Instruct&filter=mlx",
                "search=Qwen2.5-3B-Instruct&filter=mlx",
                "search=Qwen3-4B-Instruct&filter=mlx",
                "search=Qwen3-8B&filter=mlx",
            ]
        case .notes:
            return [
                "search=typhoon&filter=mlx&limit=100",
                "search=Qwen2.5-7B-Instruct&filter=mlx",
                "search=Qwen3-4B-Instruct&filter=mlx",
            ]
        }
    }
}

extension ModelTask: Codable {
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let task = ModelTask(rawValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown task \(text)"))
        }
        self = task
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Where the model runs. Shown on each row so the user can see what hardware it uses.
enum ModelRuntime: String, Codable, Sendable {
    /// sherpa-onnx cache-aware streaming transducer, ONNX Runtime on the CPU.
    case sherpaStreaming
    /// FluidAudio Nemotron streaming, Core ML on the Neural Engine.
    case coreMLNemotron
    /// mlx-lm text model, Metal on the GPU.
    case mlx

    var accelerator: String {
        switch self {
        case .sherpaStreaming: return "CPU · ONNX Runtime"
        case .coreMLNemotron: return "Neural Engine · Core ML"
        case .mlx: return "GPU · Metal (MLX)"
        }
    }
}

struct HubFile: Codable, Hashable, Sendable {
    var path: String
    var size: Int64?
    /// LFS files carry a sha256 on the Hub. Small git files do not; their size is checked.
    var sha256: String?
}

struct HubSibling: Equatable, Sendable {
    var path: String
    var size: Int64?
    var sha256: String?
}

/// A Hub repo this app can run for one task, with the exact files to fetch.
struct HubCandidate: Identifiable, Codable, Hashable, Sendable {
    var repo: String
    var task: ModelTask
    var runtime: ModelRuntime
    var files: [HubFile]
    var downloads: Int
    var likes: Int
    var license: String?
    /// Mel bins the sherpa front end must produce. NeMo 0.6B graphs use 128, Zipformer 80.
    var featureDim: Int
    /// Subfolder that holds the model (Core ML chunk folder), or empty for the root.
    var modelSubfolder: String
    /// Translation models: true when it translates between many languages, false for Thai ⇄ English only.
    var multilingual: Bool? = nil

    /// Whether this translator can serve a direction.
    func translates(_ direction: TranslationDirection) -> Bool {
        multilingual == true || direction.isThaiEnglish
    }

    var id: String { "\(task.rawValue):\(repo)" }

    var totalBytes: Int64 {
        files.compactMap(\.size).reduce(0, +)
    }

    var sizeKnown: Bool {
        files.allSatisfy { $0.size != nil }
    }
}

enum HubCompatibility {
    /// The Core ML chunk this app streams with. 1120 ms is Nemotron's trained chunk.
    static let coreMLChunkFolder = "nemotron_coreml_1120ms"

    static func candidate(
        task: ModelTask,
        repo: String,
        siblings: [HubSibling],
        tags: [String],
        libraryName: String?,
        pipelineTag: String?,
        downloads: Int,
        likes: Int
    ) -> HubCandidate? {
        let lowerTags = Set(tags.map { $0.lowercased() })
        let license = lowerTags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
        func make(_ runtime: ModelRuntime, _ files: [HubSibling], featureDim: Int = 0, subfolder: String = "") -> HubCandidate {
            HubCandidate(
                repo: repo,
                task: task,
                runtime: runtime,
                files: files.map { HubFile(path: $0.path, size: $0.size, sha256: $0.sha256) },
                downloads: downloads,
                likes: likes,
                license: license,
                featureDim: featureDim,
                modelSubfolder: subfolder
            )
        }
        switch task {
        case .speech(let language):
            guard speaks(language, repo: repo, tags: lowerTags) else { return nil }
            if language == .english, let files = coreMLNemotronFiles(siblings) {
                return make(.coreMLNemotron, files, subfolder: coreMLChunkFolder)
            }
            guard isStreaming(repo: repo, tags: lowerTags), let files = sherpaFiles(siblings) else { return nil }
            return make(.sherpaStreaming, files, featureDim: featureDim(repo: repo))
        case .translation, .notes:
            guard isMLX(libraryName: libraryName, tags: lowerTags),
                  fitsTextTask(task, repo: repo, pipelineTag: pipelineTag),
                  let files = mlxFiles(siblings) else { return nil }
            var candidate = make(.mlx, files)
            if task == .translation {
                candidate.multilingual = isMultilingualInstruct(repo)
            }
            return candidate
        }
    }

    // MARK: Speech

    static func speaks(_ language: SpeechLanguage, repo: String, tags: Set<String>) -> Bool {
        let name = repo.split(separator: "/").last.map(String.init)?.lowercased() ?? repo.lowercased()
        let words = Set(name.split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init))
        // A Typhoon Thai checkpoint lists "en" because it keeps English words. It is not an English model.
        if language == .english && name.contains("typhoon") { return false }
        if words.contains(language.code) || language.nameHints.contains(where: name.contains) { return true }
        if language == .english {
            return tags.contains("en") && !tags.contains("th")
        }
        return tags.contains(language.code)
    }

    static func isStreaming(repo: String, tags: Set<String>) -> Bool {
        let name = repo.lowercased()
        return name.contains("streaming") || name.contains("online") || tags.contains("streaming")
    }

    static func featureDim(repo: String) -> Int {
        let name = repo.lowercased()
        if name.contains("zipformer") || name.contains("conformer-en") || name.contains("115m") { return 80 }
        if name.contains("nemotron") || name.contains("typhoon-asr-streaming-nemotron") { return 128 }
        return 80
    }

    /// sherpa-onnx online transducer: encoder, decoder, joiner, tokens.txt at the repo root.
    /// int8 graphs are preferred: a third of the memory traffic for the same streaming loop.
    static func sherpaFiles(_ siblings: [HubSibling]) -> [HubSibling]? {
        let root = siblings.filter { !$0.path.contains("/") }
        guard let tokens = root.first(where: { $0.path == "tokens.txt" }) else { return nil }
        var chosen: [HubSibling] = []
        for role in ["encoder", "decoder", "joiner"] {
            let options = root
                .filter { $0.path.hasPrefix(role) && $0.path.hasSuffix(".onnx") }
                .sorted { $0.path < $1.path }
            guard let pick = options.first(where: { $0.path.contains(".int8.") }) ?? options.first else { return nil }
            chosen.append(pick)
            // External weights sit next to the graph: encoder.onnx.data or encoder.data.
            let stem = String(pick.path.dropLast(".onnx".count))
            for data in root where data.path == pick.path + ".data" || data.path == stem + ".data" {
                chosen.append(data)
            }
        }
        chosen.append(tokens)
        return chosen
    }

    static func coreMLNemotronFiles(_ siblings: [HubSibling]) -> [HubSibling]? {
        let prefix = coreMLChunkFolder + "/"
        let files = siblings.filter { $0.path.hasPrefix(prefix) }
        let required = ["encoder/encoder_int8.mlmodelc/", "decoder.mlmodelc/", "joint.mlmodelc/", "tokenizer.json"]
        for item in required where !files.contains(where: { $0.path.hasPrefix(prefix + item) }) {
            return nil
        }
        return files
    }

    // MARK: Text

    static func isMLX(libraryName: String?, tags: Set<String>) -> Bool {
        libraryName?.lowercased() == "mlx" || tags.contains("mlx")
    }

    static func fitsTextTask(_ task: ModelTask, repo: String, pipelineTag: String?) -> Bool {
        let name = repo.lowercased()
        let excluded = ["ocr", "whisper", "asr", "vision", "-vl", "audio", "embed"]
        if excluded.contains(where: name.contains) { return false }
        if let pipelineTag, !["text-generation", "translation", "text2text-generation"].contains(pipelineTag) {
            return false
        }
        switch task {
        case .translation:
            return name.contains("chindamt") || name.contains("typhoon-translate") || isMultilingualInstruct(repo)
        case .notes:
            if isMultilingualInstruct(repo) { return true }
            guard name.contains("typhoon"), !name.contains("translate") else { return false }
            // Base checkpoints do not follow the notes prompt. Typhoon 2.1 and 2.5 ship instruct-only.
            return name.contains("instruct") || name.contains("typhoon2.1") || name.contains("typhoon2.5")
        case .speech:
            return false
        }
    }

    /// Qwen instruct checkpoints: one model that follows "Translate X to Y" for Chinese,
    /// Japanese, Korean, Vietnamese, Indonesian and the European languages.
    static func isMultilingualInstruct(_ repo: String) -> Bool {
        let parts = repo.lowercased().split(separator: "/").map(String.init)
        guard parts.count == 2 else { return false }
        let (publisher, name) = (parts[0], parts[1])
        // Conversions from the publishers that track upstream Qwen releases; fine-tunes are not translators.
        guard ["mlx-community", "lmstudio-community", "qwen"].contains(publisher) else { return false }
        // Instruct checkpoints that answer directly. Qwen3 hybrid and R1 distills spend tokens thinking first.
        let instruct = (name.hasPrefix("qwen2.5-") && name.contains("instruct"))
            || (name.hasPrefix("qwen3-") && name.contains("instruct-2507"))
        let blocked = ["coder", "math", "vl", "audio", "omni", "embedding", "reranker", "guard", "aligner",
                       "thinking", "uncensored", "abliterated", "a3b", "a22b", "14b", "30b", "32b", "72b", "235b", "0.5b", "0.6b", "1.5b"]
        return instruct && !blocked.contains(where: name.contains)
    }

    /// mlx-lm folder: config, safetensors weights, tokenizer files. Remote code is never fetched.
    static func mlxFiles(_ siblings: [HubSibling]) -> [HubSibling]? {
        let root = siblings.filter { !$0.path.contains("/") }
        let allowed = [".json", ".safetensors", ".jinja", ".model", ".tiktoken", ".txt"]
        let files = root.filter { file in
            allowed.contains { file.path.hasSuffix($0) } && file.path != "README.md"
        }
        guard files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path.hasSuffix(".safetensors") }),
              files.contains(where: { $0.path.hasPrefix("tokenizer") }) else { return nil }
        return files
    }
}
