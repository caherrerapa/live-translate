import Foundation

/// Session history on this device: one JSON file of text per session, never audio.
/// Writes happen on a utility queue so a save never stalls the UI.
final class SessionStore: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "live-translate.sessions", qos: .utility)

    init(storage: URL) {
        folder = storage.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func loadAll() -> [SessionRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    func save(_ record: SessionRecord) {
        let url = file(for: record.id)
        queue.async {
            guard let data = try? record.jsonData() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func delete(_ id: UUID) {
        let url = file(for: id)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func file(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".json")
    }
}

/// Input level for the bottom-bar waveform. Kept apart from the session so a
/// 15 Hz meter redraws only itself, not the transcript.
@MainActor
final class LevelMeter: ObservableObject {
    static let barCount = 28
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: LevelMeter.barCount)

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(level)
        levels = next
    }

    func reset() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

/// Collects RMS on the audio thread and hands one value to the main thread per frame of the meter.
final class LevelTap: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var lastSent: TimeInterval = 0
    private let send: @Sendable (Float) -> Void

    init(send: @escaping @Sendable (Float) -> Void) {
        self.send = send
    }

    func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        let rms = (energy / Float(samples.count)).squareRoot()
        // Speech sits around 0.01–0.2 RMS; a square root spreads it across the bar height.
        let level = min(1, (rms * 6).squareRoot())
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        peak = max(peak, level)
        let due = now - lastSent >= 1.0 / 15
        let value = peak
        if due {
            lastSent = now
            peak = 0
        }
        lock.unlock()
        if due { send(value) }
    }
}
