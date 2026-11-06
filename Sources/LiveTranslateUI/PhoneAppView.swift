#if os(iOS)
import SwiftUI
import Translation

/// The iPhone design: a start screen with one big button and recent sessions, a live
/// screen that shows each turn's original small and its translation large, and a
/// session screen with the summary, the transcript, Copy and Share.
struct PhoneAppView: View {
    @ObservedObject var controller: SessionController
    @State private var path: [UUID] = []
    @State private var picking: PhoneLanguageSide?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if controller.engine.listening || controller.isPreparing {
                    PhoneLiveScreen(controller: controller) { stop() }
                } else {
                    PhoneStartScreen(controller: controller, picking: $picking) { start() } open: { id in
                        path.append(id)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                PhoneSessionDetail(controller: controller, id: id)
            }
        }
        .sheet(item: $picking) { side in
            PhoneLanguagePicker(controller: controller, side: side)
        }
        #if DEBUG
        .task {
            // LT_PHONE_SCREEN opens one design screen over the demo content, for simulator screenshots.
            guard let screen = ProcessInfo.processInfo.environment["LT_PHONE_SCREEN"] else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            switch screen {
            case "start":
                controller.listenOrStop()
            case "summary", "copy", "transcript":
                stop()
            case "language":
                controller.listenOrStop()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                picking = .source
            default:
                break
            }
        }
        #endif
    }

    /// Each start is a new session; the last one is already saved in Recent.
    private func start() {
        if !controller.engine.turns.isEmpty { controller.newSession() }
        controller.listenOrStop()
    }

    /// Stop, then show the session that just ended.
    private func stop() {
        let id = controller.displayedRecord.id
        let hadSpeech = !controller.engine.turns.isEmpty
        controller.listenOrStop()
        if hadSpeech { path.append(id) }
    }
}

enum PhoneLanguageSide: String, Identifiable {
    case source, target
    var id: String { rawValue }
}

private enum Phone {
    static let fill = Color(hex: 0xF2F2F7)
    static let secondary = Color(hex: 0x636366)
    static let separator = Color(hex: 0xE0E0E6)
    static let chevron = Color(hex: 0x8E8E93)
    static let red = Color(hex: 0xD93036)
    static let redSoft = Color(hex: 0xFDECEC)
    static let redText = Color(hex: 0xB4232A)
    static let segmentFill = Color(hex: 0xEEEEF2)
    static let segmentText = Color(hex: 0x4A4A52)
    static let provisional = Color(hex: 0x6E6E73)

    /// "Today · 13 min · EN → TH"
    static func meta(_ record: SessionRecord, direction: Bool) -> String {
        var parts = [day(record.started), SessionRecord.durationText(record.duration)]
        if direction { parts.append(record.directionShort) }
        return parts.joined(separator: " · ")
    }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: Start

private struct PhoneStartScreen: View {
    @ObservedObject var controller: SessionController
    @Binding var picking: PhoneLanguageSide?
    let start: () -> Void
    let open: (UUID) -> Void

