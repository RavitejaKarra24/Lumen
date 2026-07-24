import Foundation

/// On-disk Codable store (no SwiftData — works with Command Line Tools only).
actor ActivityStore {
    static let shared = ActivityStore()

    private(set) var segments: [ActivitySegment] = []
    private(set) var tags: [TagDefinition] = []
    private(set) var snapshots: [DailySnapshot] = []
    private(set) var contents: [ContentArtifact] = []
    private(set) var insightRecords: [InsightRecord] = []
    private(set) var goals: [CreationGoal] = []
    private(set) var projects: [ProjectDefinition] = []
    private(set) var warnings: [BehaviourWarning] = []
    private(set) var focusSessions: [FocusSession] = []
    private var dismissedInsightKeys: Set<String> = []

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lumen", isDirectory: true)
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loaded = false

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = Self.defaultDirectory
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadIfNeeded() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        segments = try read([ActivitySegment].self, from: "segments.json") ?? []
        tags = try read([TagDefinition].self, from: "tags.json") ?? []
        snapshots = try read([DailySnapshot].self, from: "snapshots.json") ?? []
        contents = try read([ContentArtifact].self, from: "content.json") ?? []
        insightRecords = try read([InsightRecord].self, from: "insights.json") ?? []
        goals = try read([CreationGoal].self, from: "goals.json") ?? []
        projects = try read([ProjectDefinition].self, from: "projects.json") ?? []
        warnings = try read([BehaviourWarning].self, from: "warnings.json") ?? []
        focusSessions = try read([FocusSession].self, from: "focus-sessions.json") ?? []
        dismissedInsightKeys = try read(Set<String>.self, from: "dismissed-insights.json") ?? []

        // A tracker segment cannot legitimately span a full day: idle detection and
        // app transitions would have split it. Remove legacy crash-inflated rows.
        let originalSegmentCount = segments.count
        segments.removeAll { segment in
            guard let endAt = segment.endAt else { return false }
            return endAt.timeIntervalSince(segment.startAt) > 24 * 60 * 60
        }
        var mutated = segments.count != originalSegmentCount

        // Close segments left open by a crash at their last observed tick,
        // rather than incorrectly counting all downtime until this launch.
        for index in segments.indices where segments[index].endAt == nil {
            segments[index].endAt = segments[index].lastObservedAt ?? segments[index].startAt
            mutated = true
        }
        if mutated { try persistSegments() }
        loaded = true
    }

    // MARK: - Segments

    func allSegments() throws -> [ActivitySegment] {
        try loadIfNeeded()
        return segments
    }

    func openSegment() throws -> ActivitySegment? {
        try loadIfNeeded()
        return segments.last(where: { $0.endAt == nil })
    }

    func segments(from start: Date, to end: Date) throws -> [ActivitySegment] {
        try loadIfNeeded()
        return segments
            .filter { segment in
                let segEnd = segment.endAt ?? .now
                return segment.startAt < end && segEnd >= start
            }
            .sorted { $0.startAt < $1.startAt }
    }

    func insert(_ segment: ActivitySegment) throws {
        try loadIfNeeded()
        segments.append(segment)
        try persistSegments()
    }

    func replaceSegment(_ segment: ActivitySegment) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        segments[index] = segment
        try persistSegments()
    }

    func setTags(id: UUID, tags: [String]) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].tags = tags
        try persistSegments()
    }

    func setNotes(id: UUID, notes: String) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].notes = notes
        try persistSegments()
    }

    func segment(id: UUID) throws -> ActivitySegment? {
        try loadIfNeeded()
        return segments.first(where: { $0.id == id })
    }

    func closeSegment(id: UUID, at date: Date, minimumDuration: TimeInterval) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].endAt = date
        segments[index].lastObservedAt = date
        if segments[index].duration < minimumDuration {
            let removedID = segments[index].id
            segments.remove(at: index)
            contents.removeAll { $0.segmentID == removedID }
            try persistContents()
        }
        try persistSegments()
    }

    func deleteSegment(id: UUID) throws {
        try loadIfNeeded()
        segments.removeAll { $0.id == id }
        contents.removeAll { $0.segmentID == id }
        try persistSegments()
        try persistContents()
    }

    // MARK: - Tags

    func allTags() throws -> [TagDefinition] {
        try loadIfNeeded()
        return tags.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertTag(name: String, colorHex: String = "#5B8DEF") throws {
        try loadIfNeeded()
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if tags.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            return
        }
        tags.append(TagDefinition(name: cleaned, colorHex: colorHex))
        try persistTags()
    }

    func deleteTag(id: UUID) throws {
        try loadIfNeeded()
        guard let tag = tags.first(where: { $0.id == id }) else { return }
        tags.removeAll { $0.id == id }
        for index in segments.indices {
            segments[index].tags.removeAll {
                $0.caseInsensitiveCompare(tag.name) == .orderedSame
            }
        }
        try persistTags()
        try persistSegments()
    }

    // MARK: - Snapshots

    func allSnapshots() throws -> [DailySnapshot] {
        try loadIfNeeded()
        return snapshots.sorted { $0.dayStart > $1.dayStart }
    }

    func upsertSnapshot(_ snapshot: DailySnapshot) throws {
        try loadIfNeeded()
        if let index = snapshots.firstIndex(where: { Calendar.current.isDate($0.dayStart, inSameDayAs: snapshot.dayStart) }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
        }
        try persistSnapshots()
    }

    func snapshot(on day: Date) throws -> DailySnapshot? {
        try loadIfNeeded()
        return snapshots.first { Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
    }

    // MARK: - Content

    func allContent() throws -> [ContentArtifact] {
        try loadIfNeeded()
        return contents
    }

    func content(for segmentID: UUID) throws -> ContentArtifact? {
        try loadIfNeeded()
        return contents
            .filter { $0.segmentID == segmentID }
            .sorted { $0.fetchedAt > $1.fetchedAt }
            .first
    }

    func contentMap(for segmentIDs: [UUID]) throws -> [UUID: ContentArtifact] {
        try loadIfNeeded()
        let wanted = Set(segmentIDs)
        var map: [UUID: ContentArtifact] = [:]
        for artifact in contents where wanted.contains(artifact.segmentID) {
            if let existing = map[artifact.segmentID] {
                if artifact.fetchedAt > existing.fetchedAt {
                    map[artifact.segmentID] = artifact
                }
            } else {
                map[artifact.segmentID] = artifact
            }
        }
        return map
    }

    func upsertContent(_ artifact: ContentArtifact) throws {
        try loadIfNeeded()
        // Keep one primary artifact per segment+kind.
        if let index = contents.firstIndex(where: { $0.segmentID == artifact.segmentID && $0.kind == artifact.kind }) {
            contents[index] = artifact
        } else if let index = contents.firstIndex(where: { $0.id == artifact.id }) {
            contents[index] = artifact
        } else {
            contents.append(artifact)
        }
        // Bound growth
        if contents.count > 5000 {
            contents = Array(contents.suffix(4000))
        }
        try persistContents()
    }

    // MARK: - Insights

    func allInsights() throws -> [InsightRecord] {
        try loadIfNeeded()
        return insightRecords.sorted { $0.createdAt > $1.createdAt }
    }

    func insights(on day: Date) throws -> [InsightRecord] {
        try loadIfNeeded()
        return insightRecords
            .filter { Calendar.current.isDate($0.dayStart, inSameDayAs: day) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                if lhs.kind != rhs.kind {
                    return kindRank(lhs.kind) < kindRank(rhs.kind)
                }
                return lhs.confidence > rhs.confidence
            }
    }

    func replaceGeneratedInsights(dayStart: Date, with insights: [InsightRecord]) throws {
        try loadIfNeeded()
        // Keep pinned or completed user-managed items for the day.
        let kept = insightRecords.filter { record in
            if !Calendar.current.isDate(record.dayStart, inSameDayAs: dayStart) { return true }
            return record.isPinned || record.isCompleted
        }
        let keptKeys = Set(kept.filter { Calendar.current.isDate($0.dayStart, inSameDayAs: dayStart) }.map {
            "\($0.kind.rawValue)|\($0.title.lowercased())"
        })
        let fresh = insights.filter { insight in
            let key = insightKey(insight)
            return !keptKeys.contains(key) && !dismissedInsightKeys.contains(key)
        }
        insightRecords = kept + fresh
        try persistInsights()
    }

    func upsertInsight(_ insight: InsightRecord) throws {
        try loadIfNeeded()
        if let index = insightRecords.firstIndex(where: { $0.id == insight.id }) {
            insightRecords[index] = insight
        } else {
            insightRecords.append(insight)
        }
        try persistInsights()
    }

    func deleteInsight(id: UUID) throws {
        try loadIfNeeded()
        if let record = insightRecords.first(where: { $0.id == id }) {
            dismissedInsightKeys.insert(insightKey(record))
        }
        insightRecords.removeAll { $0.id == id }
        try persistInsights()
        try persistDismissedInsightKeys()
    }

    // MARK: - Goals

    func allGoals() throws -> [CreationGoal] {
        try loadIfNeeded()
        return goals.sorted { $0.createdAt < $1.createdAt }
    }

    func upsertGoal(_ goal: CreationGoal) throws {
        try loadIfNeeded()
        if let index = goals.firstIndex(where: { $0.id == goal.id }) {
            goals[index] = goal
        } else {
            goals.append(goal)
        }
        try persistGoals()
    }

    func deleteGoal(id: UUID) throws {
        try loadIfNeeded()
        goals.removeAll { $0.id == id }
        try persistGoals()
    }

    // MARK: - Projects

    func allProjects() throws -> [ProjectDefinition] {
        try loadIfNeeded()
        return projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func upsertProject(_ project: ProjectDefinition) throws {
        try loadIfNeeded()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try persistProjects()
    }

    func deleteProject(id: UUID) throws {
        try loadIfNeeded()
        projects.removeAll { $0.id == id }
        try persistProjects()
    }

    // MARK: - Focus sessions

    func allFocusSessions() throws -> [FocusSession] {
        try loadIfNeeded()
        return focusSessions.sorted { $0.startAt > $1.startAt }
    }

    func activeFocusSession() throws -> FocusSession? {
        try loadIfNeeded()
        return focusSessions.first { $0.status == .active }
    }

    func upsertFocusSession(_ session: FocusSession) throws {
        try loadIfNeeded()
        if let index = focusSessions.firstIndex(where: { $0.id == session.id }) {
            focusSessions[index] = session
        } else {
            focusSessions.append(session)
        }
        if focusSessions.count > 1000 {
            focusSessions = Array(focusSessions.sorted { $0.startAt > $1.startAt }.prefix(800))
        }
        try persistFocusSessions()
    }

    // MARK: - Warnings

    func recentWarnings(limit: Int = 30) throws -> [BehaviourWarning] {
        try loadIfNeeded()
        return Array(warnings.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func upsertWarning(_ warning: BehaviourWarning) throws {
        try loadIfNeeded()
        if let index = warnings.firstIndex(where: { $0.id == warning.id }) {
            warnings[index] = warning
        } else {
            warnings.append(warning)
        }
        if warnings.count > 300 {
            warnings = Array(warnings.sorted { $0.createdAt > $1.createdAt }.prefix(200))
        }
        try persistWarnings()
    }

    private func insightKey(_ insight: InsightRecord) -> String {
        "\(insight.kind.rawValue)|\(insight.title.lowercased())"
    }

    private func kindRank(_ kind: InsightKind) -> Int {
        switch kind {
        case .learningSummary: 0
        case .actionItem: 1
        case .idea: 2
        case .interest: 3
        case .sessionNote: 4
        }
    }

    // MARK: - Persistence

    private func persistSegments() throws {
        try write(segments, to: "segments.json")
    }

    private func persistTags() throws {
        try write(tags, to: "tags.json")
    }

    private func persistSnapshots() throws {
        try write(snapshots, to: "snapshots.json")
    }

    private func persistContents() throws {
        try write(contents, to: "content.json")
    }

    private func persistInsights() throws {
        try write(insightRecords, to: "insights.json")
    }

    private func persistGoals() throws {
        try write(goals, to: "goals.json")
    }

    private func persistProjects() throws {
        try write(projects, to: "projects.json")
    }

    private func persistWarnings() throws {
        try write(warnings, to: "warnings.json")
    }

    private func persistFocusSessions() throws {
        try write(focusSessions, to: "focus-sessions.json")
    }

    private func persistDismissedInsightKeys() throws {
        try write(dismissedInsightKeys, to: "dismissed-insights.json")
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }
}
