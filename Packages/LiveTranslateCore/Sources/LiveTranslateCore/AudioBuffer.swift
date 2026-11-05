import Foundation

/// 16 kHz mono samples. The buffer is memory only: capture refuses a file path,
/// and nothing here is written to disk, uploaded, or attached to a log.
struct AudioBuffer: Codable, Equatable {
    var samples: [Float]
    var sampleRate: Int

    static let captureRate = 16_000

    static func capture(samples: [Float], sampleRate: Int, filePath: String?) -> AudioBuffer? {
        if let filePath, !filePath.isEmpty {
            return nil
        }
        guard sampleRate == captureRate, !samples.isEmpty else { return nil }
        return AudioBuffer(samples: samples, sampleRate: sampleRate)
    }
}
