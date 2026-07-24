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
                        List(segments, selection: $selectedSegmentID) { segment in
                            TimelineRow(segment: segment)
                                .tag(segment.id)
                                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        }
                        .listStyle(.inset)
                        .onChange(of: selectedSegmentID) { _, newValue in
                            tagDraft = ""
                            if let id = newValue,
                               let segment = appState.analytics?.segments.first(where: { $0.id == id }) {
                                notesDraft = segment.notes
                            } else {
                                notesDraft = ""
                            }
                        }
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
        .onAppear {
            if selectedSegmentID == nil {
                selectedSegmentID = appState.analytics?.segments.first(where: { !$0.isIdle })?.id
            }
        }
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
