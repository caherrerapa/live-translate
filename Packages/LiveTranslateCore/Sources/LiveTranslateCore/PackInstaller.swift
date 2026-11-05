import Foundation

protocol ByteSource: Sendable {
    func read(maxLength: Int) async throws -> Data?
    func close()
}

struct PackFileSpec: Equatable, Sendable {
    var modelID: String
    var name: String
    var sha256: String
    var url: URL?

    var hasHash: Bool {
        !sha256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum InstallResult: Equatable {
    case installed
    case rejectedHash
    case unverified
    case blockedByListening
    case failed(String)
}

enum HuggingFaceURL {
    static func file(repo: String, name: String) -> URL? {
        URL(string: "https://huggingface.co/\(repo)/resolve/main/\(name)")
    }
}

/// Hash-gated pack install. Pause and resume keep writing the same file.
/// A bad hash deletes that file and leaves the pack uninstalled. An empty
/// catalog hash never counts as installed. Listening opens no source.
actor PackInstaller {
    let root: URL
    private let makeSource: @Sendable (URL, Int64) -> any ByteSource
    private var listening = false
    private var pauseFlag = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isParked = false

    init(root: URL, makeSource: @escaping @Sendable (URL, Int64) -> any ByteSource) {
        self.root = root
        self.makeSource = makeSource
    }

    func setListening(_ value: Bool) {
        listening = value
        if value {
            pauseFlag = false
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            isParked = false
            waiters.forEach { $0.resume() }
        }
    }

    func pause() {
        pauseFlag = true
    }

    func resume() {
        pauseFlag = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        isParked = false
        waiters.forEach { $0.resume() }
    }

    func fileURL(packID: String, modelID: String, name: String) -> URL {
        root
            .appendingPathComponent(packID, isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
            .appendingPathComponent(name)
    }

    func tombstoneURL(packID: String) -> URL {
        root.appendingPathComponent("tombstones", isDirectory: true).appendingPathComponent(packID)
    }

    func suppressAdopt(packID: String) {
        let url = tombstoneURL(packID: packID)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func allowAdopt(packID: String) {
        try? FileManager.default.removeItem(at: tombstoneURL(packID: packID))
    }

    /// Link a file this machine already produced. The hash check is `isInstalled`, once.
    func adoptIfMissing(packID: String, file: PackFileSpec, source: URL) {
        guard file.hasHash else { return }
        guard !FileManager.default.fileExists(atPath: tombstoneURL(packID: packID).path) else { return }
        let dest = fileURL(packID: packID, modelID: file.modelID, name: file.name)
        if FileManager.default.fileExists(atPath: dest.path) { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createSymbolicLink(at: dest, withDestinationURL: source)
    }

    func isInstalled(packID: String, files: [PackFileSpec]) -> Bool {
        guard !files.isEmpty, files.allSatisfy(\.hasHash) else { return false }
        for file in files {
            let url = fileURL(packID: packID, modelID: file.modelID, name: file.name)
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            guard let digest = try? Hash.sha256(file: url), digest == file.sha256.lowercased() else {
                if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    try? FileManager.default.removeItem(at: url)
                }
                return false
            }
        }
        return true
    }

    func delete(packID: String) throws {
        let directory = root.appendingPathComponent(packID, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func download(packID: String, file: PackFileSpec) async -> InstallResult {
        if listening {
            return .blockedByListening
        }
        let url = fileURL(packID: packID, modelID: file.modelID, name: file.name)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        var offset = fileSize(url)
        var source: (any ByteSource)?
        while true {
            if Task.isCancelled || listening {
                source?.close()
                return .blockedByListening
            }
            if pauseFlag {
                source?.close()
                source = nil
                await park()
                if listening || Task.isCancelled {
                    return .blockedByListening
                }
            }
            if source == nil {
                guard let remote = file.url else {
                    return .failed("missing url")
                }
                source = makeSource(remote, offset)
            }
            let chunk: Data?
            do {
                chunk = try await source?.read(maxLength: 64 * 1024)
            } catch {
                source?.close()
                return .failed(error.localizedDescription)
            }
            guard let chunk, !chunk.isEmpty else { break }
            do {
                try append(chunk, to: url)
            } catch {
                source?.close()
                return .failed(error.localizedDescription)
            }
            offset += Int64(chunk.count)
            if pauseFlag {
                source?.close()
                source = nil
                await park()
                if listening || Task.isCancelled {
                    return .blockedByListening
                }
            }
        }
        source?.close()
        return verify(url: url, expected: file.sha256)
    }

    private func park() async {
        if !pauseFlag {
            return
        }
        isParked = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !pauseFlag {
                isParked = false
                continuation.resume()
                return
            }
            pauseWaiters.append(continuation)
        }
        isParked = false
    }

    private func verify(url: URL, expected: String) -> InstallResult {
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return .unverified
        }
        guard let digest = try? Hash.sha256(file: url) else {
            try? FileManager.default.removeItem(at: url)
            return .failed("hash failed")
        }
        guard digest == trimmed else {
            try? FileManager.default.removeItem(at: url)
            return .rejectedHash
        }
        return .installed
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

final class RangeByteSource: ByteSource, @unchecked Sendable {
    let url: URL
    private var offset: Int64
    private let session: URLSession

    init(url: URL, offset: Int64, session: URLSession = .shared) {
        self.url = url
        self.offset = offset
        self.session = session
    }

    func read(maxLength: Int) async throws -> Data? {
        var request = URLRequest(url: url)
        let end = offset + Int64(maxLength) - 1
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 416 || data.isEmpty {
            return nil
        }
        if offset > 0 && http.statusCode == 200 {
            return nil
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw URLError(.badServerResponse)
        }
        offset += Int64(data.count)
        return data
    }

    func close() {}
}
