import Foundation

/// Hugging Face models the user picked for one task. Search, download, verify,
/// select. This and `PackInstaller` are the only code that opens a network
/// connection, and neither runs while Listen is on.
@MainActor
final class ModelLibrary: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case downloading(fraction: Double, bytes: Int64)
        case paused(bytes: Int64)
        case verifying
        case installed
        case failed(String)
    }

    @Published private(set) var results: [ModelTask: [HubCandidate]] = [:]
    @Published private(set) var searching: Set<ModelTask> = []
    @Published private(set) var searchErrors: [ModelTask: String] = [:]
    @Published private(set) var installed: [HubCandidate] = []
    @Published private(set) var status: [String: Status] = [:]
    @Published private(set) var selection: [ModelTask: String] = [:]
    /// Set by the session. Downloads refuse to start while it is true.
    var listening = false
    /// Called after an install so the session can check the runtime opens it.
    var verifyInstall: ((HubCandidate, URL) async -> String?)?

    private let root: URL
    private var transfers: [String: HubTransfer] = [:]
    private var resumeData: [String: (file: Int, data: Data)] = [:]
    private static let selectionKey = "modelSelection"

    init(storage: URL) {
        root = storage.appendingPathComponent("hub", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let saved = UserDefaults.standard.dictionary(forKey: Self.selectionKey) as? [String: String] {
            for (key, value) in saved {
                if let task = ModelTask(rawValue: key) { selection[task] = value }
            }
        }
        loadInstalled()
    }

    // MARK: Selection

    /// Nil means the pack's built-in model for that task.
    func selected(_ task: ModelTask) -> HubCandidate? {
        guard let repo = selection[task] else { return nil }
        return installed.first { $0.task == task && $0.repo == repo }
    }

    func select(_ candidate: HubCandidate?, for task: ModelTask) {
        selection[task] = candidate?.repo
        var saved: [String: String] = [:]
        for (key, value) in selection { saved[key.rawValue] = value }
        UserDefaults.standard.set(saved, forKey: Self.selectionKey)
    }

    func directory(for candidate: HubCandidate) -> URL {
        let slug = candidate.task.rawValue + "__" + candidate.repo.replacingOccurrences(of: "/", with: "__")
        return root.appendingPathComponent(slug, isDirectory: true)
    }

    /// Folder the runtime opens: the repo folder, or its Core ML chunk subfolder.
    func modelDirectory(for candidate: HubCandidate) -> URL {
        let base = directory(for: candidate)
        return candidate.modelSubfolder.isEmpty ? base : base.appendingPathComponent(candidate.modelSubfolder, isDirectory: true)
    }

    func status(of candidate: HubCandidate) -> Status {
        if let current = status[candidate.id] { return current }
        return installed.contains(candidate) ? .installed : .notInstalled
    }

    // MARK: Search

    func search(_ task: ModelTask) async {
        guard !searching.contains(task) else { return }
        searching.insert(task)
        searchErrors[task] = nil
        defer { searching.remove(task) }
        do {
            var repos: [String: HubListing] = [:]
            for query in task.searchQueries {
                for listing in try await HubAPI.list(query: query) where repos[listing.id] == nil {
                    repos[listing.id] = listing
                }
            }
            // Cheap name filter first, then one detail call per survivor for file sizes and hashes.
            // Repos that name a runtime this app has come first; mirrors in other formats are already gone.
            let shortlist = repos.values
                .filter { HubCompatibility.prefilter(task: task, listing: $0) }
                .sorted {
                    let left = HubCompatibility.runtimeHint($0.id), right = HubCompatibility.runtimeHint($1.id)
                    return left != right ? left > right : $0.downloads > $1.downloads
                }
                .prefix(48)
            var found: [HubCandidate] = []
            var queue = Array(shortlist)
            // At most eight Hub calls at once.
            await withTaskGroup(of: HubCandidate?.self) { group in
                func addNext() {
                    guard !queue.isEmpty else { return }
                    let listing = queue.removeFirst()
                    group.addTask { await Self.evaluate(task: task, listing: listing) }
                }
                for _ in 0..<8 { addNext() }
                for await candidate in group {
                    if let candidate {
                        found.append(candidate)
                        // Rows appear as each repo passes, not after the whole search.
                        results[task] = Self.ranked(found)
                    }
                    addNext()
                }
            }
            results[task] = Self.ranked(found)
            if found.isEmpty && repos.isEmpty {
                searchErrors[task] = "Hugging Face returned no models."
            }
        } catch {
            searchErrors[task] = "Could not reach Hugging Face. \(error.localizedDescription)"
        }
    }

    /// Neural Engine builds first (least CPU), then the most downloaded.
    nonisolated private static func ranked(_ candidates: [HubCandidate]) -> [HubCandidate] {
        candidates.sorted {
            if $0.runtime != $1.runtime { return $0.runtime == .coreMLNemotron }
            return $0.downloads > $1.downloads
        }
    }

    nonisolated private static func evaluate(task: ModelTask, listing: HubListing) async -> HubCandidate? {
        guard let detail = try? await HubAPI.detail(repo: listing.id) else { return nil }
        guard var candidate = HubCompatibility.candidate(
            task: task,
            repo: listing.id,
            siblings: detail.siblings,
            tags: detail.tags,
            libraryName: detail.libraryName,
            pipelineTag: detail.pipelineTag,
            downloads: listing.downloads,
            likes: listing.likes
        ) else { return nil }
        if candidate.runtime == .sherpaStreaming {
            // sherpa-onnx reads its settings from the encoder's metadata and exits the
            // process when they are missing. Read the graph's tail before listing it.
            guard let encoder = candidate.files.first?.path,
                  let tail = try? await HubAPI.tail(repo: listing.id, path: encoder),
                  let metadata = SherpaMetadata(tail: tail) else { return nil }
            candidate.featureDim = metadata.featureDim
        }
        return candidate
    }

    // MARK: Download

    func download(_ candidate: HubCandidate) {
        guard !listening else {
            status[candidate.id] = .failed("Downloads wait until Listen stops.")
            return
        }
        if case .downloading = status(of: candidate) { return }
        Task { await run(candidate) }
    }

    func pause(_ candidate: HubCandidate) {
        transfers[candidate.id]?.pause()
    }

    func delete(_ candidate: HubCandidate) {
        transfers[candidate.id]?.cancel()
        try? FileManager.default.removeItem(at: directory(for: candidate))
        try? FileManager.default.removeItem(at: partialDirectory(for: candidate))
        resumeData[candidate.id] = nil
        status[candidate.id] = nil
        installed.removeAll { $0 == candidate }
        if selection[candidate.task] == candidate.repo {
            select(nil, for: candidate.task)
        }
    }

    private func partialDirectory(for candidate: HubCandidate) -> URL {
        root.appendingPathComponent(".partial", isDirectory: true)
            .appendingPathComponent(directory(for: candidate).lastPathComponent, isDirectory: true)
    }

    private func run(_ candidate: HubCandidate) async {
        let partial = partialDirectory(for: candidate)
        try? FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        let total = max(candidate.totalBytes, 1)
        var done: Int64 = 0
        let transfer = HubTransfer()
        transfers[candidate.id] = transfer
        defer { transfers[candidate.id] = nil }
        status[candidate.id] = .downloading(fraction: 0, bytes: 0)

        for (index, file) in candidate.files.enumerated() {
            let destination = partial.appendingPathComponent(file.path)
            // A file that is already whole from an earlier attempt is not fetched again.
            if let size = file.size, Self.size(of: destination) == size {
                done += size
                continue
            }
            if listening {
                status[candidate.id] = .paused(bytes: done)
                return
            }
            guard let url = HubAPI.resolveURL(repo: candidate.repo, path: file.path) else {
                status[candidate.id] = .failed("Bad file path \(file.path).")
                return
            }
            let resume = resumeData[candidate.id].flatMap { $0.file == index ? $0.data : nil }
            resumeData[candidate.id] = nil
            let base = done
            let outcome = await transfer.fetch(url: url, to: destination, resumeData: resume) { [weak self] written in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.status[candidate.id] ?? .notInstalled {
                        let bytes = base + written
                        self.status[candidate.id] = .downloading(fraction: Double(bytes) / Double(total), bytes: bytes)
                    }
                }
            }
            switch outcome {
            case .finished:
                done += file.size ?? Self.size(of: destination)
            case .paused(let data):
                if let data { resumeData[candidate.id] = (index, data) }
                status[candidate.id] = .paused(bytes: done)
                return
            case .cancelled:
                status[candidate.id] = nil
                return
            case .failed(let message):
                status[candidate.id] = .failed(message)
                return
            }
        }

        status[candidate.id] = .verifying
        let files = candidate.files
        let problem = await Task.detached(priority: .utility) {
            Self.verify(files: files, in: partial)
        }.value
        if let problem {
            // A bad hash is deleted and offered again.
            try? FileManager.default.removeItem(at: partial)
            status[candidate.id] = .failed(problem)
            return
        }
        let final = directory(for: candidate)
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: partial, to: final)
            let manifest = try JSONEncoder().encode(candidate)
            try manifest.write(to: final.appendingPathComponent(".manifest.json"))
        } catch {
            status[candidate.id] = .failed("Could not install: \(error.localizedDescription)")
            return
        }
        if let verifyInstall, let reason = await verifyInstall(candidate, modelDirectory(for: candidate)) {
            try? FileManager.default.removeItem(at: final)
            status[candidate.id] = .failed("Downloaded, but the runtime cannot open it: \(reason)")
            return
        }
        installed.removeAll { $0 == candidate }
        installed.append(candidate)
        status[candidate.id] = .installed
        if selection[candidate.task] == nil {
            select(candidate, for: candidate.task)
        }
    }

    nonisolated private static func verify(files: [HubFile], in folder: URL) -> String? {
        for file in files {
            let url = folder.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return "\(file.path) is missing." }
            if let size = file.size, size != Self.size(of: url) {
                return "\(file.path) has the wrong size."
            }
            if let expected = file.sha256 {
                guard let actual = try? Hash.sha256(file: url), actual == expected else {
                    return "\(file.path) failed the sha256 check."
                }
            }
        }
        return nil
    }

    nonisolated private static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private func loadInstalled() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(".manifest.json")) else { return nil }
            return try? JSONDecoder().decode(HubCandidate.self, from: data)
        }
    }
}