    private var recent: [SessionRecord] {
        Array(controller.sessions.filter { !$0.isEmpty }.sorted { $0.started > $1.started }.prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 40) {
                Button(action: start) {
                    ZStack {
                        Circle().fill(Theme.accentSoft).frame(width: 160, height: 160)
                        Circle().fill(Theme.accent).frame(width: 132, height: 132)
                        Image(systemName: "mic")
                            .font(.system(size: 46, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    .compositingGroup()
                    .shadow(color: Theme.accent.opacity(0.18), radius: 16, y: 14)
                }
                .buttonStyle(.plain)
                .disabled(!controller.engine.listenEnabled && !controller.isPreparing)
                .accessibilityLabel("Start")
                Text(startCaption)
                    .font(.system(size: 20, weight: .semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxHeight: .infinity)
            if !recent.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent").font(.system(size: 17, weight: .semibold))
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Phone.separator.frame(height: 1).padding(.leading, 16) }
                            Button { open(record.id) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(verbatim: record.displayTitle)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(Theme.text)
                                            .lineLimit(1)
                                        Text(verbatim: Phone.meta(record, direction: true))
                                            .font(.system(size: 13))
                                            .foregroundStyle(Phone.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Phone.chevron)
                                }
                                .padding(.leading, 16)
                                .padding(.trailing, 14)
                                .padding(.vertical, 10)
                                .frame(minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(Phone.fill, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var startCaption: String {
        if controller.isPreparing { return "Getting ready…" }
        if case .failed(let message) = controller.speechStatus { return message }
        return "Tap to start"
    }

    /// The language pill in the middle, settings on the right.
    private var header: some View {
        let direction = controller.engine.direction
        return HStack(spacing: 0) {
            Color.clear.frame(width: 44, height: 44)
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                languageButton(direction.source.title) { picking = .source }
                Button { controller.swapDirection() } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Swap languages")
                languageButton(direction.target.title) { picking = .target }
            }
            .padding(.horizontal, 4)
            .frame(height: 40)
            .background(Phone.fill, in: Capsule())
            Spacer(minLength: 0)
            Button { controller.showModels = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Settings")
        }
        .frame(height: 44)
        .padding(.top, 8)
    }

    private func languageButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Phone.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 32)
        }
        .buttonStyle(.plain)
    }
}

// MARK: Live

private struct PhoneLiveScreen: View {
    @ObservedObject var controller: SessionController
    let stop: () -> Void

    var body: some View {
        let direction = controller.engine.direction
        let turns = controller.engine.turns.filter { !$0.sourceDisplay.isEmpty }
        VStack(spacing: 0) {
            PhoneTimerChip(controller: controller)
                .frame(height: 44)
                .padding(.top, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if turns.isEmpty {
                        Text(controller.isPreparing ? "Getting ready…" : "Listening…")
                            .font(.system(size: 15))
                            .foregroundStyle(Phone.secondary)
                    }
                    ForEach(turns, id: \.id) { turn in
                        PhoneTurn(turn: turn, direction: direction, live: turn.id == turns.last?.id && !turn.committed)
                            .id(turn.id)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 56)
                    Color.black
                }
            }
            Button(action: stop) {
                VStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(Phone.red))
                        .background(Circle().fill(Phone.redSoft).padding(-6))
                    Text("Stop").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                }
            }
            .buttonStyle(.plain)
            .frame(height: 112)
            .disabled(controller.stopping)
        }
        .padding(.horizontal, 20)
    }
}

/// The red chip at the top: recording dot, elapsed time, five level bars.
private struct PhoneTimerChip: View {
    @ObservedObject var controller: SessionController

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Phone.red).frame(width: 7, height: 7)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: StatusStrip.elapsed(controller.elapsed(at: context.date)))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
            PhoneChipBars(levels: controller.levels)
        }
        .foregroundStyle(Phone.redText)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Phone.redSoft, in: Capsule())
        .opacity(controller.paused ? 0.5 : 1)
    }
}

private struct PhoneChipBars: View {
    @ObservedObject var levels: LevelMeter

    var body: some View {
        let recent = levels.levels.suffix(5)
        HStack(spacing: 2) {
            ForEach(Array(recent.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Phone.red)
                    .frame(width: 2, height: 4 + CGFloat(min(max(level, 0), 1)) * 10)
            }
        }
        .frame(height: 14)
    }
}

