import AppKit
import SwiftUI

struct ReportsView: View {
    @Environment(AppState.self) private var appState
    @State private var previewMarkdown: String = ""

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
                    let day = appState.selectedDay
                    Task {
                        if let snap = await appState.generateReport(for: day) {
                            previewMarkdown = snap.markdown
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                Menu("Export…") {
                    Button("Markdown (.md)") {
                        appState.exportReportToDownloads(format: .markdown)
                    }
                    Button("Sessions as CSV (.csv)") {
                        appState.exportReportToDownloads(format: .csv)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
                                previewMarkdown = snap.markdown
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
        .onChange(of: appState.analytics?.activeDuration) { _, _ in
            // Keep live preview fresh when not looking at a stored snapshot exclusively.
            if previewMarkdown.isEmpty {
                loadPreview()
            }
        }
    }

    private func loadPreview() {
        let dayStart = Calendar.current.startOfDay(for: appState.selectedDay)
        if let existing = appState.snapshots.first(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: dayStart) }) {
            previewMarkdown = existing.markdown
            return
        }
        if let analytics = appState.analytics,
           Calendar.current.isDate(analytics.dayStart, inSameDayAs: dayStart) {
            previewMarkdown = ReportGenerator.markdown(for: analytics)
        } else if appState.isRefreshing {
            previewMarkdown = "_Loading this day’s activity…_"
        } else {
            previewMarkdown = "_No data for this day yet._"
        }
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
