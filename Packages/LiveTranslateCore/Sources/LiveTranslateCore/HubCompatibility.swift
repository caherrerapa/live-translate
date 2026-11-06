import Foundation

/// One job a downloadable model can do in a session. The model screen lists
/// Hugging Face repos per task, and only repos this app's runtimes can load.
enum ModelTask: String, CaseIterable, Identifiable, Codable, Sendable {
    case thaiSpeech
    case englishSpeech
    case translation
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thaiSpeech: return "Thai streaming"
        case .englishSpeech: return "English streaming"
        case .translation: return "Translation"
        case .notes: return "Notes"
        }
    }

    var subtitle: String {
        switch self {
        case .thaiSpeech: return "Streaming speech recognition for Thai."
        case .englishSpeech: return "Streaming speech recognition for English."
        case .translation: return "Thai ↔ English text translation."
        case .notes: return "Thai and English instruct model for the live meeting note."
        }
    }

    var systemImage: String {
        switch self {
        case .thaiSpeech, .englishSpeech: return "waveform"
        case .translation: return "character.bubble"
        case .notes: return "list.bullet.rectangle"
        }
    }

    var speechLanguage: SpeechLanguage? {
        switch self {
        case .thaiSpeech: return .thai
        case .englishSpeech: return .english
        case .translation, .notes: return nil
        }
    }

    static func speech(_ language: SpeechLanguage) -> ModelTask {
        language == .thai ? .thaiSpeech : .englishSpeech
    }

    /// Hub searches that surface candidates for this task. Every result still has
    /// to pass `HubCompatibility.candidate`, so a broad query cannot leak through.
    var searchQueries: [String] {
        switch self {
        case .thaiSpeech:
            return [
                "search=typhoon-asr-streaming",
                "search=sherpa-onnx-streaming&limit=100",
                "search=streaming&filter=th&filter=onnx",
            ]
        case .englishSpeech:
            return [
                "search=nemotron-speech-streaming-en",
                "search=sherpa-onnx-streaming-zipformer-en",
                "search=sherpa-onnx-streaming&limit=100",
                "search=sherpa-onnx-nemo-streaming",
            ]
        case .translation:
            return [
                "search=chindamt&filter=mlx",
                "search=typhoon-translate&filter=mlx",
            ]
        case .notes:
            return [
                "search=typhoon&filter=mlx&limit=100",
            ]
        }
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
        case .thaiSpeech, .englishSpeech:
            guard let language = task.speechLanguage,
                  speaks(language, repo: repo, tags: lowerTags) else { return nil }
            if language == .english, let files = coreMLNemotronFiles(siblings) {
                return make(.coreMLNemotron, files, subfolder: coreMLChunkFolder)
            }
            guard isStreaming(repo: repo, tags: lowerTags), let files = sherpaFiles(siblings) else { return nil }
            return make(.sherpaStreaming, files, featureDim: featureDim(repo: repo))
        case .translation, .notes:
            guard isMLX(libraryName: libraryName, tags: lowerTags),
                  fitsTextTask(task, repo: repo, pipelineTag: pipelineTag),
                  let files = mlxFiles(siblings) else { return nil }
            return make(.mlx, files)
        }
    }

    // MARK: Speech

    static func speaks(_ language: SpeechLanguage, repo: String, tags: Set<String>) -> Bool {
        let name = repo.split(separator: "/").last.map(String.init)?.lowercased() ?? repo.lowercased()
        let words = Set(name.split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init))
        switch language {
        case .thai:
            return tags.contains("th") || words.contains("th") || name.contains("thai") || name.contains("typhoon")
        case .english:
            // A Typhoon Thai checkpoint lists "en" because it keeps English words. It is not an English model.
            if name.contains("typhoon") { return false }
            return words.contains("en") || name.contains("english") || name.contains("librispeech")
                || (tags.contains("en") && !tags.contains("th"))
        }
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
            return name.contains("chindamt") || name.contains("typhoon-translate")
        case .notes:
            guard name.contains("typhoon"), !name.contains("translate") else { return false }
            // Base checkpoints do not follow the notes prompt. Typhoon 2.1 and 2.5 ship instruct-only.
            return name.contains("instruct") || name.contains("typhoon2.1") || name.contains("typhoon2.5")
        case .thaiSpeech, .englishSpeech:
            return false
        }
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
