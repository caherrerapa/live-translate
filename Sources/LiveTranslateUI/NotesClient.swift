#if os(macOS)
import Foundation

/// Typhoon 2 notes. One local process, text in and text out. The production
/// pass in `NotesProductionPass` decides what is stored.
final class TyphoonNotesClient: @unchecked Sendable {
    /// Set on the main thread, read by a notes pass in the background.
    var packID: String {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return pack }
        set { overrideLock.lock(); pack = newValue; overrideLock.unlock() }
    }
    private var pack = PackPolicy.macPackID
    /// A notes model picked from Hugging Face. Nil uses the pack's model.
    var modelOverride: URL? {
        get { overrideLock.lock(); defer { overrideLock.unlock() }; return override }
        set { overrideLock.lock(); override = newValue; overrideLock.unlock() }
    }
    /// Separate from `lock`, which a notes pass holds for seconds. The main thread only touches this one.
    private let overrideLock = NSLock()
    private var override: URL?
    /// The live process, readable without `lock` so quitting never waits on a running pass.
    private var liveProcess: Process?
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
        let budget = Self.replyBudget(for: noteInput.note)
        let body: [String: Any] = ["id": 1, "prompt": prompt, "max_tokens": budget]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return empty }
        var line = data
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            return empty
        }
        // A hung model would hold `lock` forever and starve every later pass.
        // At ~10 tokens a second on a busy GPU, the largest reply needs a few minutes.
        guard let reply = readLine(timeout: max(180, Double(budget) / 8)),
              let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let text = object["text"] as? String else {
            return empty
        }
        return NotesProductionPass.draft(parsing: text, fallbackTurnID: noteInput.turns.last?.id ?? "")
    }

    /// Each pass repeats the whole note and adds to it, so a long meeting's reply outgrows a fixed
    /// budget and would be cut off mid-JSON, freezing the note. The budget follows the note's size:
    /// about one token per 2.5 characters (Thai runs denser than English), plus room for new items.
    static func replyBudget(for note: MeetingNote) -> Int {
        let items = [note.title] + note.summary + note.decisions + note.actions + note.openQuestions
        let characters = items.reduce(0) { $0 + $1.text.count + $1.turnID.count + 24 }
        return min(2048, max(480, Int(Double(characters) / 2.5) + 320))
    }

    /// Free-form text from the notes model, for Ask on this Mac. Shares the process with notes passes.
    func complete(_ prompt: String, maxTokens: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard startIfNeeded() else { return "" }
        let body: [String: Any] = ["id": 2, "prompt": prompt, "max_tokens": maxTokens]
        guard var line = try? JSONSerialization.data(withJSONObject: body) else { return "" }
        line.append(0x0A)
        do {
            try input?.write(contentsOf: line)
        } catch {
            return ""
        }
        guard let reply = readLine(timeout: max(120, Double(maxTokens) / 4)),
              let object = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let text = object["text"] as? String else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ends the process at once. Called on quit: a pass holding `lock` reads EOF and returns.
    func terminateNow() {
        overrideLock.lock()
        let process = liveProcess
        liveProcess = nil
        overrideLock.unlock()
        process?.terminate()
    }

    /// Loads the notes model before the first pass needs it, so a pass in the middle
    /// of a session does not page gigabytes in. Call off the main thread.
    func prewarm() {
        lock.lock()
        defer { lock.unlock() }
        _ = startIfNeeded()
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
        // Notes may lag; speech, translation and the UI may not. Its CPU and disk I/O yield to them.
        process.qualityOfService = .utility
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let log = HelperLog(name: "notes")
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            log.append(data)
        }
        do {
            try process.run()
        } catch {
            return false
        }
        self.process = process
        overrideLock.lock()
        liveProcess = process
        overrideLock.unlock()
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        leftover.removeAll()
        // Loading 7B weights from a cold disk is slow, but not this slow.
        guard let line = readLine(timeout: 300),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["ready"] as? Bool == true else {
            process.terminate()
            self.process = nil
            return false
        }
        return true
    }

    /// Reads one reply line. If none arrives within `timeout`, the process is ended,
    /// which closes its output and returns nil here.
    private func readLine(timeout: TimeInterval) -> String? {
        let watchdog = DispatchWorkItem { [process] in process?.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
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
