#if os(macOS) && DEBUG
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Debug-only stand-in for the microphone: plays a recording into the session at
/// real-time speed, so the running app can be checked without someone talking.
final class FileCapture: AudioCapturing, @unchecked Sendable {
    private let url: URL
    private var running = false
    private let lock = NSLock()

    /// The endurance check loops one short recording instead of holding hours of audio in memory.
    static var repeating = false

    init(url: URL) { self.url = url }

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        let samples = try Self.read(url)
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in
            let hop = 320
            let tail = [Float]()  // Stop arrives right after the last word; the drain must recover it.
            let all = samples + tail
            let repeating = FileCapture.repeating
            var offset = 0
            var played = 0
            let start = Date()
            while offset < all.count {
                guard let self else { return }
                self.lock.lock(); let on = self.running; self.lock.unlock()
                guard on else { return }
                let end = min(offset + hop, all.count)
                onSamples(Array(all[offset..<end]))
                played += end - offset
                offset = end
                if repeating, offset >= all.count { offset = 0 }
                let wait = start.addingTimeInterval(Double(played) / 16_000).timeIntervalSinceNow
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
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "sheet" {
            let watchdog = MainThreadWatchdog()
            watchdog.start()
            let input = InputLatencyProbe()
            input.start()
            print("AUTOMATION MARK sheet"); fflush(stdout)
            for _ in 0..<3 {
                controller.showModels = true
                await sleep(4)
                controller.showModels = false
                await sleep(1.5)
            }
            let worst = watchdog.stop()
            let inputWorst = input.stop()
            // What a person feels is how long a click or key waits; the dispatch-queue timer
            // above also counts time AppKit spends idle in a sheet-animation run loop mode.
            check("Models sheet: main dispatch queue timer (informational)", true, String(format: "worst stall %.0f ms; ", worst * 1000) + watchdog.stalls.map { String(format: "%.0f", $0.1 * 1000) }.joined(separator: ","))
            // The models panel lives inside the window, so it must not hold input the way a
            // sheet does (macOS holds input ~0.4 s while presenting any sheet).
            check("Models panel: input events handled within 150 ms while it opens and closes", inputWorst < 0.15,
                  String(format: "models panel %.0f ms over %d events", inputWorst * 1000, input.count))
            // Rendering the window to a PNG blocks the main thread, so it runs after the timing.
            controller.showModels = true
            await sleep(2)
            snapshot("models-panel")
            controller.showModels = false
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "ask" {
            await askCheck(controller)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "snap" {
            // Every visible window as a PNG after the demo content settles (LT_DEMO, LT_SIDE_PANEL, LT_SETTINGS_TAB).
            await sleep(6)
            for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.height > 200 {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = (window.title.isEmpty ? "window" : window.title).replacingOccurrences(of: " ", with: "-")
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("snap-\(index)-\(name).png"))
            }
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "quit" {
            // Quit in the middle of speech: nothing queued for the speech graphs may run during exit.
            controller.setDirection(.englishToThai)
            _ = await waitUntil(120) { if case .ready = controller.speechStatus { return true }; return false }
            controller.automationFeed = english
            controller.listenOrStop()
            await sleep(Double.random(in: 1.5...4))
            check("Listening when quit", controller.engine.listening, "")
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "long" {
            await longMeetingCheck(controller)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "recover" {
            await translatorRecoveryCheck(controller, thai: thai)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "stress" {
            await stressCheck(controller, english: english, thai: thai)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "endurance" {
            await enduranceCheck(controller, english: english, thai: thai)
            check("Done", true, folder.path)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["LT_AUTOMATION_ONLY"] == "keys" {
            await keyboardCheck(controller)
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
              "listening \(controller.engine.listening), denied \(controller.engine.microphoneDenied), mic permission \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue), speech \(controller.speechStatus), toast \(controller.toast ?? "")")
        guard controller.engine.listening else { return }
        await sleep(1.5)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [file.path]
        try? player.run()
        var peak: Float = 0
        var peakAfterChange: Float = 0
        var changed = false
        var updatesAfterChange = 0
        var previous = controller.levels.levels
        let began = Date()
        while player.isRunning {
            await sleep(0.1)
            let levels = controller.levels.levels
            peak = max(peak, levels.max() ?? 0)
            // Bars only shift when new audio arrives, so only a changed array counts as fresh sound.
            if changed, levels != previous {
                updatesAfterChange += 1
                peakAfterChange = max(peakAfterChange, levels.last ?? 0)
            }
            previous = levels
            // Midway, act as if headphones were plugged in: capture must restart, not go silent.
            if source == .microphone, !changed, Date().timeIntervalSince(began) > 3 {
                changed = controller.simulateInputDeviceChange()
            }
        }
        await sleep(2.5)
        check("\(label): level meter hears the sound", peak > 0.05, String(format: "peak level %.2f", peak))
        if source == .microphone {
            check("microphone: capture restarts after an input device change",
                  changed && controller.microphoneRunning && controller.engine.listening && updatesAfterChange >= 10 && peakAfterChange > 0.05,
                  String(format: "engine running %@, listening %@, %d level updates after the change, peak %.2f",
                         String(controller.microphoneRunning), String(controller.engine.listening), updatesAfterChange, peakAfterChange))
        }
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

    /// A two-hour meeting's transcript on screen while words keep arriving: the window must
    /// stay as responsive at turn 1,500 as at turn 1.
    private static func longMeetingCheck(_ controller: SessionController) async {
        let count = Int(ProcessInfo.processInfo.environment["LT_LONG_TURNS"] ?? "1500") ?? 1500
        // Real listening holds this activity (startListening); the demo session does not start capture,
        // so the check takes it itself. Without it macOS throttles a background app's timers and events.
        let activity = ProcessInfo.environment_noNap ? nil : ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Long meeting check")
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        let loadStart = Date()
        controller.loadLongDemo(turns: count)
        await sleep(3)
        check("Long meeting: \(count) turns load", controller.engine.turns.count >= count,
              String(format: "%d turns in %.1f s", controller.engine.turns.count, Date().timeIntervalSince(loadStart)))
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        let input = InputLatencyProbe()
        input.start()
        let words = "and then we will also need to confirm the training dates with every store manager before the opening".split(separator: " ")
        var text = ""
        for (index, word) in words.enumerated() {
            text += (index == 0 ? "" : " ") + word
            controller.pushDemoPartial(text)
            await sleep(0.1)
        }
        for _ in 0..<40 {
            controller.pushDemoPartial(text + " " + String(repeating: ".", count: Int.random(in: 1...3)))
            await sleep(0.1)
        }
        // New turns keep starting in a real meeting: each one appends a row and scrolls to it.
        let started = Date()
        var marks: [String] = []
        for round in 0..<6 {
            controller.pushDemoPartial(text, endpoint: true)
            marks.append(String(format: "turn %d at %.1f s", round, Date().timeIntervalSince(started)))
            await sleep(0.5)
            for (index, word) in words.prefix(8).enumerated() {
                controller.pushDemoPartial(words.prefix(index + 1).joined(separator: " ") + " \(round)")
                _ = word
                await sleep(0.1)
            }
        }
        print("AUTOMATION long marks " + marks.joined(separator: "; ")); fflush(stdout)
        let stallTimes = watchdog.stalls.map { String(format: "%.0f ms at +%.1f s", $0.1 * 1000, $0.0.timeIntervalSince(started)) }
        print("AUTOMATION long stalls " + stallTimes.joined(separator: "; ")); fflush(stdout)
        let worst = watchdog.stop()
        let inputWorst = input.stop()
        snapshot("long-meeting")
        check("Long meeting: input handled within 100 ms while words arrive", inputWorst < 0.1,
              String(format: "worst input delay %.0f ms over %d events; main-queue stalls %@", inputWorst * 1000, input.count,
                     watchdog.stalls.map { String(format: "%.0f", $0.1 * 1000) }.joined(separator: ",")))
        check("Long meeting: main thread never stalls over 150 ms", worst < 0.15, String(format: "worst %.0f ms", worst * 1000))
    }

    /// Ask: replies become text, citation chips and action cards; a real on-device answer arrives.
    private static func askCheck(_ controller: SessionController) async {
        controller.loadDemo()
        await sleep(1)
        let record = controller.displayedRecord
        let permit = record.turns.first { $0.source.hasPrefix("Probably by the end of next week") }
        let clock = permit.map { AskParsing.clock(record, $0) } ?? "?"
        let reply = "Store three opens once the permit arrives, [\(clock)]. If it slips, early February.\nACTION: Notion | 2 tasks added | Send updated timeline · Fri; Share permit decision · Next week | Store rollout › Tasks | https://www.notion.so/x"
        let parsed = AskParsing.message(from: reply, toolActions: [], record: record)
        check("Ask: a cited time becomes a chip for its turn", parsed.citations.first?.turnID == permit?.id && !parsed.text.contains("[") && !parsed.text.contains(",."),
              "\(parsed.citations.map { "\($0.clock) \($0.speaker)" }) · \(parsed.text)")
        check("Ask: an ACTION line becomes a card", parsed.actions.first.map { $0.app == "Notion" && $0.items.count == 2 && $0.link != nil } ?? false
              && !parsed.text.contains("ACTION"),
              parsed.actions.map { "\($0.app) \($0.result) \($0.items) \($0.location)" }.joined())
        let system = AskParsing.system(for: record, apps: ["Notion"], budget: 400_000)
        check("Ask: the prompt carries the transcript with times and the connected apps",
              system.contains("[\(clock)]") && system.contains("Notion") && system.contains("ACTION:"), "\(system.count) characters")
        // A real answer from the model on this Mac.
        let previous = AIConnections.shared.provider
        AIConnections.shared.provider = .onDevice
        AskEngine.shared.clear(record.id)
        let started = Date()
        AskEngine.shared.ask("When do they expect the permit, and what happens if it slips?", about: record)
        let answered = await waitUntil(240) { !AskEngine.shared.thinking.contains(record.id) }
        let answer = AskEngine.shared.messages(for: record.id).last
        check("Ask: on this Mac answers from the transcript", answered && answer?.role == .assistant && !(answer?.text.isEmpty ?? true),
              String(format: "%.1f s: ", Date().timeIntervalSince(started)) + String((answer?.text ?? "none").prefix(160)))
        check("Ask: the answer mentions the permit timing",
              ["week", "february", "feb"].contains { answer?.text.lowercased().contains($0) == true },
              answer?.citations.map(\.clock).joined(separator: ",") ?? "")
        AIConnections.shared.provider = previous
        snapshot("ask-live")
        // Sign-in discovery against the real servers (read-only: nothing is registered).
        for preset in MCPConnection.presets where !preset.url.isEmpty {
            guard let url = URL(string: preset.url) else { continue }
            do {
                let found = try await MCPAuth.discover(server: url)
                let ready = preset.needsClientID ? true : found.registrationEndpoint != nil
                check("Connect \(preset.name): sign-in discovered", ready,
                      "\(found.authorizationEndpoint.host ?? "?") · register \(found.registrationEndpoint?.absoluteString ?? "none (needs a client ID)") · scope \(found.scope ?? "-")")
            } catch {
                check("Connect \(preset.name): sign-in discovered", false, error.localizedDescription)
            }
        }
    }

    /// Kills this app's own translator process mid-session, the way a crash or the
    /// system would, and checks that later turns are still translated.
    private static func translatorRecoveryCheck(_ controller: SessionController, thai: URL) async {
        controller.setDirection(.thaiToEnglish)
        _ = await waitUntil(120) { if case .ready(let name) = controller.speechStatus { return name.contains("Typhoon") }; return false }
        // Warm the translator so the kill lands on a running process.
        _ = await waitUntil(60) { if case .ready = controller.translatorStatus { return true }; return false }
        await sleep(8)
        let me = ProcessInfo.processInfo.processIdentifier
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killer.arguments = ["-9", "-P", String(me), "-f", "chindamt"]
        try? killer.run()
        killer.waitUntilExit()
        check("Translator process killed mid-session", killer.terminationStatus == 0, "pkill exit \(killer.terminationStatus) (children of \(me) only)")
        let turns = await listen(controller, file: thai, direction: .thaiToEnglish, label: "after-kill")
        let translated = turns.filter { !$0.translationCommitted.isEmpty }
        check("Turns after the kill are still translated", !translated.isEmpty && translated.count == turns.count,
              "\(translated.count) of \(turns.count): \(translated.last?.translationCommitted.prefix(80) ?? "")")
        check("Translator status recovers", { if case .ready = controller.translatorStatus { return true }; return false }(), "\(controller.translatorStatus)")
    }

    /// Resident memory of this app's helper processes (translator, notes model), in MB.
    private static func helpersMB() -> Double {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        let me = ProcessInfo.processInfo.processIdentifier
        shell.arguments = ["-c", "ps -o rss= -p $(pgrep -d, -P \(me)) 2>/dev/null"]
        let pipe = Pipe()
        shell.standardOutput = pipe
        shell.standardError = FileHandle.nullDevice
        guard (try? shell.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        let kilobytes = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        return kilobytes.reduce(0, +) / 1024
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// Abuse the controls the way an impatient person would, with the main thread watched
    /// throughout: nothing may crash, hang, or leave the session in a stuck state.
    private static func stressCheck(_ controller: SessionController, english: URL, thai: URL) async {
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        let began = Date()
        var marks: [(Double, String)] = []
        func mark(_ name: String) { marks.append((Date().timeIntervalSince(began), name)) }
        controller.setDirection(.englishToThai)
        _ = await waitUntil(120) { if case .ready = controller.speechStatus { return true }; return false }
        controller.automationFeed = english

        mark("listen/stop storm")
        // 1. Listen / Stop as fast as the button can be pressed.
        for _ in 0..<25 {
            controller.listenOrStop()
            await sleep(Double.random(in: 0.02...0.25))
            controller.listenOrStop()
            await sleep(Double.random(in: 0.0...0.1))
        }
        let settled = await waitUntil(20) { !controller.engine.listening && !controller.stopping && !controller.isPreparing }
        check("Rapid Listen/Stop settles stopped", settled, "listening \(controller.engine.listening) stopping \(controller.stopping)")

        mark("pause storm")
        // 2. Pause / Resume storm while listening, then Stop.
        controller.listenOrStop()
        let relisten = await waitUntil(10) { controller.engine.listening }
        check("Listen works right after the Listen/Stop storm", relisten,
              "listening \(controller.engine.listening) preparing \(controller.isPreparing) stopping \(controller.stopping) speech \(controller.speechStatus) enabled \(controller.engine.listenEnabled) installed \(controller.engine.packInstalled) state \(controller.engine.listenState)")
        var dropped: String?
        for step in 0..<30 {
            controller.pauseOrResume()
            await sleep(Double.random(in: 0.0...0.08))
            if dropped == nil && !controller.engine.listening {
                dropped = "step \(step): paused \(controller.paused) toast \(controller.toast ?? "-") denied \(controller.engine.microphoneDenied)"
            }
        }
        if controller.paused { controller.pauseOrResume() }
        await sleep(1)
        check("Pause/Resume storm keeps listening", controller.engine.listening && !controller.paused,
              "listening \(controller.engine.listening) paused \(controller.paused) dropped at \(dropped ?? "never")")
        controller.listenOrStop()
        _ = await waitUntil(20) { !controller.engine.listening && !controller.stopping }

        mark("direction churn")
        // 3. Direction, preset, and language changes while the next graph is still loading.
        for direction in [TranslationDirection.thaiToEnglish, .englishToThai, .thaiToEnglish, TranslationDirection(source: .chinese, target: .english), .englishToThai] {
            controller.setDirection(direction)
            controller.setPreset([.fast, .balanced, .accurate].randomElement()!)
            await sleep(Double.random(in: 0.0...0.3))
        }
        controller.setPreset(.accurate)
        let reloaded = await waitUntil(120) {
            if case .ready(let name) = controller.speechStatus { return name.contains("EN") }
            return false
        }
        check("Direction and preset churn ends on the right model", reloaded, "\(controller.speechStatus)")

        mark("stop during load")
        // 4. Listen while the speech model is still loading, then Stop before it is ready.
        controller.setPreset(.balanced)
        controller.listenOrStop()
        controller.listenOrStop()
        let cancelled = await waitUntil(60) { !controller.isPreparing && !controller.engine.listening }
        check("Stop during model load cancels cleanly", cancelled, "preparing \(controller.isPreparing) listening \(controller.engine.listening)")
        controller.setPreset(.accurate)
        _ = await waitUntil(120) { if case .ready = controller.speechStatus { return true }; return false }

        mark("session actions")
        // 5. Session actions in the middle of listening.
        controller.listenOrStop()
        _ = await waitUntil(10) { controller.engine.listening }
        await sleep(3)
        controller.showSessions = true
        controller.showSummary = false
        controller.newSession()
        check("New session while listening stops and saves", !controller.engine.listening && controller.engine.turns.isEmpty, "turns \(controller.engine.turns.count)")
        controller.listenOrStop()
        _ = await waitUntil(10) { controller.engine.listening }
        await sleep(2)
        if let past = controller.sessions.first(where: { $0.id != controller.current.id }) {
            controller.open(past.id)
            await sleep(0.5)
            controller.viewingID = nil
        }
        controller.deleteSession(controller.current.id)
        check("Deleting the live session stops cleanly", !controller.engine.listening, "listening \(controller.engine.listening)")
        controller.showSummary = true
        controller.showSessions = false

        mark("copy/export")
        // 6. Copy everything while a session is live, and an empty session.
        controller.listenOrStop()
        _ = await waitUntil(10) { controller.engine.listening }
        await sleep(2)
        for kind in SessionCopyKind.allCases { controller.copySession(kind) }
        controller.listenOrStop()
        _ = await waitUntil(20) { !controller.engine.listening && !controller.stopping }
        controller.newSession()
        for kind in SessionCopyKind.allCases { controller.copySession(kind) }
        _ = controller.exportData(.markdown); _ = controller.exportData(.json); _ = controller.exportData(.text)
        check("Copy and export on live and empty sessions", true, "no crash")

        mark("models sheet")
        // 7. Models sheet open and closed during a session.
        controller.listenOrStop()
        _ = await waitUntil(10) { controller.engine.listening }
        controller.showModels = true
        await sleep(2)
        controller.showModels = false
        controller.listenOrStop()
        _ = await waitUntil(20) { !controller.engine.listening && !controller.stopping }

        controller.automationFeed = nil
        let worst = watchdog.stop()
        let stallList = watchdog.stalls.map { stall -> String in
            let at = stall.0.timeIntervalSince(began)
            let step = marks.last { $0.0 <= at }?.1 ?? "setup"
            return String(format: "%.0f ms in %@ at %.1f s", stall.1 * 1000, step, at)
        }
        // Sheet slide animations run the run loop in a mode that does not service the main
        // queue, so the watchdog cannot fire during them; the profile shows the main thread idle.
        let outsideSheet = watchdog.stalls.filter { stall in
            let at = stall.0.timeIntervalSince(began)
            return (marks.last { $0.0 <= at }?.1 ?? "") != "models sheet"
        }.map(\.1).max() ?? 0
        _ = worst
        check("Main thread responsive through the stress run", outsideSheet < 0.25,
              String(format: "worst stall outside sheet transitions %.0f ms; all: ", outsideSheet * 1000) + stallList.joined(separator: "; "))
        check("App still alive", true, String(format: "resident %.0f MB", residentMB()))
    }

    /// Ten minutes of speech (the PRD's endurance fixture): memory stays flat and
    /// the main thread stays responsive the whole time.
    private static func enduranceCheck(_ controller: SessionController, english: URL, thai: URL) async {
        let minutes = Double(ProcessInfo.processInfo.environment["LT_ENDURANCE_MINUTES"] ?? "10") ?? 10
        // One long recording: the English and Thai fixtures alternated with short pauses.
        let en = (try? FileCapture.read(english)) ?? []
        let th = (try? FileCapture.read(thai)) ?? []
        let gap = [Float](repeating: 0, count: 16_000)
        let long = en + gap + th + gap
        FileCapture.repeating = true
        defer { FileCapture.repeating = false }
        let url = folder.appendingPathComponent("endurance.wav")
        if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(long.count)),
           let file = try? AVAudioFile(forWriting: url, settings: format.settings) {
            buffer.frameLength = AVAudioFrameCount(long.count)
            long.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: long.count) }
            try? file.write(from: buffer)
        }
        controller.setDirection(.englishToThai)
        _ = await waitUntil(120) { if case .ready = controller.speechStatus { return true }; return false }
        controller.automationFeed = url
        let watchdog = MainThreadWatchdog()
        watchdog.start()
        controller.listenOrStop()
        _ = await waitUntil(10) { controller.engine.listening }
        var samples: [(Double, Double)] = []
        var helpers: [Double] = []
        let start = Date()
        while Date().timeIntervalSince(start) < minutes * 60 + 5 {
            await sleep(30)
            samples.append((Date().timeIntervalSince(start) / 60, residentMB()))
            helpers.append(helpersMB())
            print(String(format: "AUTOMATION endurance %.1f min resident %.0f MB helpers %.0f MB turns %d", samples.last!.0, samples.last!.1, helpers.last!, controller.engine.turns.count))
            fflush(stdout)
        }
        controller.listenOrStop()
        _ = await waitUntil(60) { !controller.engine.listening && !controller.stopping }
        let worst = watchdog.stop()
        controller.automationFeed = nil
        let early = samples.dropFirst(2).prefix(2).map(\.1)
        let late = samples.suffix(2).map(\.1)
        let growth = (late.reduce(0, +) / Double(max(late.count, 1))) - (early.reduce(0, +) / Double(max(early.count, 1)))
        check("Endurance: session ran the whole time", samples.count >= Int(minutes * 2), "\(samples.count) samples, \(controller.engine.turns.count) turns")
        check("Endurance: memory stays flat", growth < 150, String(format: "growth %.0f MB after warm-up; samples %@", growth, samples.map { String(format: "%.0f", $0.1) }.joined(separator: ",")))
        let helperGrowth = (helpers.suffix(2).reduce(0, +) / Double(max(min(helpers.count, 2), 1)))
            - (helpers.dropFirst(2).prefix(2).reduce(0, +) / Double(max(min(max(helpers.count - 2, 0), 2), 1)))
        check("Endurance: translator and notes memory stay flat", helperGrowth < 400,
              String(format: "growth %.0f MB; last %.0f MB", helperGrowth, helpers.last ?? 0))
        check("Endurance: main thread responsive", worst < 0.25, String(format: "worst stall %.0f ms", worst * 1000))
        let translated = controller.engine.turns.filter { !$0.translationCommitted.isEmpty }.count
        check("Endurance: turns keep translating", translated >= controller.engine.turns.count / 2, "\(translated) of \(controller.engine.turns.count) turns translated")
        // A long meeting must still translate at the end, not only in the first minutes.
        let recent = controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }.suffix(10)
        let recentTranslated = recent.filter { !$0.translationCommitted.isEmpty }.count
        check("Endurance: the last turns are translated too", recentTranslated >= recent.count - 1 && !recent.isEmpty,
              "\(recentTranslated) of the last \(recent.count)")
        check("Endurance: the summary is written", !controller.engine.notes.note.summary.isEmpty,
              String(controller.engine.notes.note.summary.map(\.text).joined(separator: " ").prefix(120)))
    }

    /// The design's shortcuts, sent as real key events through the app's menu bar:
    /// ⌥⌘1–4 copy the session, ⇧⌘K opens the floating captions above other windows.
    private static func keyboardCheck(_ controller: SessionController) async {
        controller.loadDemo()
        await sleep(1)
        func press(_ key: String, _ flags: NSEvent.ModifierFlags) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: NSApp.mainWindow?.windowNumber ?? 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0
            ) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        }
        let expectations: [(String, String, (String) -> Bool)] = [
            ("1", "⌥⌘1 copies the original", { $0.contains("Thanks for joining") && !$0.contains("ขอบคุณ") }),
            ("2", "⌥⌘2 copies the translation", { $0.contains("ขอบคุณ") && !$0.contains("Thanks for joining") }),
            ("3", "⌥⌘3 copies both, line by line", { $0.contains("opening in January.\nขอบคุณ") }),
            ("4", "⌥⌘4 copies the summary", { $0.contains("Supplier call on opening three new stores") && $0.contains("Send the updated timeline") }),
        ]
        for (key, name, valid) in expectations {
            NSPasteboard.general.clearContents()
            let handled = press(key, [.command, .option])
            await sleep(0.3)
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            check(name, handled && valid(pasted), String(pasted.prefix(120)))
        }
        controller.copyOptions.timestamps = true
        NSPasteboard.general.clearContents()
        _ = press("1", [.command, .option])
        await sleep(0.3)
        let stamped = NSPasteboard.general.string(forType: .string) ?? ""
        check("Include → Timestamps adds times", stamped.contains("Sarah · 10:02"), String(stamped.prefix(80)))
        controller.copyOptions.timestamps = false

        NSPasteboard.general.clearContents()
        let markdownHandled = press("c", [.command, .option, .shift])
        await sleep(0.3)
        let markdown = NSPasteboard.general.string(forType: .string) ?? ""
        check("⌥⇧⌘C copies the session as Markdown", markdownHandled && markdown.hasPrefix("# ") && markdown.contains("\n## "), String(markdown.prefix(120)))
        let exported = String(decoding: controller.exportData(.markdown), as: UTF8.self)
        let format = SessionController.ExportFormat.markdown
        check("Export → Markdown writes a .md file", exported == markdown && format.fileExtension == "md" && format.contentType.preferredFilenameExtension == "md",
              "\(format.contentType.identifier), .\(format.contentType.preferredFilenameExtension ?? "?")")

        let opened = press("k", [.command, .shift])
        await sleep(1.5)
        let captions = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(CaptionsWindow.id) == true }
        check("⇧⌘K opens floating captions", opened && captions?.isVisible == true, captions.map { "\(Int($0.frame.width)) × \(Int($0.frame.height))" } ?? "no window")
        // SwiftUI's .floating window level is AppKit's utility level (19): above every normal window.
        check("Captions keep on top of other windows", (captions?.level.rawValue ?? 0) > NSWindow.Level.normal.rawValue,
              "level \(captions?.level.rawValue ?? -1) vs normal \(NSWindow.Level.normal.rawValue)")
        if let captions, let view = captions.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("captions-live.png"))
        }
        let toggled = press("i", [.command, .option])
        await sleep(0.5)
        check("⌥⌘I hides the summary panel", toggled && !controller.showSummary, "showSummary \(controller.showSummary)")
        _ = press("i", [.command, .option])
        let sessions = press("s", [.command, .control])
        await sleep(0.5)
        check("⌃⌘S shows the sessions list", sessions && controller.showSessions, "showSessions \(controller.showSessions)")
        _ = press("s", [.command, .control])
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

/// Posts an application-defined event every 20 ms from a background thread and times
/// how long each waits before AppKit dispatches it: the delay a click or key press would see.
final class InputLatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var monitor: Any?
    private var worstDelay: Double = 0
    private(set) var count = 0

    @MainActor
    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == 0x4C54, let self else { return event }
            let delay = ProcessInfo.processInfo.systemUptime - event.timestamp
            self.lock.lock()
            self.worstDelay = max(self.worstDelay, delay)
            self.count += 1
            self.lock.unlock()
            return nil
        }
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in
            while let self, self.isRunning {
                if let event = NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                    subtype: 0x4C54, data1: 0, data2: 0
                ) {
                    NSApp.postEvent(event, atStart: false)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    @MainActor
    func stop() -> Double {
        lock.lock(); running = false; let worst = worstDelay; lock.unlock()
        if let monitor { NSEvent.removeMonitor(monitor) }
        return worst
    }
}

private extension ProcessInfo {
    /// LT_LONG_NO_ACTIVITY=1 runs the long-meeting check without the listening activity, for comparison.
    static var environment_noNap: Bool { processInfo.environment["LT_LONG_NO_ACTIVITY"] != nil }
}

/// Lets the runner read the controller's status without exposing more API.
@MainActor
enum SessionControllerProbe {
    static weak var controller: SessionController?
    static var speech: EngineStatus { controller?.speechStatus ?? .idle }
}
#endif
