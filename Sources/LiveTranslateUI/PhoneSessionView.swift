#if os(iOS)
import SwiftUI
import UIKit

/// The iPhone screen in the live-session design's language: the language pill,
/// two-language turns, the floating Listening pill, and the summary as a page.
/// Portrait stacks each turn; landscape puts the languages side by side.
struct PhoneSessionView: View {
    @ObservedObject var controller: SessionController
    let arrangement: PanelArrangement
    /// From `SessionChrome`: Conversation / Notes pages, Highlight beside Listen.
    let pages: [SessionControl]
    let beside: [SessionControl]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if pages.count > 1 {
                Picker("Page", selection: $controller.phoneShowsNotes) {
                    Text("Conversation").tag(false)
                    Text("Summary").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Theme.hairline.frame(height: 1)
            if controller.phoneShowsNotes {
                PhoneSummary(controller: controller)
            } else {
                PhoneTranscript(controller: controller, arrangement: arrangement, beside: beside)
            }
        }
        .background(Color.white)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .overlay(alignment: .bottom) {
            if let message = controller.toast {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color.white, in: Capsule())
                    .overlay(Capsule().stroke(Theme.border))
                    .padding(.bottom, 96)
            }
        }
        .sheet(isPresented: $controller.showModels) {
            ModelScreen(controller: controller, library: controller.library)
        }
        .alert("Rename speaker", isPresented: $controller.renaming) {
            TextField("Name", text: $controller.renameText)
            Button("Save") { controller.renameCurrent(to: controller.renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: controller.displayedRecord.displayTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                PhoneCopyMenu(controller: controller)
                Button { controller.showModels = true } label: {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Models")
            }
            PhoneLanguagePill(controller: controller)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// English ⇄ Thai on a #F4F4F7 capsule, as in the design's header.
private struct PhoneLanguagePill: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let direction = controller.engine.direction
        HStack(spacing: 0) {
            menu(direction.source) { picked in
                controller.setDirection(picked == direction.target ? direction.reversed : TranslationDirection(source: picked, target: direction.target))
            }
            Button(action: controller.swapDirection) {
                Glyph(kind: .swap, size: 14, lineWidth: 1.6)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("Swap languages")
            menu(direction.target) { picked in
                controller.setDirection(picked == direction.source ? direction.reversed : TranslationDirection(source: direction.source, target: picked))
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .background(Theme.pillFill, in: Capsule())
        .allowsHitTesting(!controller.engine.listening && !controller.isViewingPast)
    }

    private func menu(_ language: SpeechLanguage, pick: @escaping (SpeechLanguage) -> Void) -> some View {
        Menu {
            ForEach(SpeechLanguage.allCases) { option in
                Button(option.title) { pick(option) }
            }
        } label: {
            Text(language.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 30)
        }
    }
}

/// The design's Copy menu as a native menu: the four session copies, then Include.
private struct PhoneCopyMenu: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let direction = controller.displayedRecord.direction
        Menu {
            Section("Copy this session") {
                Button { controller.copySession(.original) } label: { Label("Original · \(direction.source.title)", systemImage: "text.alignleft") }
                Button { controller.copySession(.translation) } label: { Label("Translation · \(direction.target.title)", systemImage: "text.alignleft") }
                Button { controller.copySession(.bilingual) } label: { Label("Bilingual · line by line", systemImage: "rectangle.split.2x1") }
                Button { controller.copySession(.summary) } label: { Label("Summary", systemImage: "list.bullet") }
            }
            Section("Include") {
                Toggle("Speaker names", isOn: $controller.copyOptions.speakerNames)
                Toggle("Timestamps", isOn: $controller.copyOptions.timestamps)
                Toggle("Markdown formatting", isOn: $controller.copyOptions.markdown)
            }
        } label: {
            HStack(spacing: 6) {
                Glyph(kind: .copy)
                Text("Copy").font(.system(size: 15, weight: .medium))
                Glyph(kind: .chevronDown, size: 12, lineWidth: 1.75).foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
    }
}

private struct PhoneTranscript: View {
    @ObservedObject var controller: SessionController
    let arrangement: PanelArrangement
    let beside: [SessionControl]

    var body: some View {
        let direction = controller.displayedRecord.direction
        let turns = controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if turns.isEmpty {
                        VStack(spacing: 8) {
                            Text(ListenPolicy.idleLine)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.speakerName)
                            Text(controller.engine.packInstalled ? "Tap Listen. Words appear here as they are spoken." : controller.statusLine)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    }
                    ForEach(turns) { turn in
                        PhoneTurnRow(turn: turn, direction: direction, arrangement: arrangement, controller: controller)
                            .id(turn.id)
                    }
                }
                .padding(EdgeInsets(top: 8, leading: 8, bottom: 110, trailing: 8))
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .overlay(alignment: .top) {
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                if beside.contains(.highlight) && controller.engine.listening {
                    Button(action: controller.highlight) {
                        Image(systemName: "pin")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .frame(width: 48, height: 48)
                            .background(Color.white, in: Circle())
                            .overlay(Circle().stroke(Theme.border))
                    }
                    .accessibilityLabel("Highlight")
                }
                PhonePill(controller: controller, levels: controller.levels)
            }
            .padding(.bottom, 20)
            .shadow(color: Color(hex: 0x14163C, opacity: 0.08), radius: 12, y: 8)
        }
    }
}

private struct PhoneTurnRow: View {
    let turn: SessionTurn
    let direction: TranslationDirection
    let arrangement: PanelArrangement
    @ObservedObject var controller: SessionController

    var body: some View {
        let colors = Theme.speakers
        let index = controller.engine.speakers.colorIndex(ordinal: turn.speakerOrdinal, paletteCount: colors.count)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if controller.engine.speakers.chipsVisible, let index, !turn.speakerLabel.isEmpty {
                    Circle().fill(colors[index]).frame(width: 7, height: 7)
                    Text(verbatim: turn.speakerLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.speakerName)
                }
            }
            .frame(height: 22)
            if arrangement == .sideBySide {
                HStack(alignment: .top, spacing: 24) {
                    source.frame(maxWidth: .infinity, alignment: .leading)
                    translation.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    source
                    translation
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Copy original") { controller.copy(text: turn.sourceDisplay, label: "Original copied") }
            Button("Copy translation") { controller.copy(text: turn.translationCommitted + turn.translationProvisional, label: "Translation copied") }
            if turn.speakerOrdinal != nil {
                Button("Rename speaker…") { controller.beginRename(turn.id) }
            }
        }
    }

    private var source: some View {
        let language = direction.source
        return (Text(verbatim: turn.sourcePrefix)
            + Text(verbatim: turn.committed ? "" : turn.sourceTail).foregroundColor(Theme.secondary)
            + Text(verbatim: turn.committed ? "" : "▏").foregroundColor(Theme.accent))
            .font(Theme.body(language))
            .lineSpacing(Theme.lineSpacing(language))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var translation: some View {
        let language = direction.target
        let live = !turn.committed && !(turn.translationCommitted + turn.translationProvisional).isEmpty
        return (Text(verbatim: turn.translationCommitted)
            + Text(verbatim: turn.translationProvisional + (live ? "…" : "")).foregroundColor(Theme.secondary))
            .font(Theme.body(language))
            .lineSpacing(Theme.lineSpacing(language))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The design's Listening pill: dot, Listening, time, level bars, Pause, Stop.
/// Idle, it is the Listen button.
private struct PhonePill: View {
    @ObservedObject var controller: SessionController
    let levels: LevelMeter

    var body: some View {
        HStack(spacing: 10) {
            if controller.engine.listening {
                Circle().fill(controller.paused ? Color.orange : Theme.live).frame(width: 8, height: 8)
                Text(controller.paused ? "Paused" : "Listening").font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let total = max(0, Int(controller.elapsed(at: context.date)))
                    Text(String(format: "%d:%02d", total / 60, total % 60))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }
                PhoneLevelBars(levels: levels).frame(width: 33, height: 20)
                Button(action: controller.pauseOrResume) {
                    Glyph(kind: controller.paused ? .play : .pause, size: 14, lineWidth: 2)
                        .foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36)
                        .background(Theme.pauseFill, in: Circle())
                }
                .accessibilityLabel(controller.paused ? "Resume" : "Pause")
                Button(action: controller.listenOrStop) {
                    HStack(spacing: 6) {
                        Glyph(kind: .stop, size: 12)
                        Text("Stop").font(.system(size: 14, weight: .semibold)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 12)
                    .padding(.trailing, 16)
                    .frame(height: 36)
                    .background(Theme.live, in: Capsule())
                }
            } else {
                Button(action: controller.listenOrStop) {
                    HStack(spacing: 8) {
                        Glyph(kind: .mic, size: 16)
                        Text("Listen").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 36)
                    .background(Theme.accent.opacity(controller.engine.listenEnabled && controller.engine.packInstalled ? 1 : 0.4), in: Capsule())
                }
                .disabled(!(controller.engine.listenEnabled && controller.engine.packInstalled))
                .accessibilityIdentifier("listenButton")
            }
        }
        .padding(.leading, controller.engine.listening ? 16 : 6)
        .padding(.trailing, 6)
        .frame(height: 48)
        .fixedSize(horizontal: true, vertical: false)
        .background(Color.white, in: Capsule())
        .overlay(Capsule().stroke(Theme.border))
    }
}

private struct PhoneLevelBars: View {
    @ObservedObject var levels: LevelMeter

    var body: some View {
        Canvas { context, size in
            for (index, level) in levels.levels.suffix(7).enumerated() {
                let height = max(4, min(size.height, CGFloat(level) * size.height))
                let rect = CGRect(x: CGFloat(index) * 5, y: (size.height - height) / 2, width: 3, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(index < 2 ? Theme.waveQuiet : Theme.accent))
            }
        }
    }
}

/// The design's summary panel as the phone's Summary page.
private struct PhoneSummary: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        let note = controller.displayedRecord.note
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Text("Summary").font(.system(size: 17, weight: .semibold))
                    if controller.engine.listening || controller.notesRunning {
                        Circle().fill(Theme.live).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Button(action: controller.copySummary) {
                        HStack(spacing: 5) {
                            Glyph(kind: .copy, size: 14)
                            Text("Copy").font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(Theme.accent)
                    }
                }
                let summary = note.summary.map(\.text).joined(separator: " ")
                Text(verbatim: summary.isEmpty ? NotesReducer.emptyLine : summary)
                    .font(.system(size: 15))
                    .lineSpacing(15 * 0.26)
                    .foregroundStyle(summary.isEmpty ? Theme.secondary : Theme.text)
                    .textSelection(.enabled)
                let points = note.decisions + note.openQuestions + note.highlights
                if !points.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        section("Key points")
                        ForEach(points) { item in
                            HStack(alignment: .top, spacing: 0) {
                                Circle().frame(width: 5, height: 5).padding(.leading, 1).padding(.top, 9).frame(width: 18, alignment: .leading)
                                Text(verbatim: item.text).font(.system(size: 15)).lineSpacing(15 * 0.31)
                            }
                        }
                    }
                }
                if !note.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        section("Action items")
                        ForEach(note.actions) { item in
                            let done = controller.displayedRecord.checkedActions.contains(item.id)
                            HStack(alignment: .top, spacing: 10) {
                                DesignCheckbox(checked: done) { controller.toggleAction(item.id) }.padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.text).font(.system(size: 15))
                                    if !item.speaker.isEmpty {
                                        Text(verbatim: item.speaker).font(.system(size: 13)).foregroundStyle(Theme.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.panel)
    }

    private func section(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(12 * 0.04)
            .foregroundStyle(Theme.tertiary)
    }
}
#endif
