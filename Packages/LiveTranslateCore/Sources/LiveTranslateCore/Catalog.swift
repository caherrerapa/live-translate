import Foundation

enum SpeechLanguage: String, Codable, Equatable {
    case thai
    case english

    var prompt: String {
        switch self {
        case .thai: return "th-TH"
        case .english: return "en-US"
        }
    }
}

enum TranslationDirection: String, Codable, Equatable {
    case thaiToEnglish = "th-en"
    case englishToThai = "en-th"

    var source: SpeechLanguage {
        self == .thaiToEnglish ? .thai : .english
    }

    var target: SpeechLanguage {
        self == .thaiToEnglish ? .english : .thai
    }

    var title: String {
        switch self {
        case .thaiToEnglish: return "Thai → English"
        case .englishToThai: return "English → Thai"
        }
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

enum ChunkPolicy {
    /// Acceptance map. The value has to be one of the model's trained chunks.
    /// Fast, Balanced, and Accurate change this number only. They do not change the file.
    static func milliseconds(language: SpeechLanguage, preset: LatencyPreset, model: SpeechModel) -> Int? {
        let chosen: Int
        switch (language, preset) {
        case (.thai, .fast): chosen = 80
        case (.thai, .balanced): chosen = 480
        case (.thai, .accurate): chosen = 1040
        case (.english, .fast): chosen = 80
        case (.english, .balanced): chosen = 320
        case (.english, .accurate): chosen = 1120
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
            return model.languages.contains(language == .thai ? "th" : "en")
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
    static func text(source: String, direction: TranslationDirection) -> String {
        switch direction {
        case .englishToThai:
            return "Translate English to Thai.\n\nEN: \(source)"
        case .thaiToEnglish:
            return "Translate Thai to English.\n\nTH: \(source)"
        }
    }
}
