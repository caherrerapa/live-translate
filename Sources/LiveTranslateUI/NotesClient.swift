#if os(macOS)
import Foundation

/// Typhoon 2 notes. One local process, text in and text out. The production
/// pass in `NotesProductionPass` decides what is stored.
final class TyphoonNotesClient: @unchecked Sendable {
    var packID = PackPolicy.macPackID
    /// A notes model picked from Hugging Face. Nil uses the pack's model.
    var modelOverride: URL? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return override }
        set { overrideLock.lock(); override = newValue; overrideLock.unlock() }
    }
    /// Separate from `lock`, which a notes pass holds for seconds. The main thread only touches this one.
    private let overrideLock = NSLock()
    private var override: URL?
    private var runningModel: URL?
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var leftover = Data()

    func draft(for noteInput: NotesInput) -> NotesDraft {
        let empty = NotesDraft(title: "", titleTurnID: "", summary: [], decisions: [], actions: [], openQuestions: [])
        lock.lock()
        defer { lock.unlock() }
        guard startIfNeeded() else { return empty }
        let prompt = NotesProductionPass.prompt(for: noteInput)
        let body: [String: Any] = ["id": 1, "prompt": prompt, "max_tokens": 480]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return empty }
        var line = data
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            return empty
        }
        guard let reply = readLine(),
              let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let text = object["text"] as? String else {
            return empty
        }
        return NotesProductionPass.draft(parsing: text, fallbackTurnID: noteInput.turns.last?.id ?? "")
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let input {
            try? input.write(contentsOf: Data("{\"cmd\":\"stop\"}\n".utf8))
        }
        process?.terminate()
        process = nil
        input = nil
        output = nil
        leftover.removeAll()
    }

    private func startIfNeeded() -> Bool {
        let wanted = modelOverride ?? OnDevicePaths.notesDirectory(packID: packID)
        if let process, process.isRunning, runningModel == wanted { return true }
        if let process {
            process.terminate()
            self.process = nil
        }
        guard let python = OnDevicePaths.python(),
              let script = OnDevicePaths.chindaScript(),
              let model = wanted else {
            return false
        }
        runningModel = model
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
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        leftover.removeAll()
        guard let line = readLine(),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["ready"] as? Bool == true else {
            process.terminate()
            self.process = nil
            return false
        }
        return true
    }

    private func readLine() -> String? {
        while true {
            if let newline = leftover.firstIndex(of: 0x0A) {
                let chunk = leftover[..<newline]
                leftover.removeSubrange(...newline)
                return String(data: Data(chunk), encoding: .utf8)
            }
            let chunk = output?.availableData ?? Data()
            if chunk.isEmpty { return nil }
            leftover.append(chunk)
        }
    }
}
#endif
