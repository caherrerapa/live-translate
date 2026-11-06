import Foundation

/// A spoken or written language. Thai and English ship in the pack; the others
/// run with a streaming model and a translator downloaded from Hugging Face.
/// Raw values are stored in saved sessions and must not change.
enum SpeechLanguage: String, Codable, Equatable, Hashable, CaseIterable, Identifiable {
    case thai
    case english
    case chinese
    case japanese
    case korean
    case vietnamese
    case indonesian
    case french
    case german
    case spanish

    var id: String { rawValue }

    /// ISO 639-1 code, as Hugging Face tags and model names use it.
    var code: String {
        switch self {
        case .thai: return "th"
        case .english: return "en"
        case .chinese: return "zh"
        case .japanese: return "ja"
        case .korean: return "ko"
        case .vietnamese: return "vi"
        case .indonesian: return "id"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        }
    }

    init?(code: String) {
        guard let match = Self.allCases.first(where: { $0.code == code.lowercased() }) else { return nil }
        self = match
    }

    var title: String {
        switch self {
        case .thai: return "Thai"
        case .english: return "English"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        case .french: return "French"
        case .german: return "German"
        case .spanish: return "Spanish"
        }
    }

    /// The language's name in its own script, for language lists.
    var nativeName: String {
        switch self {
        case .thai: return "ไทย"
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .vietnamese: return "Tiếng Việt"
        case .indonesian: return "Bahasa Indonesia"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        }
    }

    /// Two-letter label for compact controls (EN, TH, ZH…).
    var short: String { code.uppercased() }

    /// Prompt id for prompt-conditioned NeMo transducers (Nemotron, Typhoon).
    var prompt: String {
        switch self {
        case .thai: return "th-TH"
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .vietnamese: return "vi-VN"
        case .indonesian: return "id-ID"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        }
    }

    /// Scripts written without spaces between words. Their growth is counted in characters.
    var countsCharacters: Bool {
        switch self {
        case .thai, .chinese, .japanese: return true
        default: return false
        }
    }

    /// Words used in model names for this language, beside the code.
    var nameHints: [String] {
        switch self {
        case .thai: return ["thai", "typhoon"]
        case .english: return ["english", "librispeech", "gigaspeech"]
        case .chinese: return ["chinese", "mandarin", "zh-hans", "wenetspeech", "aishell"]
        case .japanese: return ["japanese", "reazonspeech"]
        case .korean: return ["korean", "zeroth"]
        case .vietnamese: return ["vietnamese"]
        case .indonesian: return ["indonesian"]
        case .french: return ["french"]
        case .german: return ["german"]
        case .spanish: return ["spanish"]
        }
    }

    /// Languages the shipping pack covers with its own speech models.
    var inPack: Bool { self == .thai || self == .english }
}

/// Which language is spoken and which one the translation is written in.
/// Stored as "th-en" style codes, so sessions saved before more languages existed still load.
struct TranslationDirection: Codable, Equatable, Hashable {
    var source: SpeechLanguage
    var target: SpeechLanguage

    init(source: SpeechLanguage, target: SpeechLanguage) {
        self.source = source
        self.target = target
    }

    static let thaiToEnglish = TranslationDirection(source: .thai, target: .english)
    static let englishToThai = TranslationDirection(source: .english, target: .thai)

    var rawValue: String { "\(source.code)-\(target.code)" }

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "-").map(String.init)
        guard parts.count == 2, let source = SpeechLanguage(code: parts[0]), let target = SpeechLanguage(code: parts[1]) else {
            return nil
        }
        self.init(source: source, target: target)
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let direction = TranslationDirection(rawValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown direction \(text)"))
        }
        self = direction
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var reversed: TranslationDirection {
        TranslationDirection(source: target, target: source)
    }

    var title: String { "\(source.title) → \(target.title)" }

    /// Thai ⇄ English is the pair the pack's ChindaMT model translates.
    var isThaiEnglish: Bool {
        Set([source, target]) == [.thai, .english]
    }
}