/// Original small and gray, translation large; the forming part of each is dimmer.
private struct PhoneTurn: View {
    let turn: SessionTurn
    let direction: TranslationDirection
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(verbatim: turn.sourcePrefix) + Text(verbatim: turn.committed ? "" : turn.sourceTail)
                + (live ? Text(verbatim: "|").foregroundColor(Theme.accent).fontWeight(.light) : Text("")))
                .font(Theme.body(direction.source, size: 15))
                .lineSpacing(15 * 0.45 - 4)
                .foregroundStyle(Phone.secondary)
            if !turn.translationCommitted.isEmpty || !turn.translationProvisional.isEmpty {
                (Text(verbatim: turn.translationCommitted)
                    + Text(verbatim: turn.translationProvisional.isEmpty ? "" : turn.translationProvisional + "…")
                        .foregroundColor(Phone.provisional))
                    .font(Theme.body(direction.target, size: 21, weight: .medium))
                    .lineSpacing(21 * 0.5 - 6)
                    .foregroundStyle(Theme.text)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Session

private struct PhoneSessionDetail: View {
    @ObservedObject var controller: SessionController
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .summary
    @State private var copying = false

    enum Tab { case summary, transcript }

    var body: some View {
        let record = controller.displayedRecord
        VStack(alignment: .leading, spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: record.displayTitle)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.3)
                    .lineLimit(2)
                Text(verbatim: Phone.meta(record, direction: false))
                    .font(.system(size: 15))
                    .foregroundStyle(Phone.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            segments
                .padding(.horizontal, 20)
                .padding(.top, 20)
            ScrollView {
                Group {
                    switch tab {
                    case .summary: summary(record)
                    case .transcript: transcript(record)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button { copying = true } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                ShareLink(item: record.markdown(), subject: Text(verbatim: record.displayTitle)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 52, height: 52)
                        .background(Phone.fill, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityLabel("Share")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            controller.open(id)
            #if DEBUG
            switch ProcessInfo.processInfo.environment["LT_PHONE_SCREEN"] {
            case "copy": copying = true
            case "transcript": tab = .transcript
            default: break
            }
            #endif
        }
        .sheet(isPresented: $copying) {
            PhoneCopySheet(controller: controller, record: record)
                .presentationDetents([.height(330)])
                .presentationCornerRadius(28)
                .presentationBackground(.white)
        }
    }

    private var segments: some View {
        HStack(spacing: 0) {
            segment("Summary", .summary)
            segment("Transcript", .transcript)
        }
        .padding(2)
        .background(Phone.segmentFill, in: RoundedRectangle(cornerRadius: 9))
    }

    private func segment(_ title: String, _ value: Tab) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            Text(title)
                .font(.system(size: 14, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Theme.text : Phone.segmentText)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7).fill(.white)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder
    private func summary(_ record: SessionRecord) -> some View {
        let note = record.note
        let summary = note.summary.map(\.text).joined(separator: " ")
        let points = note.decisions + note.openQuestions + note.highlights
        VStack(alignment: .leading, spacing: 28) {
            if summary.isEmpty && points.isEmpty && note.actions.isEmpty {
                Text(controller.notesRunning ? "Writing the summary…" : "No summary yet.")
                    .font(.system(size: 17))
                    .foregroundStyle(Phone.secondary)
            }
            if !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.system(size: 18))
                    .lineSpacing(18 * 0.45 - 5)
                    .textSelection(.enabled)
            }
            if !points.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Key points")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(points) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("•").font(.system(size: 17))
                                Text(verbatim: point.text).font(.system(size: 17)).lineSpacing(17 * 0.4 - 5)
                            }
                            .padding(.leading, 6)
                        }
                    }
                }
            }
            if !note.actions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    heading("To do")
                    ForEach(note.actions) { action in
                        let done = record.checkedActions.contains(action.id)
                        Button { controller.toggleAction(action.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: done ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 20, weight: .light))
                                    .foregroundStyle(done ? Theme.accent : Phone.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: action.text)
                                        .font(.system(size: 17))
                                        .foregroundStyle(Theme.text)
                                        .strikethrough(done, color: Phone.secondary)
                                    if !action.speaker.isEmpty {
                                        Text(verbatim: action.speaker)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Phone.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcript(_ record: SessionRecord) -> some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            if record.turns.isEmpty {
                Text("Nothing was said.").font(.system(size: 17)).foregroundStyle(Phone.secondary)
            }
            ForEach(record.turns, id: \.id) { turn in
                VStack(alignment: .leading, spacing: 4) {
                    if !turn.speaker.isEmpty {
                        Text(verbatim: turn.speaker)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Phone.secondary)
                    }
                    Text(verbatim: turn.source)
                        .font(Theme.body(record.direction.source, size: 15))
                        .foregroundStyle(Phone.secondary)
                    if !turn.translation.isEmpty {
                        Text(verbatim: turn.translation)
                            .font(Theme.body(record.direction.target, size: 19, weight: .medium))
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Phone.secondary)
    }
}

/// Translation, Original, Both, Summary.
private struct PhoneCopySheet: View {
    @ObservedObject var controller: SessionController
    let record: SessionRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy")
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal, 4)
                .padding(.top, 20)
            VStack(spacing: 0) {
                row("Translation", detail: record.direction.target.title, kind: .translation)
                Phone.separator.frame(height: 1).padding(.leading, 16)
                row("Original", detail: record.direction.source.title, kind: .original)
                Phone.separator.frame(height: 1).padding(.leading, 16)
                row("Both", detail: nil, kind: .bilingual)
                Phone.separator.frame(height: 1).padding(.leading, 16)
                row("Summary", detail: nil, kind: .summary)
            }
            .background(Phone.fill, in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: String, detail: String?, kind: SessionCopyKind) -> some View {
        Button {
            controller.copySession(kind)
            dismiss()
        } label: {
            HStack {
                Text(title).font(.system(size: 17)).foregroundStyle(Theme.text)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 15)).foregroundStyle(Phone.secondary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Language picker

/// "Translate from" / "Translate to": search, recent picks, then every language.
/// A download icon marks languages the system has not installed for offline use yet.
struct PhoneLanguagePicker: View {
    @ObservedObject var controller: SessionController
    let side: PhoneLanguageSide
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var needsDownload: Set<SpeechLanguage> = []
    @AppStorage("recentLanguages") private var recentRaw = ""

    private var selected: SpeechLanguage {
        side == .source ? controller.engine.direction.source : controller.engine.direction.target
    }

    private var other: SpeechLanguage {
        side == .source ? controller.engine.direction.target : controller.engine.direction.source
    }

    private var recent: [SpeechLanguage] {
        let saved = recentRaw.split(separator: ",").compactMap { SpeechLanguage(rawValue: String($0)) }
        return Array(([selected] + saved).reduce(into: [SpeechLanguage]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
    }

    private var matches: [SpeechLanguage] {
        SpeechLanguage.allCases
            .sorted { $0.title < $1.title }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.nativeName.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(side == .source ? "Translate from" : "Translate to")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(height: 52)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Phone.secondary)
                TextField("Search languages", text: $query)
                    .font(.system(size: 17))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Phone.segmentFill, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if query.isEmpty {
                        group("Recent", recent)
                    }
                    group(query.isEmpty ? "All languages" : "Results", matches)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
        }
        .presentationDragIndicator(.visible)
        .task { await checkDownloads() }
    }

    private func group(_ title: String, _ languages: [SpeechLanguage]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13))
                .kerning(0.26)
                .foregroundStyle(Phone.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(Array(languages.enumerated()), id: \.element) { index, language in
                    if index > 0 { Phone.separator.frame(height: 1).padding(.leading, 16) }
                    row(language)
                }
            }
            .background(Phone.fill, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func row(_ language: SpeechLanguage) -> some View {
        Button { pick(language) } label: {
            HStack(spacing: 8) {
                Text(language.title).font(.system(size: 17)).foregroundStyle(Theme.text)
                if language.nativeName != language.title {
                    Text(language.nativeName).font(.system(size: 15)).foregroundStyle(Phone.secondary)
                }
                Spacer(minLength: 0)
                if language == selected {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                } else if needsDownload.contains(language) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Download for offline use")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(language == selected ? .isSelected : [])
    }

    private func pick(_ language: SpeechLanguage) {
        let direction = controller.engine.direction
        if language == other {
            controller.swapDirection()
        } else if side == .source {
            controller.setDirection(TranslationDirection(source: language, target: direction.target))
        } else {
            controller.setDirection(TranslationDirection(source: direction.source, target: language))
        }
        recentRaw = ([language] + recent.filter { $0 != language }).prefix(3).map(\.rawValue).joined(separator: ",")
        dismiss()
    }

    /// Languages the system translator supports but has not downloaded for this pair.
    private func checkDownloads() async {
        let availability = LanguageAvailability()
        var missing: Set<SpeechLanguage> = []
        for language in SpeechLanguage.allCases where language != other {
            let pair = side == .source ? (language, other) : (other, language)
            let status = await availability.status(
                from: Locale.Language(identifier: pair.0.code),
                to: Locale.Language(identifier: pair.1.code)
            )
            if status == .supported { missing.insert(language) }
        }
        needsDownload = missing
    }
}
#endif
