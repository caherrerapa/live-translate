#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let sessionPalette: [Color] = Theme.speakers

/// The Mac window from the "Mac app — live session" design: a 52 pt header, the
/// two-column transcript anchored to the bottom with a floating control pill, and
/// the 300 pt summary panel. The sessions list slides in from the header toggle.
struct MacSessionView: View {
    @ObservedObject var controller: SessionController
    @State private var copyMenuOpen = false
    @State private var exportFormat: SessionController.ExportFormat?

    var body: some View {
        VStack(spacing: 0) {
            DesignHeader(controller: controller, copyMenuOpen: $copyMenuOpen)
            Theme.hairline.frame(height: 1)
            HStack(spacing: 0) {
                if controller.showSessions {
                    SessionSidebar(controller: controller)
                        .frame(width: 248)
                        .transition(.move(edge: .leading))
                    Theme.hairline.frame(width: 1)
                }
                TranscriptMain(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if controller.showSummary {
                    Theme.hairline.frame(width: 1)
                    SummaryInspector(controller: controller)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Color.white)
        // The header is the title bar: it sits beside the traffic lights, not below them.
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .background(WindowChrome())
        .overlay(alignment: .topTrailing) {
            if copyMenuOpen {
                ZStack(alignment: .topTrailing) {
                    // Clicking anywhere else closes the menu, like a native one.
                    Color.black.opacity(0.001)
                        .onTapGesture { copyMenuOpen = false }
                    CopyMenuPanel(controller: controller) { copyMenuOpen = false }
                        .padding(.top, 46)
                        .padding(.trailing, 14 + 30 + 4)
                }
                .onExitCommand { copyMenuOpen = false }
            }
        }
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.2), value: controller.toast)
        .animation(.easeOut(duration: 0.2), value: controller.showSessions)
        .animation(.easeOut(duration: 0.2), value: controller.showSummary)
        #if DEBUG
        .task {
            AutomationRunner.startIfRequested(controller)
            // LT_DEMO=1 fills the real window with the design's content, for screenshots.
            if ProcessInfo.processInfo.environment["LT_DEMO"] != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                controller.loadDemo()
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
            }
        }
        #endif
        // A panel inside the window rather than a sheet: macOS holds all input for ~0.4 s
        // while it presents or dismisses a sheet, even with animations off.
        .overlay {
            if controller.showModels {
                ZStack {
                    Color.black.opacity(0.22)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { controller.showModels = false }
                    ModelScreen(controller: controller, library: controller.library) {
                        controller.showModels = false
                    }
                    .frame(maxWidth: 760, maxHeight: 600)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
                    .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                    .padding(24)
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .sheet(isPresented: $controller.claudeSetupPresented) {
            ClaudeSetupSheet()
        }
        .sheet(isPresented: $controller.calendarSetupPresented) {
            CalendarSettingsView()
        }
        .alert("Rename speaker", isPresented: $controller.renaming) {
            TextField("Name", text: $controller.renameText)
            Button("Save") { controller.renameCurrent(to: controller.renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: controller.exportRequest) { _, request in
            guard let request else { return }
            exportFormat = request
            controller.exportRequest = nil
        }
        .fileExporter(
            isPresented: Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } }),
            document: ExportFile(data: exportFormat.map { controller.exportData($0) } ?? Data()),
            contentType: exportFormat?.contentType ?? .plainText,
            defaultFilename: "\(controller.displayedRecord.displayTitle).\(exportFormat?.fileExtension ?? "txt")"
        ) { _ in exportFormat = nil }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = controller.toast {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Color.white, in: Capsule())
                .overlay(Capsule().stroke(Theme.border))
                .shadow(color: Color(hex: 0x14163C, opacity: 0.08), radius: 12, y: 8)
                .padding(.bottom, 84)
                .transition(.opacity)
        }
    }
}

// MARK: Window

/// Puts the traffic lights where the design draws them: centered in the 52 pt header,
/// 20 pt from the left edge, 8 pt apart. The title bar has no toolbar, so nothing
/// covers the header that SwiftUI draws underneath it. AppKit re-lays the buttons
/// out on resize, so they are placed again after every layout change.
private struct WindowChrome: NSViewRepresentable {
    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        weak var window: NSWindow?

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(nsView.window, context.coordinator) }
    }

    private func attach(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        if coordinator.window !== window {
            coordinator.window = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar = nil
            window.backgroundColor = .white
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification,
            ]
            coordinator.observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { Self.placeLights(window) }
                }
            }
        }
        Self.placeLights(window)
    }

    static func placeLights(_ window: NSWindow) {
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        guard let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview, let container = titlebar.superview,
              let frameView = container.superview else { return }
        // Grow the title bar strip to the header's height so the lights can sit in it.
        var strip = container.frame
        strip.size.height = 52
        strip.origin.y = frameView.bounds.height - 52
        container.frame = strip
        titlebar.frame = container.bounds
        for (index, kind) in kinds.enumerated() {
            guard let button = window.standardWindowButton(kind) else { continue }
            let size = button.frame.size
            button.setFrameOrigin(NSPoint(
                x: 20 + CGFloat(index) * 20 - (size.width - 12) / 2,
                y: (52 - size.height) / 2
            ))
        }
    }
}