// MARK: Hub API

struct HubListing: Decodable, Sendable {
    var id: String
    var downloads: Int
    var likes: Int
    var tags: [String]
    var libraryName: String?
    var pipelineTag: String?

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags
        case libraryName = "library_name"
        case pipelineTag = "pipeline_tag"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        downloads = try container.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        likes = try container.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
        pipelineTag = try container.decodeIfPresent(String.self, forKey: .pipelineTag)
    }
}

struct HubDetail: Sendable {
    var siblings: [HubSibling]
    var tags: [String]
    var libraryName: String?
    var pipelineTag: String?
}

enum HubAPI {
    static let host = "https://huggingface.co"

    static func list(query: String) async throws -> [HubListing] {
        var text = query
        if !text.contains("limit=") { text += "&limit=50" }
        guard let url = URL(string: "\(host)/api/models?\(text)&sort=downloads") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([HubListing].self, from: data)
    }

    static func detail(repo: String) async throws -> HubDetail {
        guard let url = URL(string: "\(host)/api/models/\(repo)?blobs=true") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let siblings = (object["siblings"] as? [[String: Any]] ?? []).compactMap { entry -> HubSibling? in
            guard let path = entry["rfilename"] as? String else { return nil }
            let lfs = entry["lfs"] as? [String: Any]
            let size = (entry["size"] as? NSNumber)?.int64Value ?? (lfs?["size"] as? NSNumber)?.int64Value
            return HubSibling(path: path, size: size, sha256: lfs?["sha256"] as? String)
        }
        return HubDetail(
            siblings: siblings,
            tags: object["tags"] as? [String] ?? [],
            libraryName: object["library_name"] as? String,
            pipelineTag: object["pipeline_tag"] as? String
        )
    }

