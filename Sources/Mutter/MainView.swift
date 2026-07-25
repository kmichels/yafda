import AppKit
import Speech
import SwiftUI

// MARK: - Palette (Mutter: warm paper, soft teal, adaptive light/dark)

enum Palette {
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? dark : light
        })
    }

    /// Warm backdrop behind the sidebar and panel.
    static let shell = dynamic(
        NSColor(red: 0.962, green: 0.954, blue: 0.940, alpha: 1),
        NSColor(red: 0.125, green: 0.123, blue: 0.118, alpha: 1))
    /// The main content sheet.
    static let panel = dynamic(
        .white,
        NSColor(red: 0.168, green: 0.165, blue: 0.160, alpha: 1))
    /// Cards on the sheet.
    static let card = dynamic(
        NSColor(red: 0.972, green: 0.965, blue: 0.952, alpha: 1),
        NSColor(red: 0.208, green: 0.204, blue: 0.198, alpha: 1))
    /// The promo banner — deep calm teal in both modes.
    static let banner = dynamic(
        NSColor(red: 0.078, green: 0.153, blue: 0.146, alpha: 1),
        NSColor(red: 0.096, green: 0.176, blue: 0.168, alpha: 1))
    /// Soft seafoam tint for callout cards.
    static let tint = dynamic(
        NSColor(red: 0.886, green: 0.938, blue: 0.925, alpha: 1),
        NSColor(red: 0.157, green: 0.235, blue: 0.224, alpha: 1))
    /// Primary text / filled buttons.
    static let ink = dynamic(
        NSColor(red: 0.13, green: 0.13, blue: 0.135, alpha: 1),
        NSColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1))
    /// Text on top of an ink-filled control.
    static let onInk = dynamic(
        .white,
        NSColor(red: 0.11, green: 0.11, blue: 0.11, alpha: 1))
    static let border = dynamic(
        NSColor.black.withAlphaComponent(0.08),
        NSColor.white.withAlphaComponent(0.12))
    /// Mutter's accent: a soft teal.
    static let accent = dynamic(
        NSColor(red: 0.16, green: 0.55, blue: 0.52, alpha: 1),
        NSColor(red: 0.40, green: 0.78, blue: 0.74, alpha: 1))
}

// MARK: - Pages

enum Page: Hashable {
    case home, insights, dictionary, training, snippets, style, transforms, scratchpad
    case settings, help

    var label: String {
        switch self {
        case .home: return "Home"
        case .insights: return "Insights"
        case .dictionary: return "Dictionary"
        case .training: return "Voice Training"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .insights: return "chart.bar"
        case .dictionary: return "text.book.closed"
        case .training: return "waveform.badge.mic"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .transforms: return "wand.and.sparkles"
        case .scratchpad: return "square.and.pencil"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        }
    }

    static let mainItems: [Page] = [
        .home, .insights, .dictionary, .training, .snippets, .style, .transforms,
        .scratchpad,
    ]
    static let bottomItems: [Page] = [.settings, .help]
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var app: AppDelegate
    @State private var page: Page = .home
    @State private var showSidebar = true

    private let permissionTimer = Timer.publish(
        every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(app: app, page: $page, showSidebar: $showSidebar)
                    .frame(width: 232)
            }
            mainPanel
        }
        .background(Palette.shell)
        .ignoresSafeArea()
        .onReceive(permissionTimer) { _ in app.refreshPermissions() }
        
    }

    private var mainPanel: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.panel)
                .shadow(color: .black.opacity(0.05), radius: 3, y: 1)

            VStack(spacing: 0) {
                topBar
                ScrollView {
                    pageContent
                        .padding(.horizontal, 56)
                        .padding(.bottom, 40)
                        .frame(maxWidth: 1100, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(EdgeInsets(top: 6, leading: showSidebar ? 0 : 6, bottom: 6, trailing: 6))
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            if !showSidebar {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar = true }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 76)
            }
            Spacer()
            if let status = app.transformStatus {
                Label(status, systemImage: "wand.and.sparkles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accent)
            }
            if let error = app.lastError, app.uiState == .idle {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 460, alignment: .trailing)
            }
            RecordingPill(app: app)
            Image(systemName: "bell")
                .foregroundStyle(Palette.ink.opacity(0.75))
                .onTapGesture { page = .help }
            Image(systemName: "person.circle")
                .font(.system(size: 18))
                .foregroundStyle(Palette.ink.opacity(0.75))
                .onTapGesture { page = .settings }
        }
        .padding(.top, 18)
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .home: HomePage(app: app, page: $page)
        case .insights: InsightsPage(app: app)
        case .dictionary: DictionaryPage()
        case .training: TrainingPage(app: app)
        case .snippets: SnippetsPage()
        case .style: StylePage(app: app)
        case .transforms: TransformsPage(app: app)
        case .scratchpad: ScratchpadPage()
        case .settings: SettingsPage(app: app)
        case .help: HelpPage(app: app)
        }
    }
}

