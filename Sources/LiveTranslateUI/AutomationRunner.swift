#if os(macOS) && DEBUG
import AppKit
import AVFoundation
import SwiftUI

/// Debug-only stand-in for the microphone: plays a recording into the session at
/// real-time speed, so the running app can be checked without someone talking.
final class FileCapture: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private var running = false
    private let lock = NSLock()

    init(url: URL) { self.url = url }

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        let samples = try Self.read(url)
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in
            let hop = 320
            let tail = [Float]()  // Stop arrives right after the last word; the drain must recover it.
            let all = samples + tail
            var offset = 0
            let start = Date()
            while offset < all.count {
                guard let self else { return }
                self.lock.lock(); let on = self.running; self.lock.unlock()
                guard on else { return }
                let end = min(offset + hop, all.count)
                onSamples(Array(all[offset..<end]))
                offset = end
                let wait = start.addingTimeInterval(Double(offset) / 16_000).timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
        }
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw CaptureError.formatUnavailable
        }
        try file.read(into: buffer)
        return MicrophoneCapture.convert(buffer, converter: converter, target: target) ?? []
    }

    static func duration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

/// `LT_AUTOMATION=<report folder>` runs the spec's Mac acceptance checks in the
/// live window and writes report.json plus window snapshots there.
@MainActor
enum AutomationRunner {
    private static var results: [[String: Any]] = []
    private static var folder = URL(fileURLWithPath: NSTemporaryDirectory())

    static func startIfRequested(_ controller: SessionController) {
        guard let path = ProcessInfo.processInfo.environment["LT_AUTOMATION"], !path.isEmpty else { return }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { await run(controller) }
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: Any = "") {
        results.append(["check": name, "passed": passed, "detail": detail])
        print("AUTOMATION \(passed ? "PASS" : "FAIL") \(name) \(detail)")
        write()
    }

