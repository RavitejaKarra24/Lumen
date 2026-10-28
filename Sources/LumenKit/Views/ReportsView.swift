import AppKit
import SwiftUI

struct ReportsView: View {
    @Environment(AppState.self) private var appState

    /// What the preview pane is showing. Live and placeholder states refresh
    /// themselves when matching analytics arrives; a saved snapshot stays put
    /// until another report or day is selected.
    private enum PreviewSource: Equatable {
        case savedSnapshot
        case live
        case placeholder
    }

    @State private var previewMarkdown: String = ""
    @State private var previewSource: PreviewSource = .placeholder

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            HStack {
                Text("Reports")
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                DayPickerBar(day: $appState.selectedDay) { day in
                    appState.selectDay(day)
                    loadPreview()
                }
                Button("Generate") {
                    generateReport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasNoRawSessions)

                Menu("Export…") {
                    Button("Saved report (.md)") {
                        if let snapshot = savedSnapshot {
                            appState.exportSavedReport(snapshot, format: .markdown)
                        }
                    }
                    .disabled(savedSnapshot == nil)

                    Button("Regenerate from sessions (.md)") {
                        appState.exportReportToDownloads(format: .markdown)
                    }
                    .disabled(hasNoRawSessions)

                    Button("Sessions as CSV (.csv)") {
                        appState.exportReportToDownloads(format: .csv)
                    }
                    .disabled(hasNoRawSessions)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(hasNoRawSessions ? "Raw sessions for this day are gone; only the saved Markdown can be exported." : "")
            }
            .padding(20)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("History")
                        .font(.headline)
                        .padding(16)
                    if appState.snapshots.isEmpty {
                        Text("Generated reports will appear here.")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                        Spacer()
                    } else {
                        List(appState.snapshots) { snap in
                            Button {
                                showSnapshot(snap)
                                appState.selectDay(snap.dayStart)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dayLabel(snap.dayStart))
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text("Focus \(Int(snap.focusScore.rounded())) · \(DurationFormat.compact(snap.activeSeconds)) active")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "doc.richtext")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(minWidth: 260, idealWidth: 280)

                MarkdownPreview(text: previewMarkdown)
                    .frame(minWidth: 480)
            }
        }
        .onAppear(perform: loadPreview)
        .onChange(of: appState.selectedDay) { _, _ in
            loadPreview()
        }
        .onChange(of: appState.analyticsRevision) { _, _ in
            refreshIfLive()
        }
        .onChange(of: appState.isRefreshing) { _, _ in
            refreshIfLive()
        }
    }

    private var savedSnapshot: DailySnapshot? {
        let dayStart = Calendar.current.startOfDay(for: appState.selectedDay)
        return appState.snapshots.first { Calendar.current.isDate($0.dayStart, inSameDayAs: dayStart) }
    }

    /// Raw sessions expired after retention — a regenerated export would not
    /// match what the user is looking at.
    private var hasNoRawSessions: Bool {
        guard let analytics = appState.analytics,
              Calendar.current.isDate(analytics.dayStart, inSameDayAs: appState.selectedDay)
        else { return true }
        return analytics.segments.isEmpty
    }

    private func generateReport() {
        let day = appState.selectedDay
        Task {
            if let snap = await appState.generateReport(for: day) {
                // Guard against the user having moved to another day while the
                // report was generated.
                guard Calendar.current.isDate(day, inSameDayAs: appState.selectedDay) else { return }
                previewMarkdown = snap.markdown
                previewSource = .savedSnapshot
            }
        }
    }

    private func showSnapshot(_ snap: DailySnapshot) {
        previewMarkdown = snap.markdown
        previewSource = .savedSnapshot
    }

    private func loadPreview() {
        if let snapshot = savedSnapshot {
            previewMarkdown = snapshot.markdown
            previewSource = .savedSnapshot
            return
        }
        previewSource = .live
        if let analytics = appState.analytics,
           Calendar.current.isDate(analytics.dayStart, inSameDayAs: appState.selectedDay) {
            previewMarkdown = ReportGenerator.markdown(for: analytics)
        } else if appState.isRefreshing {
            previewMarkdown = "_Loading this day’s activity…_"
            previewSource = .placeholder
        } else {
            previewMarkdown = "_No data for this day yet._"
            previewSource = .placeholder
        }
    }

    /// Live and loading previews follow analytics updates; a stored snapshot
    /// must not be replaced by a background refresh.
    private func refreshIfLive() {
        guard previewSource != .savedSnapshot else { return }
        loadPreview()
    }

    private func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: date)
    }
}

struct MarkdownPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Markdown")
                    .font(.headline)
                Spacer()
                Button {
                    copy()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(text.isEmpty)
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