enum LatencyPreset: String, Codable, CaseIterable, Equatable {
    case fast
    case balanced
    case accurate

    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }
}

struct ModelCatalog: Decodable, Equatable {
    var version: Int
    var notes: String
    var hardwareProfiles: [HardwareProfile]
    var models: [SpeechModel]
    var packs: [ModelPack]

    enum CodingKeys: String, CodingKey {
        case version
        case notes
        case hardwareProfiles = "hardware_profiles"
        case models
        case packs
    }

    static func load(from url: URL) throws -> ModelCatalog {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModelCatalog.self, from: data)
    }

    static func loadFromBundle() throws -> ModelCatalog {
        guard let url = Bundle.main.url(forResource: "model-catalog", withExtension: "json") else {
            throw CatalogError.missingFile
        }
        return try load(from: url)
    }

    func pack(id: String) -> ModelPack? {
        packs.first { $0.id == id }
    }

    func model(id: String) -> SpeechModel? {
        models.first { $0.id == id }
    }
}

struct HardwareProfile: Decodable, Equatable, Identifiable {
    var id: String
    var chip: String
    var memoryGB: Int
    var storageGB: Int?
    var pack: String
    var note: String

    enum CodingKeys: String, CodingKey {
        case id
        case chip
        case memoryGB = "memory_gb"
        case storageGB = "storage_gb"
        case pack
        case note
    }
}

struct CatalogFile: Decodable, Equatable, Identifiable {
    var name: String
    var sha256: String
    var bytes: Int?
    var url: String?

    var id: String { name }

    var hasHash: Bool {
        !sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SpeechModel: Decodable, Equatable, Identifiable {
    var id: String
    var task: String
    var languages: [String]
    var title: String
    var huggingFaceRepo: String?
    var runtime: String
    var platforms: [String]
    var license: String
    var exportStatus: String
    var sizeGB: Double?
    var note: String
    var chunkMS: [Int]
    var defaultChunkMS: Int?
    var languagePrompt: String?
    var files: [CatalogFile]

    enum CodingKeys: String, CodingKey {
        case id
        case task
        case languages
        case title
        case huggingFaceRepo = "hf_repo"
        case runtime
        case platforms
        case license
        case exportStatus = "export_status"
        case sizeGB = "size_gb"
        case note
        case chunkMS = "chunk_ms"
        case defaultChunkMS = "default_chunk_ms"
        case languagePrompt = "language_prompt"
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        task = try container.decode(String.self, forKey: .task)
        languages = try container.decode([String].self, forKey: .languages)
        title = try container.decode(String.self, forKey: .title)
        huggingFaceRepo = try container.decodeIfPresent(String.self, forKey: .huggingFaceRepo)
        runtime = try container.decode(String.self, forKey: .runtime)
        platforms = try container.decode([String].self, forKey: .platforms)
        license = try container.decode(String.self, forKey: .license)
        exportStatus = try container.decode(String.self, forKey: .exportStatus)
        sizeGB = try container.decodeIfPresent(Double.self, forKey: .sizeGB)
        note = try container.decode(String.self, forKey: .note)
        chunkMS = try container.decodeIfPresent([Int].self, forKey: .chunkMS) ?? []
        defaultChunkMS = try container.decodeIfPresent(Int.self, forKey: .defaultChunkMS)
        languagePrompt = try container.decodeIfPresent(String.self, forKey: .languagePrompt)
        files = try container.decodeIfPresent([CatalogFile].self, forKey: .files) ?? []
    }
}

struct ModelPack: Decodable, Equatable, Identifiable {
    var id: String
    var title: String
    var platforms: [String]
    var directions: [String]
    var defaultPreset: String?
    var recommended: Bool
    var models: [String]
    var note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case platforms
        case directions
        case defaultPreset = "default_preset"
        case recommended
        case models
        case note
    }
}

enum CatalogError: Error {
    case missingFile
}

enum SpeechGraphs {
    /// Folder for one trained chunk. Int8 keeps its own graph and does not reuse full precision.
    static func directoryName(language: SpeechLanguage, chunkMS: Int, precision: String) -> String {
        let stem = language == .thai ? "typhoon-0.6b" : "nemotron-en"
        let name = "\(stem)-\(chunkMS)"
        return precision == "int8" ? "\(name)-int8" : name
    }