    private static func write() {
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent("report.json"))
        }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await sleep(0.25)
        }
        return condition()
    }

    private static var speechReady: Bool {
        if case .ready = SessionControllerProbe.speech { return true }
        return false
    }

    static func snapshot(_ name: String) {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
        // The content view renders every SwiftUI layer; the frame view adds the traffic lights.
        for (view, suffix) in [(window.contentView, ""), (window.contentView?.superview, "-frame")] {
            guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)\(suffix).png"))
        }
    }

    /// Feeds one recording through Listen and returns the turns the window shows.
    private static func listen(_ controller: SessionController, file: URL, direction: TranslationDirection, label: String) async -> [SessionTurn] {
        controller.setDirection(direction)
        SessionControllerProbe.controller = controller
        // Ready means the graph for this language, not the one still loaded from the last direction.
        let expected = direction.source == .thai ? "Typhoon" : "EN"
        let ready = await waitUntil(120) {
            if case .ready(let name) = controller.speechStatus { return name.contains(expected) }
            return false
        }
        check("\(label): speech model loads off the main thread", ready, "\(controller.speechStatus)")
        controller.automationFeed = file
        print("AUTOMATION MARK \(label)-listen")
        fflush(stdout)
        let tick = Date()
        controller.listenOrStop()
        let started = await waitUntil(10) { controller.engine.listening }
        check("\(label): Listen starts", started, "after \(String(format: "%.2f", Date().timeIntervalSince(tick))) s")
        // The main thread must stay responsive while decoding. A main-queue timer
        // fires every 20 ms; any lateness is time the main thread was blocked.
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        let end = Date().addingTimeInterval(FileCapture.duration(file) + 0.3)
        var firstText: TimeInterval?
        while Date() < end {
            await sleep(0.1)
            if firstText == nil, controller.engine.turns.contains(where: { !$0.sourceDisplay.isEmpty }) {
                firstText = Date().timeIntervalSince(tick)
            }
        }
        let worstLag = watchdog.stop()
        let notesWindow = controller.notesActivity.map { "\(String(format: "%.1f", $0.start.timeIntervalSince(tick)))–\($0.end.map { String(format: "%.1f", $0.timeIntervalSince(tick)) } ?? "running") s" }
        let stallTimes = watchdog.stalls.map { String(format: "%.1f s (%.0f ms)", $0.0.timeIntervalSince(tick), $0.1 * 1000) }
        print("AUTOMATION stalls \(label): \(stallTimes) notes passes: \(notesWindow)")
        results.append(["check": "\(label): stall timing", "passed": true, "detail": "stalls \(stallTimes); notes model busy \(notesWindow)"])
        check("\(label): partial text appears while audio plays", firstText != nil, "first text at \(firstText.map { String(format: "%.2f s", $0) } ?? "never")")
        check("\(label): main thread stays responsive", worstLag < 0.1, String(format: "worst main-thread stall %.0f ms", worstLag * 1000))
        snapshot("\(label)-listening")
        controller.listenOrStop()
        _ = await waitUntil(30) { !controller.engine.listening && !controller.stopping }
        _ = await waitUntil(60) { controller.engine.pendingTranslation == nil && !controller.isTranslating }
        await sleep(1)
        controller.automationFeed = nil
        snapshot("\(label)-stopped")
        return controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }
    }

    private static func run(_ controller: SessionController) async {
        let root = OnDevicePaths.repoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let english = root.appendingPathComponent("spikes/fixtures/en-room.wav")
        let thai = root.appendingPathComponent("spikes/fixtures/utt0072.wav")
        // Window managers place and resize a new window for a few seconds after launch.
        await sleep(20)
        if ProcessInfo.processInfo.environment["LT_STORAGE"] != nil {
            // A previous run's delete-pack check leaves a tombstone in the throwaway storage.
            await controller.installer.allowAdopt(packID: controller.packID)
            await controller.refreshInstall()
        }
        headerHitCheck()
        let launched = Date()
        let installed = await waitUntil(180) { controller.engine.packInstalled }
        print("AUTOMATION pack check took \(Date().timeIntervalSince(launched)) s")
        check("Pack installed: panels can listen", installed, controller.packName)

        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "delete" {
            await deleteCheck(controller)
            return
        }
        if let only = ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"], only == "mic" || only == "system" {
            await liveAudioCheck(controller, source: only == "mic" ? .microphone : .systemAudio, file: english)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "window" {
            await windowCheck()
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "thai" {
            _ = await listen(controller, file: thai, direction: .thaiToEnglish, label: "thai-only")
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }

        // 1. Listen, talk, see both panels update, stop, text remains.
        let en = await listen(controller, file: english, direction: .englishToThai, label: "english")
        let enSource = en.map(\.sourceDisplay).joined(separator: " ")
        let enTranslation = en.map(\.translationCommitted).joined(separator: " ")
        check("English: full sentence recognized", enSource.contains("translation on this"), enSource)
        check("English: translation covers the whole turn (Thai text)", enTranslation.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) } && enTranslation.count > 40, enTranslation)
        check("English: text remains after Stop", !controller.engine.listening && !en.isEmpty, "\(en.count) turns")

        // Copy the detected text.
        controller.copySession(.original)
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        check("Copy original puts the detected text on the pasteboard", pasted.contains("Meeting starts"), pasted)

        // Highlight pins the current turn before the notes pass.
        controller.highlight()
        check("Highlight pins the current turn", !controller.engine.notes.note.highlights.isEmpty, controller.engine.notes.note.highlights.map(\.text))

        // 2. Swap direction, talk, the panels swap roles.
        controller.newSession()
        check("New session saves the last one to history", controller.sessions.contains { $0.turns.contains { $0.source.contains("Meeting") } }, controller.sessions.map(\.displayTitle))
        let th = await listen(controller, file: thai, direction: .thaiToEnglish, label: "thai")
        let thSource = th.map(\.sourceDisplay).joined(separator: " ")
        let thTranslation = th.map(\.translationCommitted).joined(separator: " ")
        check("Thai: Typhoon 0.6B streams Thai text", thSource.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }, thSource)
        check("Thai: translation is English", thTranslation.range(of: "[A-Za-z]{3,}", options: .regularExpression) != nil, thTranslation)

        // Rename a speaker; later turns of that voice keep the name.
        if let first = th.first(where: { $0.speakerOrdinal != nil }) {
            controller.beginRename(first.id)
            controller.renameCurrent(to: "Sarah")
            let renamed = controller.engine.turns.filter { $0.speakerOrdinal == first.speakerOrdinal }.allSatisfy { $0.speakerLabel == "Sarah" }
            check("Rename a speaker", renamed, controller.engine.turns.map(\.speakerLabel))
        } else {
            check("Rename a speaker", false, "no diarizer label on the first turn")
        }

        // Stop runs one last notes pass and leaves a note; no Generate step.
        let noted = await waitUntil(180) { !controller.notesRunning && controller.engine.notes.stopPassCount >= 1 }
        check("Stop runs one last notes pass", noted, "passes \(controller.engine.notes.passCount), title \"\(controller.engine.notes.note.title.text)\"")

        await windowCheck()

        await deleteCheck(controller)
        check("Done", true, folder.path)
        NSApp.terminate(nil)
    }

    /// Real capture, real sound: the Mac plays the recording aloud and the session hears it
    /// through the microphone, or through ScreenCaptureKit for system audio.
    private static func liveAudioCheck(_ controller: SessionController, source: AudioSourceKind, file: URL) async {
        let label = source == .microphone ? "microphone" : "system audio"
        controller.setDirection(.englishToThai)
        controller.setAudioSource(source)
        _ = await waitUntil(120) {
            if case .ready(let name) = controller.speechStatus { return name.contains("EN") }
            return false
        }
        controller.listenOrStop()
        // A first run may show the permission prompt; give the person time to answer it.
        let started = await waitUntil(90) { controller.engine.listening || controller.engine.microphoneDenied }
        check("\(label): Listen starts with real capture", started && controller.engine.listening,
              "listening \(controller.engine.listening), denied \(controller.engine.microphoneDenied), toast \(controller.toast ?? "")")
        guard controller.engine.listening else { return }
        await sleep(1.5)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [file.path]
        try? player.run()
        var peak: Float = 0
        while player.isRunning {
            await sleep(0.1)
            peak = max(peak, controller.levels.levels.max() ?? 0)
        }
        await sleep(2.5)
        check("\(label): level meter hears the sound", peak > 0.05, String(format: "peak level %.2f", peak))
        snapshot("\(label)-live")
        controller.listenOrStop()
        _ = await waitUntil(30) { !controller.engine.listening && !controller.stopping }
        _ = await waitUntil(60) { controller.engine.pendingTranslation == nil && !controller.isTranslating }
        let turns = controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }
        let source = turns.map(\.sourceDisplay).joined(separator: " ")
        let translation = turns.map(\.translationCommitted).joined(separator: " ")
        let heard = ["meeting", "notes", "translation", "ship"].filter { source.lowercased().contains($0) }
        check("\(label): speech recognized from real sound", heard.count >= 2, source)
        check("\(label): translated to Thai", translation.unicodeScalars.contains { (0x0E00...0x0E7F).contains($0.value) }, translation)
    }

    /// Shrink the window to the minimum; panels stay readable.
    private static func windowCheck() async {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 960, height: 640)), display: true)
        await sleep(1)
        let size = window.frame.size
        check("Window shrinks to the 960 × 640 minimum", size.width <= 961 && size.height <= 641,
              "\(Int(size.width)) × \(Int(size.height)); minSize \(window.minSize) contentMinSize \(window.contentMinSize)")
        snapshot("minimum-window")
        print("AUTOMATION MARK minimum-window")
        fflush(stdout)
        // Long enough for an outside screen capture of the real window at this size.
        await sleep(5)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1440, height: 900)), display: true)
    }

    /// The window has an empty toolbar so the traffic lights center in the 52 pt header.
    /// Clicks on the header must still reach SwiftUI, not the title bar.
    private static func headerHitCheck() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
              let content = window.contentView, let frame = content.superview else {
            check("Header controls receive clicks", false, "no window")
            return
        }
        let width = content.bounds.width
        let points: [(String, CGFloat)] = [("sessions toggle", 101), ("language pill", width / 2 - 40), ("Copy", width - 90), ("summary toggle", width - 29)]
        var misses: [String] = []
        for (name, x) in points {
            let point = NSPoint(x: x, y: window.frame.height - 26)
            let hit = frame.hitTest(frame.convert(point, from: nil))
            // SwiftUI controls live inside the hosting view; the title bar must not take the click.
            if hit == nil || !(hit!.isDescendant(of: content)) {
                misses.append("\(name) → \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
        check("Header controls receive clicks", misses.isEmpty, misses.isEmpty ? "sessions, languages, Copy, summary" : misses.joined(separator: "; "))
    }

    private static func deleteCheck(_ controller: SessionController) async {
        // Delete the pack, Listen disables. This runs against LT_STORAGE only.
        if ProcessInfo.processInfo.environment["LT_STORAGE"] != nil, let pack = controller.platformPacks.first {
            await controller.deletePack(pack)
            check("Delete the pack, Listen disables", !controller.engine.packInstalled && !controller.engine.listenEnabled, "\(controller.engine.listenState)")
            snapshot("pack-deleted")
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "delete" {
            await sleep(3)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
        }
    }
}

/// Measures how late a 20 ms main-queue timer fires.
final class MainThreadWatchdog {
    private var timer: DispatchSourceTimer?
    private var last = DispatchTime.now()
    private(set) var worst: Double = 0
    private(set) var stalls: [(Date, Double)] = []

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(1))
        last = .now()
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            let gap = Double(now.uptimeNanoseconds - self.last.uptimeNanoseconds) / 1e9 - 0.02
            self.worst = max(self.worst, gap)
            if gap > 0.1 { self.stalls.append((Date(), gap)) }
            self.last = now
        }
        timer.resume()
        self.timer = timer
    }

    func stop() -> Double {
        timer?.cancel()
        return worst
    }
}

/// Lets the runner read the controller's status without exposing more API.
@MainActor
enum SessionControllerProbe {
    static weak var controller: SessionController?
    static var speech: EngineStatus { controller?.speechStatus ?? .idle }
}
#endif