    /// The last bytes of a file. ONNX writes model metadata after the graph.
    static func tail(repo: String, path: String, bytes: Int = 262_144) async throws -> Data {
        guard let url = resolveURL(repo: repo, path: path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("bytes=-\(bytes)", forHTTPHeaderField: "Range")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    static func resolveURL(repo: String, path: String) -> URL? {
        let escaped = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "\(host)/\(repo)/resolve/main/\(escaped)")
    }
}

extension HubCompatibility {
    /// 2 for a repo that names a runtime this app has, else 0.
    static func runtimeHint(_ repo: String) -> Int {
        let name = repo.lowercased()
        return name.contains("sherpa-onnx") || name.contains("coreml") || name.contains("mlx") ? 2 : 0
    }

    /// Name-level filter before a detail call. The file check in `candidate` is the real gate.
    static func prefilter(task: ModelTask, listing: HubListing) -> Bool {
        let tags = Set(listing.tags.map { $0.lowercased() })
        switch task {
        case .thaiSpeech, .englishSpeech:
            guard let language = task.speechLanguage else { return false }
            let name = listing.id.lowercased()
            // Formats no runtime here can load, and decoder types the transducer loop does not run.
            let foreign = ["gguf", "mlx", "litert", "webgpu", "tflite", "ctc", "paraformer", "non-streaming", "whisper"]
            if foreign.contains(where: name.contains) { return false }
            let coreML = name.contains("coreml") && language == .english
            return speaks(language, repo: listing.id, tags: tags)
                && (coreML || isStreaming(repo: listing.id, tags: tags))
        case .translation, .notes:
            return isMLX(libraryName: listing.libraryName, tags: tags)
                && fitsTextTask(task, repo: listing.id, pipelineTag: listing.pipelineTag)
        }
    }
}

// MARK: Transfer

/// One resumable file download with progress. Pausing keeps the resume data.
final class HubTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Outcome {
        case finished
        case paused(Data?)
        case cancelled
        case failed(String)
    }

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var progress: ((Int64) -> Void)?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var moveError: String?
    private var pausing = false
    private var cancelling = false