    static func existing(directories: [URL]) -> (encoder: URL, decoder: URL, joiner: URL, tokens: URL)? {
        let names = ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
        for directory in directories {
            let files = names.map { directory.appendingPathComponent($0) }
            if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                return (files[0], files[1], files[2], files[3])
            }
        }
        return nil
    }
}

enum ChunkPolicy {
    /// Acceptance map. The value has to be one of the model's trained chunks.
    /// Fast, Balanced, and Accurate select that chunk's graph.
    static func milliseconds(language: SpeechLanguage, preset: LatencyPreset, model: SpeechModel) -> Int? {
        let chosen: Int
        switch (language, preset) {
        case (.thai, .fast): chosen = 80
        case (.thai, .balanced): chosen = 480
        case (.thai, .accurate): chosen = 1040
        case (.english, .fast): chosen = 80
        case (.english, .balanced): chosen = 320
        case (.english, .accurate): chosen = 1120
        default:
            // Languages outside the pack stream with the downloaded model's own chunk.
            guard let fallback = model.defaultChunkMS ?? model.chunkMS.last else { return nil }
            chosen = fallback
        }
        guard model.chunkMS.contains(chosen) else { return nil }
        return chosen
    }

    static func preset(named: String?) -> LatencyPreset {
        LatencyPreset(rawValue: named ?? "") ?? .accurate
    }
}

enum PackPolicy {
    static let macPackID = "mac-best"
    static let phonePackID = "iphone-17-pro-max"
    static let ngramID = "typhoon-asr-streaming-nemotron-0.6b-ngram"
    static let speakerCap = 8

    static func speechPrecision(packID: String) -> String {
        packID == macPackID ? "full" : "int8"
    }

    /// The phone pack still lists the n-gram. A missed chunk drops that file first.
    static func activeModels(pack: ModelPack, chunkMissed: Bool) -> [String] {
        guard chunkMissed, pack.id == phonePackID else { return pack.models }
        return pack.models.filter { $0 != ngramID }
    }

    static func translatorID(pack: ModelPack, catalog: ModelCatalog) -> String? {
        pack.models.first { catalog.model(id: $0)?.task == "mt" }
    }

    static func notesID(pack: ModelPack, catalog: ModelCatalog) -> String? {
        pack.models.first { catalog.model(id: $0)?.task == "notes" }
    }

    static func speechID(pack: ModelPack, catalog: ModelCatalog, language: SpeechLanguage) -> String? {
        pack.models.first { id in
            guard let model = catalog.model(id: id), model.task == "asr" else { return false }
            return model.languages.contains(language.code)
        }
    }

    static func packs(on platform: String, catalog: ModelCatalog) -> [ModelPack] {
        catalog.packs.filter { $0.platforms.contains(platform) }
    }
}

enum TranslatorChoice {
    /// Section 8 Accurate lag, measured after the prefix commits.
    static let accurateLagSeconds = 2.0
    static let macDefaultID = "chindamt-4b-8bit"
    static let macCeilingID = "chindamt-4b-bf16"

    /// bf16 replaces 8-bit only when a growing-turn timing lands inside the Accurate lag.
    static func macModelID(bf16LagSeconds: Double?) -> String {
        if let lag = bf16LagSeconds, lag >= 0, lag < accurateLagSeconds {
            return macCeilingID
        }
        return macDefaultID
    }
}

enum TranslationPrompt {
    /// "Translate English to Thai.\n\nEN: …" is the instruction style ChindaMT was trained on;
    /// multilingual instruct models follow the same shape for any pair.
    static func text(source: String, direction: TranslationDirection) -> String {
        "Translate \(direction.source.title) to \(direction.target.title).\n\n\(direction.source.short): \(source)"
    }
}