// MARK: - Recording status pill (top bar)

struct RecordingPill: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        Group {
            switch app.uiState {
            case .idle:
                EmptyView()
            case .recording:
                Label(app.isHandsFree ? "Recording — hands-free" : "Recording…",
                      systemImage: "waveform")
                    .foregroundStyle(.red)
            case .processing:
                Label("Transcribing…", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption.weight(.medium))
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @Binding var showSidebar: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSidebar = false }
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 14)
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .bold))
                Text("Mutter")
                    .font(.system(size: 22, weight: .semibold))
                Text("Local")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Palette.border, lineWidth: 1))
                Spacer()
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 22)

            VStack(spacing: 2) {
                ForEach(Page.mainItems, id: \.self) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            wordsCard
                .padding(.horizontal, 12)
                .padding(.bottom, 14)

            VStack(spacing: 2) {
                ForEach(Page.bottomItems, id: \.self) { item in
                    navRow(item, compact: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(Palette.shell)
    }

    private func navRow(_ item: Page, compact: Bool = false) -> some View {
        let selected = page == item
        return HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: compact ? 13 : 14))
                .frame(width: 20)
            Text(item.label)
                .font(.system(size: compact ? 13 : 14,
                              weight: selected ? .medium : .regular))
            Spacer()
        }
        .foregroundStyle(Palette.ink.opacity(selected ? 1 : 0.8))
        .padding(.vertical, compact ? 6 : 9)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Palette.panel : .clear)
                .shadow(color: selected ? .black.opacity(0.06) : .clear,
                        radius: 2, y: 1))
        .contentShape(Rectangle())
        .onTapGesture { page = item }
    }

    private var wordsCard: some View {
        let missingNames = [
            app.micAuthorized ? nil : "Microphone",
            app.axTrusted ? nil : "Accessibility",
        ].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 8) {
            if !missingNames.isEmpty {
                Text("\(missingNames.count) permission\(missingNames.count == 1 ? "" : "s") needed")
                    .font(.system(size: 14, weight: .semibold))
                Text("Grant \(missingNames.joined(separator: " and ")) to start dictating.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { page = .settings } label: {
                    Text("Fix now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            } else {
                Text("∞ words remaining")
                    .font(.system(size: 14, weight: .semibold))
                Text("Everything runs on-device. Unlimited, free, private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button { page = .help } label: {
                    Text("How it works")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.onInk)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var app: AppDelegate
    @Binding var page: Page
    @State private var searchText = ""
    @State private var searchOpen = false
    @State private var showClearConfirm = false
    @State private var hoveredRow: String?
    @State private var editingEntry: HistoryEntry?
    @State private var editText = ""
    @State private var learnFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Welcome back, \(firstName)")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 24) {
                    banner
                    historyFeed
                }
                VStack(spacing: 16) {
                    statsCard
                    voiceProfileCard
                }
                .frame(width: 300)
            }
        }
        .sheet(item: $editingEntry) { entry in
            VStack(alignment: .leading, spacing: 14) {
                Label("Correct this transcript", systemImage: "pencil")
                    .font(.headline)
                Text("Fix what Mutter misheard. It compares your fix with the " +
                     "original and learns the corrections for future dictations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(width: 460, height: 140)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
                HStack {
                    Spacer()
                    Button("Cancel") { editingEntry = nil }
                    Button("Save & Learn") {
                        let outcome = app.correctHistoryEntry(
                            id: entry.id, newText: editText)
                        learnFeedback = outcome.summary
                        editingEntry = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private var firstName: String {
        NSFullUserName().components(separatedBy: " ").first ?? "there"
    }

    // MARK: Banner

    private var banner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Palette.banner)
            HStack {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 150, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Palette.accent.opacity(0.55), .white.opacity(0.12)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(.trailing, 40)
            }
            VStack(alignment: .leading, spacing: 10) {
                (Text("Make Mutter sound like ")
                    + Text("you").italic())
                    .font(.system(size: 32, design: .serif))
                    .foregroundStyle(.white)
                Text("Teach it your names, jargon and spellings.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                Button { page = .training } label: {
                    Text("Start now")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(.white.opacity(0.35), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
        .frame(height: 224)
    }

    // MARK: Stats

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            statRow(compactNumber(totalWords), "total words")
            statRow(wpmText, "wpm")
            statRow("\(dayStreak)", "day streak")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func statRow(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(value)
                .font(.system(size: 32, design: .serif))
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }

    private var totalWords: Int {
        app.entries.reduce(0) { $0 + $1.wordCount }
    }

    private var wpmText: String {
        let timed = app.entries.filter { ($0.duration ?? 0) > 1 }
        let seconds = timed.reduce(0.0) { $0 + ($1.duration ?? 0) }
        guard seconds > 0 else { return "—" }
        let words = timed.reduce(0) { $0 + $1.wordCount }
        return "\(Int(Double(words) / (seconds / 60)))"
    }

    private var dayStreak: Int {
        let calendar = Calendar.current
        let days = Set(app.entries.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return streak
    }

    private func compactNumber(_ number: Int) -> String {
        number >= 1000
            ? String(format: "%.1fK", Double(number) / 1000)
            : "\(number)"
    }

    // MARK: Voice profile card

    private var voiceProfileCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Voice Profile")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                    .textCase(.uppercase)
                if let profile = app.voiceProfile {
                    Text(profile.title)
                        .font(.system(size: 22, design: .serif))
                    if !profile.summary.isEmpty {
                        Text(profile.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Still listening…")
                        .font(.system(size: 22, design: .serif))
                    Text("Dictate a bit more and Mutter will sketch your " +
                         "persona from what you talk about.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text((Locale.current.localizedString(
                    forIdentifier: app.localeID) ?? app.localeID)
                    + " · Hold \(app.hotkey.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text("Click to train your pronunciation")
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 12) {
                Image(systemName: "figure.wave")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Palette.accent)
                if app.voiceProfile != nil {
                    Button {
                        app.refreshVoiceProfileIfDue(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh profile from your latest dictations")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { page = .training }
    }

    // MARK: History feed

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return app.entries }
        return app.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [(title: String, items: [HistoryEntry])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredEntries) {
            calendar.startOfDay(for: $0.date)
        }
        return groups.keys.sorted(by: >).map { day in
            (dayLabel(day), groups[day]!.sorted { $0.date > $1.date })
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide).month().day()).uppercased()
    }

    private var historyFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let feedback = learnFeedback {
                Label(feedback, systemImage: "graduationcap")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.accent)
                    .task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        learnFeedback = nil
                    }
            }
            if app.entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "mic")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No transcripts yet")
                        .font(.headline)
                    Text("Click into any text field, hold \(app.hotkey.displayName), " +
                         "and speak. Your dictations will show up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    HStack {
                        Text(section.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .kerning(0.8)
                        Spacer()
                        if index == 0 {
                            if searchOpen {
                                TextField("Search transcripts", text: $searchText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 240)
                            }
                            Button {
                                searchOpen.toggle()
                                if !searchOpen { searchText = "" }
                            } label: {
                                Image(systemName: searchOpen
                                    ? "xmark.circle" : "magnifyingglass")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            Button {
                                showClearConfirm = true
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear all history")
                            .confirmationDialog(
                                "Clear all history?", isPresented: $showClearConfirm) {
                                Button("Clear History", role: .destructive) {
                                    app.clearHistoryEntries()
                                }
                            } message: {
                                Text("This permanently deletes all \(app.entries.count) " +
                                     "saved transcripts. This can't be undone.")
                            }
                        }
                    }
                    .padding(.top, index == 0 ? 0 : 14)

                    VStack(spacing: 0) {
                        ForEach(section.items) { entry in
                            historyRow(entry)
                            if entry != section.items.last {
                                Divider().opacity(0.6)
                            }
                        }
                    }
                    .background(Palette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Palette.border, lineWidth: 1))
                }
            }
        }
    }

    /// One line summarising which LearnedStore rules fired on this
    /// transcript, e.g. `“Konrad” → “laptop” ×2`. Mirrors the curly-quote /
    /// arrow convention `LearnOutcome.summary` uses for the same kind of
    /// correction, and the `×N` convention the Training page uses for
    /// repeat counts.
    private func appliedCorrectionsCaption(_ corrections: [AppliedCorrection]) -> String {
        corrections.map { correction in
            let mapping = "“\(correction.heard)” → “\(correction.intended)”"
            return correction.count > 1 ? "\(mapping) ×\(correction.count)" : mapping
        }.joined(separator: ", ")
    }

    private func historyRow(_ entry: HistoryEntry) -> some View {
        let hovered = hoveredRow == entry.id
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 14))
                    .lineLimit(2)
                if let corrections = entry.appliedCorrections, !corrections.isEmpty {
                    Text(appliedCorrectionsCaption(corrections))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovered {
                HStack(spacing: 14) {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(entry.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy")
                    Button {
                        editText = entry.text
                        editingEntry = entry
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .help("Correct — Mutter learns from your fix")
                    Button {
                        app.deleteHistoryEntry(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(hovered ? Color.black.opacity(0.025) : .clear)
        .onHover { inside in
            hoveredRow = inside ? entry.id : (hoveredRow == entry.id ? nil : hoveredRow)
        }
    }
}

// MARK: - Insights

struct InsightsPage: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Insights")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            HStack(spacing: 16) {
                tile("\(app.entries.count)", "dictations")
                tile(compact(totalWords), "total words")
                tile(avgWords, "avg words / dictation")
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Words per day — last 7 days")
                    .font(.headline)
                chart
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var totalWords: Int {
        app.entries.reduce(0) { $0 + $1.wordCount }
    }

    private var avgWords: String {
        app.entries.isEmpty ? "—" : "\(totalWords / app.entries.count)"
    }

    private func compact(_ number: Int) -> String {
        number >= 1000
            ? String(format: "%.1fK", Double(number) / 1000)
            : "\(number)"
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 32, design: .serif))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var last7Days: [(day: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let words = app.entries
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .reduce(0) { $0 + $1.wordCount }
            return (day, words)
        }
    }

    private var chart: some View {
        let data = last7Days
        let maxWords = max(data.map(\.words).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(data, id: \.day) { point in
                VStack(spacing: 6) {
                    Text(point.words > 0 ? "\(point.words)" : "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(point.words > 0 ? Palette.accent : Palette.border)
                        .frame(height: max(6,
                            CGFloat(point.words) / CGFloat(maxWords) * 140))
                    Text(point.day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 190, alignment: .bottom)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @State private var entries: [VocabularyEntry] = []
    @State private var newWord = ""
    @State private var newMisheard = ""
    @State private var correctingMisspelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictionary")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Add names, jargon and terms you use so Mutter spells them your " +
                 "way. A plain word biases recognition. Turn on \u{201C}Correct a " +
                 "misspelling\u{201D} to also replace a form it keeps hearing wrong.")
                .foregroundStyle(.secondary)

            // Add-new card.
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to vocabulary").font(.headline)
                Toggle("Correct a misspelling", isOn: $correctingMisspelling)
                    .toggleStyle(.switch)
                HStack {
                    if correctingMisspelling {
                        TextField("misheard as", text: $newMisheard)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    }
                    TextField("word or name", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            // Existing entries.
            VStack(spacing: 8) {
                ForEach($entries) { $entry in
                    HStack {
                        Text(entry.word)
                        if let misheard = entry.misheard, !misheard.isEmpty {
                            Text("\u{2190} \(misheard)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            entries.removeAll { $0.id == entry.id }
                            VocabularyStore.save(entries)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { entries = VocabularyStore.load() }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let misheard = correctingMisspelling
            ? newMisheard.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let normalizedMisheard = misheard.isEmpty ? nil : misheard
        // Reject only an exact duplicate of the (word, misheard) pair, so a user
        // can still map two different misheard forms ("focus", "pocus") to the
        // same word, while a true repeat is not accumulated in the file.
        let isDuplicate = entries.contains {
            $0.word.lowercased() == word.lowercased()
                && $0.misheard?.lowercased() == normalizedMisheard?.lowercased()
        }
        guard !isDuplicate else {
            newWord = ""
            newMisheard = ""
            correctingMisspelling = false
            return
        }
        entries.append(VocabularyEntry(word: word, misheard: normalizedMisheard))
        VocabularyStore.save(entries)
        newWord = ""
        newMisheard = ""
        correctingMisspelling = false
    }
}

// MARK: - Scratchpad

struct ScratchpadPage: View {
    @State private var text = ""

    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("scratchpad.txt")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Scratchpad")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("A place to park text. Saved automatically.")
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(16)
                .frame(minHeight: 380)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }
        .onChange(of: text) { _, newValue in
            try? newValue.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var supportedLocaleIDs: [String] = []
    // Shared, not @StateObject: AudioRecorder must be able to make this exact
    // instance yield the device before it starts recording.
    @ObservedObject private var micMonitor = MicMonitor.shared
    // @AppStorage, not @State: a @State copy seeded from Settings silently
    // diverges if the preference changes anywhere else.
    @AppStorage("inputDeviceUID") private var inputDeviceUID: String?
    // Held in state and refreshed on hardware changes: reading
    // AudioDevices.inputDevices() inline would leave the picker stale when a
    // microphone is plugged in or removed while this view is open.
    @State private var devices: [AudioInputDevice] = AudioDevices.inputDevices()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                Text("Permissions").font(.headline)
                permissionRow(
                    granted: app.micAuthorized,
                    title: "Microphone",
                    detail: "Required to hear your dictation.",
                    pane: "Privacy_Microphone")
                Divider()
                permissionRow(
                    granted: app.axTrusted,
                    title: "Accessibility",
                    detail: "Required for the global hotkey and pasting. " +
                            "Relaunch Mutter after granting.",
                    pane: "Privacy_Accessibility")
                if !app.axTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Toggle on in System Settings but still red here? " +
                             "The saved grant belongs to an older build. Click " +
                             "Reset Grant — the app relaunches, macOS asks once " +
                             "more, and the new grant sticks for all future updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Grant & Relaunch") {
                            app.resetAccessibilityGrant()
                        }
                        Button("Relaunch") { app.relaunch() }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            microphoneCard

            VStack(alignment: .leading, spacing: 12) {
                Text("Dictation").font(.headline)
                HStack {
                    Text("Dictation key")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.hotkey },
                        set: { app.setHotkey($0) })) {
                        ForEach(HotkeyMonitor.Hotkey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Space after each dictation")
                        Text("Leaves the cursor one space past the last " +
                             "character, so the next sentence doesn't run " +
                             "into this one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { Settings.appendTrailingSpace },
                        set: { Settings.appendTrailingSpace = $0 }))
                        .labelsHidden()
                }
                Divider()
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.localeID },
                        set: { app.setLocale($0) })) {
                        ForEach(pickerLocaleIDs, id: \.self) { identifier in
                            Text(Locale.current.localizedString(
                                forIdentifier: identifier) ?? identifier)
                                .tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recognition engine")
                        Text(app.engine == "whisper"
                            ? "Whisper: best accuracy on accents and jargon; " +
                              "your vocabulary is fed to the model. Runs locally."
                            : "Apple: instant, built into macOS. Runs locally.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.engine },
                        set: { app.setEngine($0) })) {
                        Text("Apple — instant").tag("apple")
                        Text("Whisper — precise").tag("whisper")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Context correction")
                        Text("Uses an on-device LLM to fix homophones toward your " +
                             "dictionary (e.g. focus \u{2192} Phocus) from sentence " +
                             "context. On-device is experimental and unreliable on " +
                             "macOS 26; Private Cloud Compute needs macOS 27.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { Settings.disambiguationEngine },
                        set: { Settings.disambiguationEngine = $0 })) {
                        ForEach(DisambiguationEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if app.engine == "whisper" {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whisper model")
                            Text(app.whisperReady
                                ? "Model loaded — Whisper is transcribing your dictations."
                                : app.whisperEngine.isModelDownloaded(app.whisperModel)
                                    ? "Model downloaded — loading. Apple engine covers " +
                                      "dictations until it's ready."
                                    : "Downloading in the background. Apple engine covers " +
                                      "dictations until it's ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.whisperModel },
                            set: { app.setWhisperModel($0) })) {
                            ForEach(WhisperEngine.availableModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear(perform: loadLocales)
    }

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Microphone").font(.headline)
            Text("Mutter records from the system default unless you choose a device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Input", selection: $inputDeviceUID) {
                Text("System default").tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            .labelsHidden()
            .onChange(of: inputDeviceUID) { _, newValue in
                // @AppStorage already persisted it; just re-point the meter.
                micMonitor.stop()
                micMonitor.start(deviceUID: newValue)
            }

            // The picker alone cannot tell you the device is working.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(micMonitor.level))
                    .progressViewStyle(.linear)
                Text("Say something — the bar should move.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let chosen = inputDeviceUID, !devices.contains(where: { $0.uid == chosen }) {
                Label("That microphone isn't connected. Using the system default.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            devices = AudioDevices.inputDevices()
            micMonitor.viewAppeared(deviceUID: inputDeviceUID)
        }
        .onDisappear { micMonitor.viewDisappeared() }
        .onReceive(NotificationCenter.default.publisher(
            for: .AVAudioEngineConfigurationChange)) { _ in
            devices = AudioDevices.inputDevices()
        }
    }

    private var pickerLocaleIDs: [String] {
        var ids = supportedLocaleIDs
        if !ids.contains(app.localeID) {
            ids.insert(app.localeID, at: 0)
        }
        return ids
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = locales
                .map { $0.identifier(.bcp47) }
                .sorted {
                    (Locale.current.localizedString(forIdentifier: $0) ?? $0)
                    < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
                }
        }
    }

    private func permissionRow(
        granted: Bool, title: String, detail: String, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
                    let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - Help

struct HelpPage: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Help")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 14) {
                helpRow("hand.tap", "Push-to-talk",
                    "Click into any text field, hold \(app.hotkey.displayName), speak, " +
                    "release. The cleaned-up text is pasted at your cursor.")
                Divider()
                helpRow("hands.and.sparkles", "Hands-free",
                    "Double-tap \(app.hotkey.displayName) to keep recording without " +
                    "holding. Tap once to stop.")
                Divider()
                helpRow("text.insert", "Voice commands",
                    "Say “new line” or “new paragraph” to add line breaks. " +
                    "Punctuation is added automatically from your pauses and tone.")
                Divider()
                helpRow("lock.shield", "Private by design",
                    "Recognition runs entirely on this Mac using Apple's on-device " +
                    "speech model. No audio or text ever leaves your machine.")
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func helpRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @State private var snippets: [Snippet] = []
    @State private var newTrigger = ""
    @State private var newExpansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Snippets")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Say the trigger phrase while dictating and the whole block is " +
                 "inserted instead — signatures, addresses, meeting links, " +
                 "canned replies.")
                .foregroundStyle(.secondary)

            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(Palette.accent)
                        TextField("trigger phrase (what you say)",
                                  text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    TextEditor(text: $snippet.expansion)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 64)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                        .onChange(of: snippet.expansion) { _, _ in save() }
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add new").font(.headline)
                TextField("trigger phrase (what you say)", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newExpansion)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 64)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Add snippet") {
                        snippets.append(Snippet(
                            trigger: newTrigger.trimmingCharacters(in: .whitespaces),
                            expansion: newExpansion))
                        newTrigger = ""
                        newExpansion = ""
                        save()
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                              || newExpansion.isEmpty)
                }
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { snippets = SnippetStore.load() }
    }

    private func save() {
        SnippetStore.save(snippets.filter {
            !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty
        })
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var app: AppDelegate
    @State private var defaultStyle: WritingStyle = StyleSettings.defaultStyle
    @State private var overrides: [String: AppStyleRule] = StyleSettings.overrides
    @State private var pickedBundleID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Style")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Mutter adapts your tone to where you're writing — formal in docs, " +
                 "casual in chat. Rewriting runs on-device with Apple Intelligence.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Default style").font(.headline)
                Text("Used in every app unless overridden below.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $defaultStyle) {
                    ForEach(WritingStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: defaultStyle) { _, newValue in
                    StyleSettings.defaultStyle = newValue
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Per-app styles").font(.headline)
                if overrides.isEmpty {
                    Text("No app rules yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(overrides.sorted(by: { $0.value.appName < $1.value.appName }),
                        id: \.key) { bundleID, rule in
                    HStack {
                        Text(rule.appName)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { rule.style },
                            set: { newStyle in
                                overrides[bundleID] = AppStyleRule(
                                    appName: rule.appName, style: newStyle)
                                StyleSettings.overrides = overrides
                            })) {
                            ForEach(WritingStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            overrides.removeValue(forKey: bundleID)
                            StyleSettings.overrides = overrides
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
                HStack {
                    Picker("", selection: $pickedBundleID) {
                        Text("Choose a running app…").tag("")
                        ForEach(runningApps, id: \.bundleID) { appInfo in
                            Text(appInfo.name).tag(appInfo.bundleID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add rule") {
                        guard let appInfo = runningApps.first(
                            where: { $0.bundleID == pickedBundleID }) else { return }
                        overrides[appInfo.bundleID] = AppStyleRule(
                            appName: appInfo.name, style: .casual)
                        StyleSettings.overrides = overrides
                        pickedBundleID = ""
                    }
                    .disabled(pickedBundleID.isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var runningApps: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Transforms

struct TransformsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var tryText = ""
    @State private var result = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Transforms")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Select text in any app, press the shortcut, and it's rewritten " +
                 "in place — on-device.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Transform.all) { transform in
                    HStack(alignment: .top) {
                        Text(transform.keyLabel)
                            .font(.system(size: 13, weight: .semibold,
                                          design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.panel,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Palette.border, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transform.name).font(.body.weight(.medium))
                            Text(transform.description)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if transform.id != Transform.all.last?.id {
                        Divider()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 10) {
                Text("Try it here").font(.headline)
                TextEditor(text: $tryText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 70)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    ForEach(Transform.all) { transform in
                        Button(transform.name) { runTransform(transform) }
                            .disabled(running || tryText.isEmpty
                                      || !app.rewriteEngine.isAvailable)
                    }
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !result.isEmpty {
                    Text(result)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func runTransform(_ transform: Transform) {
        running = true
        result = ""
        Task {
            defer { running = false }
            do {
                result = try await app.transformManager.apply(transform, to: tryText)
            } catch {
                result = "Failed: \(error.localizedDescription)"
            }
        }
    }
}


// MARK: - Voice Training

/// Records a short sample, shows what the model heard, and saves the
/// misheard → intended mapping so Mutter learns the user's pronunciation.
@MainActor
final class TrainingModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var heard: String?
    @Published var result: String?

    private let recorder = AudioRecorder()

    func toggle(app: AppDelegate, target: String) {
        if isRecording {
            stop(app: app, target: target)
        } else {
            start()
        }
    }

    private func start() {
        heard = nil
        result = nil
        do {
            try recorder.start()
            isRecording = true
            NSSound(named: "Pop")?.play()
        } catch {
            result = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stop(app: AppDelegate, target: String) {
        isRecording = false
        guard let url = recorder.stop() else { return }
        NSSound(named: "Tink")?.play()
        isProcessing = true
        Task {
            defer {
                isProcessing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let raw = try await app.transcribeRaw(fileAt: url)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                heard = cleaned.isEmpty ? nil : cleaned
                let intended = target.trimmingCharacters(in: .whitespaces)
                guard let heardText = heard else {
                    result = "Nothing was heard — try again, a bit louder."
                    return
                }
                if heardText.lowercased() == intended.lowercased() {
                    LearnedStore.addTerm(intended)
                    result = "Recognized correctly! Added “\(intended)” to your " +
                             "vocabulary so it stays reliable."
                } else if LearnedStore.add(heard: heardText, intended: intended) {
                    result = "Learned: “\(heardText)” → “\(intended)”. Mutter will " +
                             "make this correction automatically from now on."
                } else {
                    result = "Heard “\(heardText)” for “\(intended)” — too common to " +
                             "rewrite automatically, so Mutter will just expect " +
                             "“\(intended)” when listening."
                }
            } catch {
                result = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }
}

struct TrainingPage: View {
    @ObservedObject var app: AppDelegate
    @StateObject private var model = TrainingModel()
    @State private var target = ""
    @State private var learned = LearnedStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voice Training")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Teach Mutter how you pronounce names and jargon. Type a word, " +
                 "say it, and Mutter learns what it hears from you — the mapping " +
                 "is applied to every future dictation, and the word is fed to " +
                 "the speech model as expected vocabulary.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("Teach a word or phrase").font(.headline)
                HStack(spacing: 10) {
                    TextField("word or phrase, e.g. “Søren” or “Baseten”",
                              text: $target)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.toggle(app: app, target: target)
                    } label: {
                        Label(model.isRecording ? "Stop" : "Record",
                              systemImage: model.isRecording
                                ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundStyle(model.isRecording ? .red : Palette.accent)
                    }
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isProcessing || !app.micAuthorized)
                    if model.isProcessing {
                        ProgressView().controlSize(.small)
                    }
                }
                if model.isRecording {
                    Label("Say “\(target)” now, then press Stop.",
                          systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let result = model.result {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(Palette.accent)
                        // onAppear alone only fires once: the Text view stays in
                        // the hierarchy across a second training attempt while
                        // this page is visible, so onAppear never re-fires and
                        // both lists below go stale. onChange catches that case.
                        .onAppear { learned = LearnedStore.load() }
                        .onChange(of: model.result) { _, _ in learned = LearnedStore.load() }
                }
                Text("Tip: repeat a word 2–3 times — different mishearings each " +
                     "become their own correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Learned corrections").font(.headline)
                Text("Also learned automatically when you fix a transcript in " +
                     "History (pencil icon).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if learned.corrections.isEmpty {
                    Text("Nothing learned yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(learned.corrections.reversed()) { correction in
                        HStack {
                            Text("“\(correction.heard)”")
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text("“\(correction.intended)”")
                                .fontWeight(.medium)
                            if correction.timesSeen > 1 {
                                Text("×\(correction.timesSeen)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                var data = LearnedStore.load()
                                data.corrections.removeAll { $0.id == correction.id }
                                LearnedStore.save(data)
                                learned = data
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 13))
                        Divider()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            VStack(alignment: .leading, spacing: 12) {
                Text("Trained words").font(.headline)
                Text("Fed to the speech model as expected vocabulary, even when " +
                     "no mishearing needed correcting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if learned.terms.isEmpty {
                    Text("Nothing trained yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(learned.terms.reversed(), id: \.self) { term in
                        HStack {
                            Text("“\(term)”")
                                .fontWeight(.medium)
                            Spacer()
                            Button {
                                LearnedStore.removeTerm(term)
                                learned = LearnedStore.load()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 13))
                        Divider()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { learned = LearnedStore.load() }
    }
}
