import SwiftUI

struct ActivityTimelineView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedSegmentID: UUID?
    @State private var tagDraft = ""
    @State private var notesDraft = ""
    @State private var hideIdle = true

    private var selectedSegment: ActivitySegment? {
        guard let selectedSegmentID else { return nil }
        return appState.analytics?.segments.first(where: { $0.id == selectedSegmentID })
    }

    var body: some View {
        @Bindable var appState = appState

        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Timeline")
                        .font(.largeTitle.weight(.semibold))
                    Spacer()
                    Toggle("Hide idle", isOn: $hideIdle)
                        .toggleStyle(.checkbox)
                    DayPickerBar(day: $appState.selectedDay) { appState.selectDay($0) }
                }
                .padding(20)

                Divider()

                if let analytics = appState.analytics {
                    let segments = analytics.segments.filter { hideIdle ? !$0.isIdle : true }
                    if segments.isEmpty {
                        EmptyStateView(
                            symbol: "timeline.selection",
                            title: "No activity yet",
                            message: "As you use your Mac, sessions will appear here for tagging and review."
                        )
                    } else {
                        DayStrip(
                            analytics: analytics,
                            selection: $selectedSegmentID
                        )
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)

                        Divider()

                        List(segments, selection: $selectedSegmentID) { segment in
                            TimelineRow(segment: segment)
                                .tag(segment.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                        .listStyle(.inset)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480)

            detailPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
        }
        // Kept outside the list so it still fires when the list is not on screen.
        .onChange(of: selectedSegmentID) { previous, newValue in
            // Don't discard an edit just because the user clicked another session.
            commitNotes(for: previous)
            tagDraft = ""
            notesDraft = newValue
                .flatMap { id in appState.analytics?.segments.first(where: { $0.id == id }) }?
                .notes ?? ""
        }
        .onDisappear { commitNotes(for: selectedSegmentID) }
        .onAppear {
            if selectedSegmentID == nil {
                selectedSegmentID = appState.analytics?.segments.first(where: { !$0.isIdle })?.id
                notesDraft = selectedSegment?.notes ?? ""
            }
        }
    }

    /// Saves the pending note draft if it actually differs from what is stored.
    private func commitNotes(for segmentID: UUID?) {
        guard let segmentID,
              let segment = appState.analytics?.segments.first(where: { $0.id == segmentID }),
              segment.notes != notesDraft
        else { return }
        appState.setNotes(notesDraft, for: segmentID)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let segment = selectedSegment {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Session")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(segment.appName)
                            .font(.title2.weight(.semibold))
                        HStack(spacing: 8) {
                            CategoryBadge(category: segment.category)
                            SessionKindBadge(kind: segment.sessionKind)
                        }
                        Text(timeRange(segment))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(DurationFormat.compact(segment.duration))
                            .font(.title3.monospacedDigit())
                    }

                    if let url = segment.urlString {
                        group("URL") {
                            Text(url)
                                .font(.callout)
                                .textSelection(.enabled)
                                .foregroundStyle(.blue)
                        }
                    }

                    if !segment.windowTitle.isEmpty {
                        group("Window") {
                            Text(segment.windowTitle)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }

                    if !segment.topics.isEmpty {
                        group("Topics") {
                            Text(segment.topics.joined(separator: " · "))
                                .font(.callout)
                                .foregroundStyle(.purple)
                        }
                    }

                    if let summary = segment.contentSummary, !summary.isEmpty {
                        group("Captured summary") {
                            Text(summary)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    } else if segment.contentStatus == .ready || segment.contentStatus == .failed || segment.contentStatus == .pending {
                        group("Content") {
                            Text(segment.contentStatus.rawValue.capitalized)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    group("Tags") {
                        FlowTags(tags: segment.tags) { tag in
                            appState.removeTag(tag, from: segment.id)
                        }
                        HStack {
                            TextField("Add tag…", text: $tagDraft)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addTag(to: segment) }
                            Button("Add") { addTag(to: segment) }
                                .disabled(tagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    group("Notes") {
                        TextEditor(text: $notesDraft)
                            .font(.body)
                            .frame(minHeight: 100)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        Button("Save notes") {
                            appState.setNotes(notesDraft, for: segment.id)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            EmptyStateView(
                symbol: "tag",
                title: "Select a session",
                message: "Pick a timeline block to add tags and notes."
            )
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timeRange(_ segment: ActivitySegment) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let end = segment.endAt ?? .now
        return "\(f.string(from: segment.startAt)) – \(f.string(from: end))"
    }

    private func addTag(to segment: ActivitySegment) {
        let value = tagDraft
        appState.addTag(value, to: segment.id)
        tagDraft = ""
    }
}

/// A proportional 24-hour view of the day: where the time actually went, at a glance.
struct DayStrip: View {
    let analytics: DayAnalytics
    @Binding var selection: UUID?

    private let trackHeight: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Day at a glance")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !analytics.deepWorkBlocks.isEmpty {
                    Label(
                        "\(analytics.deepWorkBlocks.count) deep-work block\(analytics.deepWorkBlocks.count == 1 ? "" : "s")",
                        systemImage: "brain.head.profile"
                    )
                    .font(.caption)
                    .foregroundStyle(.blue)
                }
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))

                    // Deep-work blocks sit behind the segments as a soft band.
                    ForEach(analytics.deepWorkBlocks) { block in
                        let frame = span(block.start, block.end, width: width)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.16))
                            .frame(width: frame.width, height: trackHeight)
                            .offset(x: frame.x)
                    }

                    ForEach(analytics.segments) { segment in
                        let frame = span(segment.startAt, segment.endAt ?? .now, width: width)
                        if frame.width > 0.5 {
                            Rectangle()
                                .fill(color(for: segment))
                                .frame(width: frame.width, height: segment.isIdle ? 8 : trackHeight)
                                .offset(x: frame.x, y: segment.isIdle ? trackHeight - 8 : 0)
                                .overlay(alignment: .leading) {
                                    if segment.id == selection {
                                        Rectangle()
                                            .stroke(Color.primary, lineWidth: 1.5)
                                            .frame(width: max(2, frame.width), height: trackHeight)
                                            .offset(x: frame.x)
                                    }
                                }
                                .onTapGesture { selection = segment.id }
                                .help(tooltip(for: segment))
                        }
                    }

                    // Hour ticks every three hours.
                    ForEach(Array(stride(from: 0, through: 24, by: 3)), id: \.self) { hour in
                        Rectangle()
                            .fill(Color.primary.opacity(0.12))
                            .frame(width: 1, height: trackHeight)
                            .offset(x: width * CGFloat(hour) / 24)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: trackHeight)

            HStack(spacing: 0) {
                ForEach(Array(stride(from: 0, to: 24, by: 3)), id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func span(_ start: Date, _ end: Date, width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let total = analytics.dayEnd.timeIntervalSince(analytics.dayStart)
        guard total > 0 else { return (0, 0) }
        let clippedStart = max(start, analytics.dayStart)
        let clippedEnd = min(end, analytics.dayEnd)
        guard clippedEnd > clippedStart else { return (0, 0) }
        let x = CGFloat(clippedStart.timeIntervalSince(analytics.dayStart) / total) * width
        let w = CGFloat(clippedEnd.timeIntervalSince(clippedStart) / total) * width
        // Keep very short sessions visible instead of collapsing them to nothing.
        return (x, max(w, 1.5))
    }

    private func color(for segment: ActivitySegment) -> Color {
        segment.isIdle ? Color.secondary.opacity(0.35) : segment.category.color.opacity(0.85)
    }

    private func tooltip(for segment: ActivitySegment) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let label = segment.isIdle ? "Idle" : segment.displayTitle
        return "\(formatter.string(from: segment.startAt)) · \(label) · \(DurationFormat.compact(segment.duration))"
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        let date = Calendar.current.date(byAdding: .hour, value: hour, to: analytics.dayStart) ?? analytics.dayStart
        return formatter.string(from: date).lowercased()
    }
}

struct TimelineRow: View {
    let segment: ActivitySegment

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(segment.isIdle ? Color.secondary.opacity(0.4) : segment.category.color)
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(primaryLabel)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text(DurationFormat.compact(segment.duration))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(timeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !segment.isIdle {
                        SessionKindBadge(kind: segment.sessionKind)
                        CategoryBadge(category: segment.category)
                    }
                    if !segment.tags.isEmpty {
                        Text(segment.tags.prefix(3).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                if let domain = segment.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if !segment.windowTitle.isEmpty && segment.windowTitle != segment.appName {
                    Text(segment.windowTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var primaryLabel: String {
        if segment.isIdle { return "Idle" }
        return segment.appName
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let end = segment.endAt ?? .now
        return "\(f.string(from: segment.startAt))–\(f.string(from: end))"
    }
}

struct FlowTags: View {
    let tags: [String]
    var onRemove: (String) -> Void

    var body: some View {
        if tags.isEmpty {
            Text("No tags")
                .foregroundStyle(.tertiary)
                .font(.callout)
        } else {
            FlexibleTagWrap(tags: tags, onRemove: onRemove)
        }
    }
}

struct FlexibleTagWrap: View {
    let tags: [String]
    var onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption.weight(.medium))
                            Button {
                                onRemove(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var rows: [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var width = 0
        for tag in tags {
            let w = tag.count + 4
            if width + w > 36, !current.isEmpty {
                result.append(current)
                current = [tag]
                width = w
            } else {
                current.append(tag)
                width += w
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