    func fetch(url: URL, to destination: URL, resumeData: Data?, progress: @escaping (Int64) -> Void) async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.destination = destination
            self.progress = progress
            self.moveError = nil
            self.pausing = false
            self.cancelling = false
            let session = self.session ?? URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func pause() {
        lock.lock()
        pausing = true
        let task = self.task
        lock.unlock()
        task?.cancel(byProducingResumeData: { _ in })
    }

    func cancel() {
        lock.lock()
        cancelling = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let progress = self.progress
        lock.unlock()
        progress?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let destination = self.destination
        lock.unlock()
        guard let destination else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.lock()
            moveError = "Hugging Face answered \(http.statusCode)."
            lock.unlock()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock()
            moveError = error.localizedDescription
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let pausing = self.pausing
        let cancelling = self.cancelling
        let moveError = self.moveError
        lock.unlock()
        guard let continuation else { return }
        if let error {
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if pausing {
                continuation.resume(returning: .paused(resume))
            } else if cancelling {
                continuation.resume(returning: .cancelled)
            } else {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
            return
        }
        if let moveError {
            continuation.resume(returning: .failed(moveError))
        } else {
            continuation.resume(returning: .finished)
        }
    }
}

// MARK: MLX check

enum MLXSupport {
    /// Nil when the bundled mlx-lm has an architecture for this folder's `model_type`.
    static func check(directory: URL) -> String? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelType = config["model_type"] as? String else {
            return "config.json has no model_type."
        }
        #if os(macOS)
        guard let resources = Bundle.main.resourceURL else { return nil }
        let lib = resources.appendingPathComponent("mlx-runtime/lib")
        let pythons = (try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []
        // A build without the runtime cannot judge; the translator reports that on start.
        guard let python = pythons.first(where: { $0.hasPrefix("python3") }) else { return nil }
        let models = lib.appendingPathComponent(python).appendingPathComponent("site-packages/mlx_lm/models")
        let file = models.appendingPathComponent(modelType.replacingOccurrences(of: "-", with: "_") + ".py")
        return FileManager.default.fileExists(atPath: file.path) ? nil : "mlx-lm has no \(modelType) architecture."
        #else
        return "MLX text models run on the Mac build."
        #endif
    }
}

/// What sherpa-onnx needs from a streaming encoder's ONNX metadata.
struct SherpaMetadata {
    var featureDim: Int

    /// NeMo graphs carry vocab_size and window_size; Zipformer graphs carry encoder_dims.
    init?(tail: Data) {
        func has(_ key: String) -> Bool { tail.range(of: Data(key.utf8)) != nil }
        let nemo = has("vocab_size") && has("window_size")
        let zipformer = has("encoder_dims") || (has("model_type") && has("decode_chunk_len"))
        guard nemo || zipformer else { return nil }
        featureDim = nemo ? (Self.value(of: "feat_dim", in: tail).flatMap(Int.init) ?? 80) : 80
    }

    /// Reads a metadata_props value: key bytes, then field 2 (0x12), a length byte, the text.
    static func value(of key: String, in data: Data) -> String? {
        guard let range = data.range(of: Data(key.utf8)) else { return nil }
        var index = range.upperBound
        let bytes = [UInt8](data[index..<min(data.endIndex, index + 32)])
        index = 0
        while index + 1 < bytes.count, bytes[index] != 0x12 { index += 1 }
        guard index + 1 < bytes.count else { return nil }
        let length = Int(bytes[index + 1])
        let start = index + 2
        guard start + length <= bytes.count else { return nil }
        return String(bytes: bytes[start..<start + length], encoding: .utf8)
    }
}
