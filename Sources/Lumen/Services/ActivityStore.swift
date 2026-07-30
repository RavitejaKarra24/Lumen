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

    /// Files the store owns. Writes are coalesced per file.
    private enum StoreFile: String, CaseIterable {
        case segments = "segments.json"
        case tags = "tags.json"
        case snapshots = "snapshots.json"
        case contents = "content.json"
        case insights = "insights.json"
        case goals = "goals.json"
        case projects = "projects.json"
        case warnings = "warnings.json"
        case focusSessions = "focus-sessions.json"
        case dismissedInsights = "dismissed-insights.json"
    }

    /// The recorder touches the open segment every few seconds. Rewriting the whole
    /// history on each touch is what makes long-lived installs crawl, so writes are
    /// batched and flushed on a short delay instead.
    private static let flushDelay: Duration = .seconds(3)

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var loaded = false
    private var dirtyFiles: Set<StoreFile> = []
    private var flushTask: Task<Void, Never>?

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
        if mutated { persistSegments() }
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
        persistSegments()
    }

    func replaceSegment(_ segment: ActivitySegment) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return }
        segments[index] = segment
        persistSegments()
    }

    func setTags(id: UUID, tags: [String]) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].tags = tags
        persistSegments()
    }

    func setNotes(id: UUID, notes: String) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].notes = notes
        persistSegments()
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
            persistContents()
        }
        persistSegments()
    }

    /// Applies many segment edits with a single persist, for callers that
    /// reclassify a whole day at once.
    func replaceSegments(_ updated: [ActivitySegment]) throws {
        try loadIfNeeded()
        guard !updated.isEmpty else { return }
        var indexByID: [UUID: Int] = [:]
        for (index, segment) in segments.enumerated() {
            indexByID[segment.id] = index
        }
        var changed = false
        for segment in updated {
            guard let index = indexByID[segment.id], segments[index] != segment else { continue }
            segments[index] = segment
            changed = true
        }
        if changed { persistSegments() }
    }

    func deleteSegment(id: UUID) throws {
        try loadIfNeeded()
        segments.removeAll { $0.id == id }
        contents.removeAll { $0.segmentID == id }
        persistSegments()
        persistContents()
    }

    /// Closes whatever segment is still open. Safe to call off the main actor,
    /// which matters during app termination.
    func closeOpenSegment(at date: Date, minimumDuration: TimeInterval) throws {
        try loadIfNeeded()
        guard let open = segments.last(where: { $0.endAt == nil }) else { return }
        try closeSegment(id: open.id, at: date, minimumDuration: minimumDuration)
    }

    // MARK: - Analysis

    /// Analyses one day inside the actor so the heavy filtering and merging stays
    /// off the main thread, and only the finished result crosses back.
    func analytics(for day: Date, calendar: Calendar = .current) throws -> DayAnalytics {
        try loadIfNeeded()
        let (start, end) = AnalyticsService.dayInterval(for: day, calendar: calendar)
        let daySegments = segments
            .filter { segment in
                let segEnd = segment.endAt ?? .now
                return segment.startAt < end && segEnd >= start
            }
            .sorted { $0.startAt < $1.startAt }
        let daySessions = focusSessions.filter { session in
            let sessionEnd = min(session.endAt ?? .now, session.scheduledEndAt)
            return session.startAt < end && sessionEnd >= start
        }
        return AnalyticsService.analyze(
            segments: daySegments,
            focusSessions: daySessions,
            dayStart: start,
            dayEnd: end
        )
    }

    /// Everything the behaviour engine needs, computed in one pass on this actor.
    ///
    /// Previously the engine pulled the whole history to the main actor and ran the
    /// weekly analyser, project scorer, and topic extraction there — several times a
    /// minute, which showed up as UI stutter once a few weeks of data accumulated.
    struct BehaviourInputs: Sendable {
        var todayAnalytics: DayAnalytics
        var interests: [InterestSignal]
        var weekly: WeeklyPatternReport
        var projectScores: [ProjectScore]
        var recommendations: [BuildRecommendation]
        var deepWorkByDay: [Date: TimeInterval]
        var todayCreationMinutes: Double
        var todayLearningMinutes: Double
        var todayDistractionMinutes: Double
        var openSegment: ActivitySegment?
        var goals: [CreationGoal]
        var projects: [ProjectDefinition]
        var recentWarnings: [BehaviourWarning]
    }

    func behaviourInputs(now: Date = .now, calendar: Calendar = .current) throws -> BehaviourInputs {
        try loadIfNeeded()

        let todayAnalytics = try analytics(for: now, calendar: calendar)
        let todaySegments = todayAnalytics.segments

        func minutes(where predicate: (ActivitySegment) -> Bool) -> Double {
            todaySegments.filter(predicate).reduce(0.0) { $0 + $1.duration } / 60.0
        }

        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let weekSegments = segments.filter { $0.startAt >= weekAgo }
        let interests = InterestDetector.detect(segments: weekSegments)

        let insights = insightRecords
        let insightCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        let openActions = insights.filter {
            $0.kind == .actionItem && !$0.isCompleted && $0.createdAt >= insightCutoff
        }
        let openIdeas = insights.filter {
            $0.kind == .idea && !$0.isCompleted && $0.createdAt >= insightCutoff
        }

        let weekly = WeeklyPatternAnalyzer.analyze(
            segments: segments,
            endingOn: now,
            interests: interests
        )
        let projectScores = ProjectScorer.score(
            projects: projects,
            segments: segments,
            insights: insights,
            now: now
        )
        let recommendations = NextBuildEngine.recommend(
            projectScores: projectScores,
            interests: interests,
            ideas: openIdeas,
            actions: openActions,
            weekly: weekly
        )

        return BehaviourInputs(
            todayAnalytics: todayAnalytics,
            interests: interests,
            weekly: weekly,
            projectScores: projectScores,
            recommendations: recommendations,
            deepWorkByDay: AnalyticsService.deepWorkSecondsByDay(
                segments: segments,
                focusSessions: focusSessions,
                calendar: calendar
            ),
            todayCreationMinutes: minutes { $0.sessionKind == .creation || $0.sessionKind == .deepWork },
            todayLearningMinutes: minutes { $0.sessionKind == .learning || $0.sessionKind == .research },
            todayDistractionMinutes: minutes { $0.sessionKind == .distraction },
            openSegment: todaySegments.last(where: { $0.endAt == nil }),
            goals: goals.sorted { $0.createdAt < $1.createdAt },
            projects: projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            recentWarnings: Array(warnings.sorted { $0.createdAt > $1.createdAt }.prefix(20))
        )
    }

    func deepWorkSecondsByDay(calendar: Calendar = .current) throws -> [Date: TimeInterval] {
        try loadIfNeeded()
        return AnalyticsService.deepWorkSecondsByDay(
            segments: segments,
            focusSessions: focusSessions,
            calendar: calendar
        )
    }

    // MARK: - Retention

    /// Deletes activity older than `days`, keeping generated reports so history
    /// stays readable after the raw segments are gone. Returns segments removed.
    @discardableResult
    func pruneSegments(olderThan days: Int, calendar: Calendar = .current) throws -> Int {
        try loadIfNeeded()
        guard days > 0 else { return 0 }
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now))
            ?? Date.distantPast
        let doomed = segments.filter { ($0.endAt ?? .now) < cutoff }
        guard !doomed.isEmpty else { return 0 }
        let doomedIDs = Set(doomed.map(\.id))
        segments.removeAll { doomedIDs.contains($0.id) }
        contents.removeAll { doomedIDs.contains($0.segmentID) }
        insightRecords.removeAll { $0.dayStart < cutoff && !$0.isPinned }
        persistSegments()
        persistContents()
        persistInsights()
        return doomed.count
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
        persistTags()
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
        persistTags()
        persistSegments()
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
        persistSnapshots()
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
        persistContents()
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
        persistInsights()
    }

    func upsertInsight(_ insight: InsightRecord) throws {
        try loadIfNeeded()
        if let index = insightRecords.firstIndex(where: { $0.id == insight.id }) {
            insightRecords[index] = insight
        } else {
            insightRecords.append(insight)
        }
        persistInsights()
    }

    func deleteInsight(id: UUID) throws {
        try loadIfNeeded()
        if let record = insightRecords.first(where: { $0.id == id }) {
            dismissedInsightKeys.insert(insightKey(record))
        }
        insightRecords.removeAll { $0.id == id }
        persistInsights()
        persistDismissedInsightKeys()
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
        persistGoals()
    }

    func deleteGoal(id: UUID) throws {
        try loadIfNeeded()
        goals.removeAll { $0.id == id }
        persistGoals()
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
        persistProjects()
    }

    func deleteProject(id: UUID) throws {
        try loadIfNeeded()
        projects.removeAll { $0.id == id }
        persistProjects()
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
        persistFocusSessions()
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
        persistWarnings()
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

    private func persistSegments() { markDirty(.segments) }
    private func persistTags() { markDirty(.tags) }
    private func persistSnapshots() { markDirty(.snapshots) }
    private func persistContents() { markDirty(.contents) }
    private func persistInsights() { markDirty(.insights) }
    private func persistGoals() { markDirty(.goals) }
    private func persistProjects() { markDirty(.projects) }
    private func persistWarnings() { markDirty(.warnings) }
    private func persistFocusSessions() { markDirty(.focusSessions) }
    private func persistDismissedInsightKeys() { markDirty(.dismissedInsights) }

    private func markDirty(_ file: StoreFile) {
        dirtyFiles.insert(file)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            await self?.performFlush()
        }
    }

    /// Writes every pending change immediately. Call before the process exits.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        performFlush()
    }

    private func performFlush() {
        flushTask = nil
        let pending = dirtyFiles
        dirtyFiles.removeAll()
        for file in pending {
            do {
                try write(file)
            } catch {
                // Put it back so the next flush retries rather than losing the change.
                dirtyFiles.insert(file)
            }
        }
    }

    private func write(_ file: StoreFile) throws {
        switch file {
        case .segments: try write(segments, to: file.rawValue)
        case .tags: try write(tags, to: file.rawValue)
        case .snapshots: try write(snapshots, to: file.rawValue)
        case .contents: try write(contents, to: file.rawValue)
        case .insights: try write(insightRecords, to: file.rawValue)
        case .goals: try write(goals, to: file.rawValue)
        case .projects: try write(projects, to: file.rawValue)
        case .warnings: try write(warnings, to: file.rawValue)
        case .focusSessions: try write(focusSessions, to: file.rawValue)
        case .dismissedInsights: try write(dismissedInsightKeys, to: file.rawValue)
        }
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