// MARK: Header

private struct DesignHeader: View {
    @ObservedObject var controller: SessionController
    @Binding var copyMenuOpen: Bool

    var body: some View {
        GeometryReader { geo in
            content(width: geo.size.width)
        }
        .frame(height: 52)
    }

    /// The design's 320 pt title and 400 pt right group at full width; both give way
    /// together below 1300 pt so the centered language pill always fits.
    private func content(width: CGFloat) -> some View {
        let squeeze = min(1, max(0, (width - 960) / 340))
        let titleWidth = 150 + 170 * squeeze
        let rightWidth = 132 + 268 * squeeze
        return HStack(spacing: 8) {
            // The system's traffic lights: three 12 pt lights with 8 pt gaps.
            Color.clear.frame(width: 52, height: 12)
            HeaderIconButton(glyph: .sessions, label: controller.showSessions ? "Hide sessions" : "Show sessions", pressed: controller.showSessions) {
                controller.showSessions.toggle()
            }
            .padding(.leading, 14)
            EditableTitle(title: controller.displayedRecord.displayTitle) { controller.renameDisplayed($0) }
                .padding(.leading, 4)
                .frame(width: titleWidth, alignment: .leading)
            HStack {
                Spacer(minLength: 0)
                LanguagePill(controller: controller)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                CopyMenuButton(open: $copyMenuOpen)
                HeaderIconButton(glyph: .summary, label: controller.showSummary ? "Hide summary" : "Show summary", pressed: controller.showSummary) {
                    controller.showSummary.toggle()
                }
            }
            .frame(width: rightWidth, alignment: .trailing)
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .frame(height: 52)
    }
}

/// 30 pt square header button. Pressed: #ECEEFB fill, accent glyph.
private struct HeaderIconButton: View {
    let glyph: Glyph.Kind
    let label: String
    var pressed = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: glyph)
                .foregroundStyle(pressed ? Theme.accent : Theme.tertiary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(pressed ? Theme.accentSoft : (hovering ? Theme.pauseFill : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Title that turns into a text field on double-click.
private struct EditableTitle: View {
    let title: String
    let commit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        if editing {
            TextField("Title", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .onSubmit {
                    commit(draft)
                    editing = false
                }
                .onExitCommand { editing = false }
        } else {
            Text(verbatim: title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .onTapGesture(count: 2) {
                    draft = title
                    editing = true
                }
                .help("Double-click to rename")
        }
    }
}

/// English ⇄ Thai: a #F4F4F7 capsule with the two language menus and the swap button.
private struct LanguagePill: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let direction = controller.engine.direction
        HStack(spacing: 0) {
            languageMenu(direction.source, help: "Spoken language") { picked in
                controller.setDirection(picked == direction.target ? direction.reversed : TranslationDirection(source: picked, target: direction.target))
            }
            Button(action: controller.swapDirection) {
                Glyph(kind: .swap, size: 14, lineWidth: 1.6)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Swap languages")
            .accessibilityLabel("Swap languages")
            languageMenu(direction.target, help: "Translation language") { picked in
                controller.setDirection(picked == direction.source ? direction.reversed : TranslationDirection(source: direction.source, target: picked))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 32)
        .background(Theme.pillFill, in: Capsule())
        // Fixed while listening, without the grey of a disabled control.
        .allowsHitTesting(!controller.engine.listening && !controller.isViewingPast)
        .help(controller.engine.listening ? "Languages stay fixed until Stop." : "Spoken language ⇄ translation")
    }

    private func languageMenu(_ language: SpeechLanguage, help: String, pick: @escaping (SpeechLanguage) -> Void) -> some View {
        Menu {
            Section(help) {
                ForEach(SpeechLanguage.allCases) { option in
                    Button {
                        pick(option)
                    } label: {
                        if option == language {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
        } label: {
            Text(language.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Copy menu

/// "Copy ▾" in the header. Open: #E1E4F8 fill, #C7CBEF border, #2B3290 text.
struct CopyMenuButton: View {
    @Binding var open: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 6) {
                Glyph(kind: .copy)
                Text("Copy").font(.system(size: 13, weight: .medium))
                Glyph(kind: open ? .chevronUp : .chevronDown, size: 12, lineWidth: 1.75)
                    .foregroundStyle(open ? Theme.accentDark : Theme.tertiary)
            }
            .foregroundStyle(open ? Theme.accentDark : Theme.text)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: open ? 8 : 7)
                    .fill(open ? Theme.accentPressed : (hovering ? Theme.pauseFill : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(open ? Theme.accentPressedBorder : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Copy")
    }
}

/// The design's Copy menu: 320 pt white card, 32 pt rows, the hovered row in accent.
struct CopyMenuPanel: View {
    @ObservedObject var controller: SessionController
    /// Screenshots only: draws the Translation row highlighted, as in the design.
    var previewHighlight = false
    let close: () -> Void

    var body: some View {
        let direction = controller.displayedRecord.direction
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Copy this session", top: 6, bottom: 4)
            CopyMenuRow(glyph: .lines, title: "Original", detail: "· \(direction.source.title)", shortcut: "⌥⌘1") {
                controller.copySession(.original); close()
            }
            CopyMenuRow(glyph: .lines, title: "Translation", detail: "· \(direction.target.title)", shortcut: "⌥⌘2", forceHighlight: previewHighlight) {
                controller.copySession(.translation); close()
            }
            CopyMenuRow(glyph: .columns, title: "Bilingual", detail: "· line by line", shortcut: "⌥⌘3") {
                controller.copySession(.bilingual); close()
            }
            CopyMenuRow(glyph: .bullets, title: "Summary", detail: nil, shortcut: "⌥⌘4") {
                controller.copySession(.summary); close()
            }
            CopyMenuRow(glyph: .lines, title: "Whole session", detail: "· Markdown", shortcut: "⌥⇧⌘C") {
                controller.copyMarkdown(); close()
            }
            Theme.border.frame(height: 1).padding(.horizontal, 10).padding(.vertical, 6)
            sectionTitle("Include", top: 2, bottom: 4)
            CopyMenuRow(glyph: controller.copyOptions.speakerNames ? .check : nil, title: "Speaker names") {
                controller.copyOptions.speakerNames.toggle()
            }
            CopyMenuRow(glyph: controller.copyOptions.timestamps ? .check : nil, title: "Timestamps") {
                controller.copyOptions.timestamps.toggle()
            }
            CopyMenuRow(glyph: controller.copyOptions.markdown ? .check : nil, title: "Markdown formatting") {
                controller.copyOptions.markdown.toggle()
            }
        }
        .padding(6)
        .frame(width: 320)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.menuBorder))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 12)
    }

    private func sectionTitle(_ text: String, top: CGFloat, bottom: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, top)
            .padding(.bottom, bottom)
    }
}

private struct CopyMenuRow: View {
    let glyph: Glyph.Kind?
    let title: String
    var detail: String? = nil
    var shortcut: String? = nil
    var forceHighlight = false
    let action: () -> Void
    @State private var hovered = false

    private var hovering: Bool { hovered || forceHighlight }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let glyph {
                    Glyph(kind: glyph)
                        .foregroundStyle(glyph == .check && !hovering ? Theme.accent : (hovering ? Color.white : Theme.text))
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
                (Text(title) + Text(detail.map { " \($0)" } ?? "").foregroundColor(hovering ? Theme.accentOnDark : Theme.tertiary))
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? Theme.accentOnDark : Theme.tertiary)
                }
            }
            .foregroundStyle(hovering ? Color.white : Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: Transcript

private struct TranscriptMain: View {
    @ObservedObject var controller: SessionController

    private var record: SessionRecord { controller.displayedRecord }

    private var turns: [DisplayTurn] {
        if controller.isViewingPast {
            var order: [String: Int] = [:]
            return record.turns.map { turn in
                if !turn.speaker.isEmpty, order[turn.speaker] == nil { order[turn.speaker] = order.count }
                return DisplayTurn(
                    id: turn.id, speaker: turn.speaker, colorIndex: order[turn.speaker],
                    clock: record.started.addingTimeInterval(turn.start),
                    source: turn.source, sourceTail: "", translation: turn.translation,
                    translationProvisional: "", live: false, renamable: false
                )
            }
        }
        let origin = controller.engine.startedAt ?? Date()
        let chips = controller.engine.speakers.chipsVisible
        return controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }.map { turn in
            DisplayTurn(
                id: turn.id,
                speaker: chips ? turn.speakerLabel : "",
                colorIndex: chips ? controller.engine.speakers.colorIndex(ordinal: turn.speakerOrdinal, paletteCount: sessionPalette.count) : nil,
                clock: origin.addingTimeInterval(turn.start),
                source: turn.sourcePrefix,
                sourceTail: turn.committed ? "" : turn.sourceTail,
                translation: turn.translationCommitted,
                translationProvisional: turn.translationProvisional,
                live: !turn.committed,
                renamable: turn.speakerOrdinal != nil
            )
        }
    }

    var body: some View {
        let direction = record.direction
        let layout = controller.layout
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Column labels: 12 pt semibold, uppercase, 0.04 em tracking.
                HStack(alignment: .top, spacing: 48) {
                    if layout != .translationOnly { columnLabel(direction.source.title) }
                    if layout == .sideBySide || layout == .translationOnly { columnLabel(direction.target.title) }
                }
                .padding(.top, 16)
                .padding(.horizontal, 64)
                .frame(height: 44, alignment: .top)
                GeometryReader { geo in
                    ScrollViewReader { proxy in
                        ScrollView {
                            let rows = turns
                            VStack(spacing: 6) {
                                // Turns sit at the bottom, newest last, like the design.
                                Spacer(minLength: 0)
                                if rows.isEmpty {
                                    EmptyTranscript(controller: controller, sourceName: direction.source.title)
                                        .frame(maxWidth: .infinity)
                                        .padding(.bottom, 40)
                                }
                                ForEach(rows) { turn in
                                    TurnRow(
                                        turn: turn,
                                        direction: direction,
                                        layout: layout,
                                        focused: controller.engine.focusedTurnID == turn.id,
                                        controller: controller
                                    )
                                    .id(turn.id)
                                }
                            }
                            .padding(EdgeInsets(top: 4, leading: 48, bottom: 96, trailing: 48))
                            .frame(minHeight: geo.size.height, alignment: .bottom)
                        }
                        .defaultScrollAnchor(.bottom)
                        .defaultScrollAnchor(.bottom, for: .sizeChanges)
                        .onChange(of: controller.engine.focusedTurnID) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                        .onChange(of: controller.engine.turns.count) { _, _ in
                            guard controller.engine.listening, let last = controller.engine.turns.last else { return }
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .overlay(alignment: .top) {
                        // 48 pt fade from white at the top edge.
                        LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 48)
                            .allowsHitTesting(false)
                    }
                }
            }
            ControlPill(controller: controller, levels: controller.levels)
                .padding(.bottom, 24)
        }
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(12 * 0.04)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptyTranscript: View {
    @ObservedObject var controller: SessionController
    let sourceName: String

    var body: some View {
        VStack(spacing: 10) {
            switch controller.isViewingPast ? .idle : controller.engine.listenState {
            case .packMissing:
                Text("No \(controller.engine.direction.source.title) speech model yet")
                    .font(.system(size: 15, weight: .semibold))
                Text(controller.statusLine.isEmpty ? "Download a pack, or pick a streaming model from Hugging Face." : controller.statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Manage languages") { controller.showModels = true }
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .medium))
                    .accessibilityIdentifier("missingPackModels")
            case .microphoneDenied:
                Text("The microphone is off").font(.system(size: 15, weight: .semibold))
                Text("Live Translate needs the microphone to hear the room. Audio never leaves this Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                Button("Open System Settings", action: controller.openSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 13, weight: .medium))
            case .idle:
                Text(controller.isViewingPast ? "No words in this session." : ListenPolicy.idleLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.speakerName)
                    .accessibilityIdentifier("idleLine")
                if !controller.isViewingPast {
                    Text("Press Listen or ⌘↩. Words appear here as they are spoken; the translation follows beside them.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            case .listening, .listeningSilence:
                Text(controller.paused ? "Paused" : "Listening for \(sourceName)…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.speakerName)
            }
        }
    }
}

/// One turn: speaker dot and name, then the original and the translation side by side.
/// Hover shows the time, a #F6F6F9 fill, and a copy button beside each column.
struct TurnRow: View {
    let turn: DisplayTurn
    let direction: TranslationDirection
    let layout: TranscriptLayout
    let focused: Bool
    @ObservedObject var controller: SessionController
    @State private var hovering = false

    private var active: Bool { hovering || focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !turn.speaker.isEmpty {
                    Circle()
                        .fill(turn.colorIndex.map { sessionPalette[$0 % sessionPalette.count] } ?? Theme.secondary)
                        .frame(width: 7, height: 7)
                    Text(verbatim: turn.speaker)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.speakerName)
                        .onTapGesture(count: 2) { if turn.renamable { controller.beginRename(turn.id) } }
                }
                if active {
                    Text(turn.clock.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(height: 22)
            switch layout {
            case .sideBySide:
                HStack(alignment: .top, spacing: 48) {
                    column(sourceText, copyLabel: "Copy original") { copyOriginal() }
                    column(translationText, copyLabel: "Copy translation") { copyTranslation() }
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 8) {
                    column(sourceText, copyLabel: "Copy original") { copyOriginal() }
                    column(translationText, copyLabel: "Copy translation") { copyTranslation() }
                }
            case .translationOnly:
                column(translationText, copyLabel: "Copy translation") { copyTranslation() }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(active ? Theme.rowHighlight : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy original") { copyOriginal() }
            Button("Copy translation") { copyTranslation() }
            Button("Copy both") { controller.copy(text: turn.sourceText + "\n" + turn.translationText, label: "Turn copied") }
            if !controller.isViewingPast {
                Divider()
                Button("Highlight") {
                    controller.focus(turn.id)
                    controller.highlight()
                }
                if turn.renamable {
                    Button("Rename speaker…") { controller.beginRename(turn.id) }
                }
            }
        }
    }

    private func column(_ text: some View, copyLabel: String, copy: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            text.frame(maxWidth: .infinity, alignment: .leading)
            // Always laid out, only shown on hover, so the text never re-wraps as the pointer moves.
            Button(action: copy) {
                Glyph(kind: .copy, size: 14)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.chipBorder))
            }
            .buttonStyle(.plain)
            .help(copyLabel)
            .accessibilityLabel(copyLabel)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceText: some View {
        let language = direction.source
        return (Text(verbatim: turn.source)
            + Text(verbatim: turn.sourceTail).foregroundColor(Theme.secondary)
            + (turn.live ? Text(Image(nsImage: Self.caret)).baselineOffset(-3) : Text("")))
            .font(Theme.body(language))
            .lineSpacing(Theme.lineSpacing(language))
            .foregroundStyle(Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Theme.leadingInset(language))
    }

    private var translationText: some View {
        let language = direction.target
        let pending = turn.live && !turn.translationText.isEmpty ? "…" : ""
        return Group {
            if turn.translationText.isEmpty {
                Text(turn.live ? "…" : "")
                    .foregroundStyle(Theme.secondary)
            } else {
                (Text(verbatim: turn.translation)
                    + Text(verbatim: turn.translationProvisional + pending).foregroundColor(Theme.secondary))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
            }
        }
        .font(Theme.body(language))
        .lineSpacing(Theme.lineSpacing(language))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Theme.leadingInset(language))
    }

    private func copyOriginal() {
        controller.copy(text: turn.sourceText, label: "Original copied")
    }

    private func copyTranslation() {
        controller.copy(text: turn.translationText, label: "Translation copied")
    }

    /// The design's live caret: a 2 × 18 pt accent bar after the live words.
    private static let caret: NSImage = {
        let size = NSSize(width: 4, height: 18)
        return NSImage(size: size, flipped: false) { _ in
            NSColor(srgbRed: 0x3A / 255, green: 0x43 / 255, blue: 0xB8 / 255, alpha: 1).setFill()
            NSRect(x: 2, y: 0, width: 2, height: 18).fill()
            return true
        }
    }()
}

// MARK: Control pill

/// The floating pill: red dot, Listening, the time, the level bars, Pause, and Stop.
/// Idle, it offers the audio source, captions, and Listen.
private struct ControlPill: View {
    @ObservedObject var controller: SessionController
    let levels: LevelMeter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 12) {
            if controller.isViewingPast {
                Text("Saved session")
                    .font(.system(size: 13, weight: .semibold))
                Text("text only")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                pillButton("Back to live", fill: Theme.accent) { controller.viewingID = nil }
            } else if controller.engine.listening {
                Circle().fill(controller.paused ? Color.orange : Theme.live).frame(width: 8, height: 8)
                Text(controller.paused ? "Paused" : (controller.stopping ? "Finishing" : "Listening"))
                    .font(.system(size: 13, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(controller.elapsed(at: context.date)))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
                LevelBars(levels: levels)
                    .frame(width: 33, height: 20)
                Button(action: controller.pauseOrResume) {
                    Glyph(kind: controller.paused ? .play : .pause, size: 14, lineWidth: 2)
                        .foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36)
                        .background(Theme.pauseFill, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .help(controller.paused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)")
                .accessibilityLabel(controller.paused ? "Resume" : "Pause")
                Button(action: controller.listenOrStop) {
                    HStack(spacing: 6) {
                        Glyph(kind: .stop, size: 12)
                        Text("Stop").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                    .frame(height: 36)
                    .background(Theme.live, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop (⌘↩)")
                .accessibilityIdentifier("listenButton")
            } else {
                sourceMenu
                Text(readyLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 230, alignment: .leading)
                Button {
                    openWindow(id: CaptionsWindow.id)
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36)
                        .background(Theme.pauseFill, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Floating captions (⇧⌘K)")
                listenButton
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .frame(height: 48)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(Theme.border))
        .shadow(color: Color(hex: 0x14163C, opacity: 0.08), radius: 12, y: 8)
    }

    private var listenButton: some View {
        let enabled = controller.isPreparing || (controller.engine.listenEnabled && controller.engine.packInstalled)
        return Button(action: controller.listenOrStop) {
            HStack(spacing: 6) {
                if controller.isPreparing {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Loading").font(.system(size: 13, weight: .semibold))
                } else {
                    Glyph(kind: .mic, size: 14)
                    Text("Listen").font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, 12)
            .padding(.trailing, 16)
            .frame(height: 36)
            .background(enabled ? Theme.accent : Theme.accent.opacity(0.4), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Listen (⌘↩)")
        .accessibilityIdentifier("listenButton")
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(AudioSourceKind.allCases) { source in
                Button {
                    controller.setAudioSource(source)
                } label: {
                    if source == controller.audioSource {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Glyph(kind: controller.audioSource == .microphone ? .mic : .speaker, size: 14)
                Text(controller.audioSource.title).font(.system(size: 13, weight: .semibold))
                Glyph(kind: .chevronDown, size: 12, lineWidth: 1.75).foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(Theme.text)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Microphone hears the room. System audio hears what this Mac plays, such as a call.")
    }

    private func pillButton(_ title: String, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(fill, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var readyLine: String {
        switch controller.speechStatus {
        case .ready(let name): return "Ready · \(name)"
        case .loading(let name): return "Loading \(name)…"
        case .failed(let message): return message
        case .idle: return "No speech model for this language yet"
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Seven 3 pt bars, 2 pt apart: the two oldest in #9AA0E3, the rest in the accent.
/// It observes the meter itself and draws in one Canvas, so it redraws alone.
private struct LevelBars: View {
    @ObservedObject var levels: LevelMeter

    var body: some View {
        Canvas { context, size in
            let values = Array(levels.levels.suffix(7))
            for (index, level) in values.enumerated() {
                let height = max(4, min(size.height, CGFloat(level) * size.height))
                let rect = CGRect(x: CGFloat(index) * 5, y: (size.height - height) / 2, width: 3, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(index < 2 ? Theme.waveQuiet : Theme.accent))
            }
        }
    }
}

// MARK: Summary

/// The 300 pt summary panel: Summary with a live dot and Copy, the paragraph,
/// Key points, and Action items with checkboxes.
struct SummaryInspector: View {
    @ObservedObject var controller: SessionController

    private var record: SessionRecord { controller.displayedRecord }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Text("Summary").font(.system(size: 15, weight: .semibold))
                    if !controller.isViewingPast && (controller.engine.listening || controller.notesRunning) {
                        Circle().fill(Theme.live).frame(width: 6, height: 6)
                            .help("Updating live, on this Mac")
                    }
                    Spacer()
                    Button(action: controller.copySummary) {
                        HStack(spacing: 5) {
                            Glyph(kind: .copy, size: 14)
                            Text("Copy").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Copy summary (⌥⌘4)")
                }
                summary
                keyPoints
                actions
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
    }

    @ViewBuilder
    private var summary: some View {
        let text = record.note.summary.map { controller.noteText($0.text) }.joined(separator: " ")
        Text(verbatim: text.isEmpty ? NotesReducer.emptyLine : text)
            .font(.system(size: 14))
            .lineSpacing(14 * 0.26)
            .padding(.top, 1.5)
            .foregroundStyle(text.isEmpty ? Theme.secondary : Theme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var keyPoints: some View {
        let points = record.note.decisions + record.note.openQuestions + record.note.highlights
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Key points")
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(points) { item in
                        HStack(alignment: .top, spacing: 0) {
                            Circle()
                                .frame(width: 5, height: 5)
                                .padding(.leading, 1)
                                .padding(.top, 8.5)
                                .frame(width: 18, alignment: .leading)
                            // 14 pt at line-height 1.45, as in the design's list.
                            Text(verbatim: controller.noteText(item.text))
                                .lineSpacing(14 * 0.31)
                                .padding(.top, 1)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 14))
                        .opacity(item.tentative ? 0.75 : 1)
                        .contextMenu {
                            if !controller.isViewingPast {
                                Button("Jump to turn") { controller.focus(item.turnID) }
                                Button("Delete", role: .destructive) { controller.deleteNote(id: item.id) }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !record.note.actions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Action items")
                ForEach(record.note.actions) { item in
                    let done = record.checkedActions.contains(item.id)
                    HStack(alignment: .top, spacing: 10) {
                        DesignCheckbox(checked: done) { controller.toggleAction(item.id) }
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: controller.noteText(item.text))
                                .font(.system(size: 14))
                                .lineSpacing(14 * 0.2)
                                // CSS fits "…timeline to the" on the first line; SwiftUI needs a hair more room.
                                .padding(.trailing, -4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            if !item.speaker.isEmpty {
                                Text(verbatim: item.speaker)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(11 * 0.04)
            .foregroundStyle(Theme.tertiary)
    }
}

// MARK: Sessions

/// Session history behind the header's sessions toggle: search, new session,
/// sessions by day, and the on-device card with Manage languages.
struct SessionSidebar: View {
    @ObservedObject var controller: SessionController
    @State private var query = ""

    private var rows: [SessionRecord] {
        var all = controller.sessions
        let live = controller.engine.record(updating: controller.current)
        if !all.contains(where: { $0.id == live.id }) && (controller.engine.listening || !live.turns.isEmpty) {
            all.insert(live, at: 0)
        }
        return all.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
                    TextField("Search sessions", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.pillFill, in: RoundedRectangle(cornerRadius: 8))
                Button(action: controller.newSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("New session (⌘N)")
            }
            .padding(12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SessionGroup.allCases, id: \.self) { group in
                        let members = rows.filter { SessionGroup.of($0.started) == group }
                        if !members.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(11 * 0.04)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.horizontal, 10)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(members) { record in
                                row(record)
                            }
                        }
                    }
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Sessions you record appear here." : "No matching sessions.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                            .padding(10)
                    }
                }
                .padding(.horizontal, 8)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("On-device · works offline", systemImage: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(modelLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(2)
                Button("Manage languages") { controller.showModels = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
            .padding(12)
        }
        .background(Theme.sidebar)
    }

    private func row(_ record: SessionRecord) -> some View {
        let chosen = (controller.viewingID ?? controller.current.id) == record.id
        let live = record.id == controller.current.id && controller.engine.listening
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if live { Circle().fill(Theme.live).frame(width: 7, height: 7) }
                Text(verbatim: record.displayTitle)
                    .font(.system(size: 13, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(chosen ? Theme.accent : Theme.text)
                    .lineLimit(1)
            }
            Text(live ? "\(record.directionShort) · Live" : "\(record.directionShort) · \(SessionRecord.durationText(record.duration))")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Theme.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.open(record.id) }
        .contextMenu {
            Button("Delete", role: .destructive) { controller.deleteSession(record.id) }
        }
    }

    private var modelLine: String {
        let direction = controller.engine.direction
        switch controller.speechStatus {
        case .ready(let name): return "\(direction.source.title) ⇄ \(direction.target.title) · \(name)"
        case .loading(let name): return "Loading \(name)…"
        case .failed(let message): return message
        case .idle: return "\(direction.source.title) ⇄ \(direction.target.title) · no speech model yet"
        }
    }
}
#endif
