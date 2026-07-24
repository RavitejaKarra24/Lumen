import SwiftUI

struct IntelligenceView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedFilter: InsightKind? = nil

    var body: some View {
        @Bindable var appState = appState
        let intel = appState.intelligence

        VStack(spacing: 0) {
            header(intel: intel)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = intel.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    metricsRow(intel: intel)
                    learningCard(intel: intel)
                    interestsCard(intel: intel)
                    classifiedCard
                    ideasAndActions(intel: intel)
                    capturesCard(intel: intel)
                }
                .padding(24)
            }
        }
        .navigationTitle("Intelligence")
        .onAppear {
            if intel.report(for: appState.selectedDay) == nil {
                Task { await appState.runIntelligence(for: appState.selectedDay) }
            }
        }
    }

    private func header(intel: IntelligenceService) -> some View {
        @Bindable var appState = appState
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Intelligence")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle(intel: intel))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            DayPickerBar(day: $appState.selectedDay) { day in
                appState.selectDay(day)
                Task { await appState.runIntelligence(for: day) }
            }
            Button {
                Task { await appState.runIntelligence(for: appState.selectedDay) }
            } label: {
                if intel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Label("Analyze", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(intel.isRunning)
        }
        .padding(20)
    }

    private func subtitle(intel: IntelligenceService) -> String {
        if intel.isRunning {
            return intel.progressLabel.isEmpty ? "Working…" : intel.progressLabel
        }
        if let at = intel.lastRunAt {
            let f = DateFormatter()
            f.timeStyle = .short
            return "Last analyzed \(f.string(from: at))"
        }
        return "Content capture · classification · interests · ideas"
    }

    private func metricsRow(intel: IntelligenceService) -> some View {
        let report = intel.report(for: appState.selectedDay)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            MetricCard(
                title: "Interests",
                value: "\(report?.interests.count ?? 0)",
                subtitle: "Repeated themes",
                symbol: "sparkles",
                accent: .purple
            )
            MetricCard(
                title: "Actions",
                value: "\(report?.actionItems.count ?? appState.actionInsights.count)",
                subtitle: "Extracted next steps",
                symbol: "checklist",
                accent: .orange
            )
            MetricCard(
                title: "Ideas",
                value: "\(report?.ideas.count ?? appState.ideaInsights.count)",
                subtitle: "Captured sparks",
                symbol: "lightbulb.fill",
                accent: .yellow
            )
            MetricCard(
                title: "Captured",
                value: "\(report?.capturedContentCount ?? 0)",
                subtitle: "\(report?.transcriptCount ?? 0) transcripts",
                symbol: "doc.text.magnifyingglass",
                accent: .cyan
            )
        }
    }

    private func learningCard(intel: IntelligenceService) -> some View {
        let body = intel.report(for: appState.selectedDay)?.learningSummary
            ?? appState.insights.first(where: { $0.kind == .learningSummary })?.body
            ?? "Run Analyze to generate today’s learning summary."

        return VStack(alignment: .leading, spacing: 12) {
            Label("Learning summary", systemImage: "graduationcap.fill")
                .font(.headline)
            Text(body)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(cardBackground)
    }

    private func interestsCard(intel: IntelligenceService) -> some View {
        let interests = intel.report(for: appState.selectedDay)?.interests ?? appState.insights.filter { $0.kind == .interest }.map {
            InterestSignal(
                topic: $0.title,
                score: $0.confidence * 1000,
                duration: 0,
                occurrences: 1,
                domains: [],
                sampleTitles: $0.body.isEmpty ? [] : [$0.body]
            )
        }

        return VStack(alignment: .leading, spacing: 12) {
            Label("Repeated interests", systemImage: "sparkles")
                .font(.headline)

            if interests.isEmpty {
                Text("As you browse and work, recurring topics will cluster here.")
                    .foregroundStyle(.secondary)
            } else {
                FlowInterestChips(interests: Array(interests.prefix(16)))
                ForEach(Array(interests.prefix(6))) { interest in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(interest.topic)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text("\(interest.occurrences)×")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            if interest.duration > 0 {
                                Text(DurationFormat.compact(interest.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let sample = interest.sampleTitles.first {
                            Text(sample)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var classifiedCard: some View {
        let segments = appState.analytics?.segments.filter { !$0.isIdle } ?? []
        var counts: [SessionKind: TimeInterval] = [:]
        for segment in segments {
            counts[segment.sessionKind, default: 0] += segment.duration
        }
        let rows = counts
            .map { (kind: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
        let total = max(rows.reduce(0.0) { $0 + $1.duration }, 1)

        return VStack(alignment: .leading, spacing: 12) {
            Label("Session classification", systemImage: "brain.head.profile")
                .font(.headline)
            if rows.isEmpty {
                Text("No classified sessions yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.kind) { row in
                    UsageBarRow(
                        title: row.kind.displayName,
                        subtitle: nil,
                        duration: row.duration,
                        total: total,
                        symbol: row.kind.symbolName,
                        color: row.kind.color
                    )
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func ideasAndActions(intel: IntelligenceService) -> some View {
        let actions = appState.actionInsights
        let ideas = appState.ideaInsights

        return HStack(alignment: .top, spacing: 16) {
            insightList(
                title: "Action items",
                symbol: "checklist",
                empty: "No action items extracted yet. Add notes like “TODO: …” or “need to ship…” on sessions.",
                items: actions
            )
            insightList(
                title: "Ideas",
                symbol: "lightbulb.fill",
                empty: "Ideas appear from notes, titles, and page takeaways.",
                items: ideas
            )
        }
    }

    private func insightList(title: String, symbol: String, empty: String, items: [InsightRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            if items.isEmpty {
                Text(empty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(10)) { item in
                    InsightRow(item: item) {
                        appState.toggleInsightCompleted(item)
                    } onPin: {
                        appState.toggleInsightPinned(item)
                    } onDelete: {
                        appState.deleteInsight(item)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func capturesCard(intel: IntelligenceService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recent captures", systemImage: "doc.text")
                .font(.headline)
            let artifacts = intel.artifacts(for: appState.selectedDay)
            if artifacts.isEmpty {
                Text("Page text and video transcripts show up here after Analyze.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(artifacts.prefix(8)) { artifact in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: artifact.kind == .transcript ? "captions.bubble" : "doc.richtext")
                                .foregroundStyle(.cyan)
                            Text(artifact.title.isEmpty ? (artifact.urlString ?? "Capture") : artifact.title)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            statusChip(artifact.status)
                        }
                        if !artifact.text.isEmpty {
                            Text(artifact.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        if let err = artifact.errorMessage, artifact.status == .failed {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func statusChip(_ status: ContentStatus) -> some View {
        let label: String
        let color: Color
        switch status {
        case .ready: label = "Ready"; color = .green
        case .pending: label = "Pending"; color = .yellow
        case .failed: label = "Failed"; color = .orange
        case .skipped: label = "Skipped"; color = .secondary
        case .none: label = "None"; color = .secondary
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct InsightRow: View {
    let item: InsightRecord
    var onToggle: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(action: onPin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .font(.caption)
                    .foregroundStyle(item.isPinned ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct FlowInterestChips: View {
    let interests: [InterestSignal]

    var body: some View {
        // Simple wrapping via flexible stack approximation
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { topic in
                        Text(topic)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.purple.opacity(0.15), in: Capsule())
                            .foregroundStyle(.purple)
                    }
                }
            }
        }
    }

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var width = 0
        for interest in interests {
            let w = interest.topic.count + 4
            if width + w > 48, !current.isEmpty {
                result.append(current)
                current = [interest.topic]
                width = w
            } else {
                current.append(interest.topic)
                width += w
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension SessionKind {
    var color: Color {
        switch self {
        case .deepWork: .blue
        case .learning: .indigo
        case .research: .cyan
        case .communication: .green
        case .meeting: .mint
        case .creation: .purple
        case .distraction: .red
        case .admin: .orange
        case .idle: .gray
        case .unknown: .secondary
        }
    }
}
