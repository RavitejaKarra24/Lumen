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
    private(set) var mutedTopics: Set<String> = []

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
        case mutedTopics = "muted-topics.json"
    }

    /// Bumped on every mutation of a segment. Callers that derive a write from an
    /// earlier read pass the revision they saw, and the store drops the write when
    /// the row has changed since — analysis results never clobber fresher data.
    private var segmentRevisions: [UUID: Int] = [:]

    struct SegmentSnapshot: Sendable {
        var segment: ActivitySegment
        var revision: Int
    }

    /// Classifier-owned fields, applied without touching tags, notes, or timestamps.
    struct ClassificationPatch: Sendable {
        var id: UUID
        var category: ActivityCategory
        var sessionKind: SessionKind
        var topics: [String]
    }

    /// How well saving to disk is doing, for surfacing in the UI.
    struct PersistenceHealth: Sendable, Equatable {
        var lastError: String?
        var lastErrorAt: Date?
        var failedFileNames: [String]
        var lastSuccessfulFlushAt: Date?
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
    private var failedFiles: Set<StoreFile> = []
    private var flushTask: Task<Void, Never>?
    private var flushRetryCount = 0
    private(set) var persistenceHealth = PersistenceHealth(
        lastError: nil,
        lastErrorAt: nil,
        failedFileNames: [],
        lastSuccessfulFlushAt: nil
    )

    /// Bump when the on-disk layout changes. A store written by a newer Lumen is
    /// refused instead of misdecoded into garbage.
    private static let schemaVersion = 1
    private static let metaFileName = "store-meta.json"

    private struct StoreMeta: Codable {
        var schemaVersion: Int
        var writtenAt: Date
    }

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
        try checkSchemaVersion()
        // Each file is read independently: one malformed file is quarantined for
        // inspection instead of preventing recording and analytics from starting.
        segments = try read([ActivitySegment].self, from: .segments) ?? []
        tags = try read([TagDefinition].self, from: .tags) ?? []
        snapshots = try read([DailySnapshot].self, from: .snapshots) ?? []
        contents = try read([ContentArtifact].self, from: .contents) ?? []
        insightRecords = try read([InsightRecord].self, from: .insights) ?? []
        goals = try read([CreationGoal].self, from: .goals) ?? []
        projects = try read([ProjectDefinition].self, from: .projects) ?? []
        warnings = try read([BehaviourWarning].self, from: .warnings) ?? []
        focusSessions = try read([FocusSession].self, from: .focusSessions) ?? []
        dismissedInsightKeys = try read(Set<String>.self, from: .dismissedInsights) ?? []
        mutedTopics = try read(Set<String>.self, from: .mutedTopics) ?? []
        segmentRevisions = [:]
        for segment in segments { segmentRevisions[segment.id] = 1 }

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

    /// Refuses to open a store written by a newer schema instead of misreading it.
    private func checkSchemaVersion() throws {
        let url = directory.appendingPathComponent(Self.metaFileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only a genuinely absent marker denotes a legacy store. Never
            // overwrite unreadable or malformed metadata with our own version.
            let meta = StoreMeta(schemaVersion: Self.schemaVersion, writtenAt: .now)
            try encoder.encode(meta).write(to: url, options: [.atomic])
            return
        }
        let meta = try decoder.decode(StoreMeta.self, from: data)
        guard meta.schemaVersion <= Self.schemaVersion else {
            throw StoreError.newerSchema(
                onDisk: meta.schemaVersion,
                supported: Self.schemaVersion
            )
        }
    }

    enum StoreError: LocalizedError {
        case newerSchema(onDisk: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case let .newerSchema(onDisk, supported):
                "This data folder was written by a newer version of Lumen (schema \(onDisk), supported \(supported)). Update the app instead of editing these files."
            }
        }
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
        segmentRevisions[segment.id] = 1
        persistSegments()
    }

    func segment(id: UUID) throws -> ActivitySegment? {
        try loadIfNeeded()
        return segments.first(where: { $0.id == id })
    }

    /// The segment together with its mutation counter, so a later write derived
    /// from this snapshot can be dropped when the row has moved on.
    func segmentSnapshot(id: UUID) throws -> SegmentSnapshot? {
        try loadIfNeeded()
        guard let segment = segments.first(where: { $0.id == id }) else { return nil }
        return SegmentSnapshot(segment: segment, revision: segmentRevisions[id] ?? 0)
    }

    func allSegmentRevisions() throws -> [UUID: Int] {
        try loadIfNeeded()
        return segmentRevisions
    }

    /// Recorder-owned fields only: window title/URL drift, the crash-recovery
    /// heartbeat, and the live reclassification. Tags, notes, and recording
    /// timestamps are never touched, so a concurrent edit cannot be overwritten.
    func applyRecordingTouch(
        id: UUID,
        windowTitle: String,
        urlString: String?,
        domain: String?,
        lastObservedAt: Date?,
        category: ActivityCategory,
        sessionKind: SessionKind,
        topics: [String]
    ) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        var segment = segments[index]
        var changed = false
        if segment.windowTitle != windowTitle { segment.windowTitle = windowTitle; changed = true }
        if segment.urlString != urlString { segment.urlString = urlString; changed = true }
        if segment.domain != domain { segment.domain = domain; changed = true }
        if let lastObservedAt, segment.lastObservedAt != lastObservedAt {
            segment.lastObservedAt = lastObservedAt
            changed = true
        }
        if segment.category != category { segment.category = category; changed = true }
        if segment.sessionKind != sessionKind { segment.sessionKind = sessionKind; changed = true }
        if segment.topics != topics { segment.topics = topics; changed = true }
        guard changed else { return }
        segments[index] = segment
        bumpRevision(id)
        persistSegments()
    }

    /// Heartbeat for an already-idle row. Deliberately does not bump the
    /// revision: polling adds no classification evidence a pending write could
    /// contradict.
    func updateObservation(id: UUID, at date: Date) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard segments[index].lastObservedAt != date else { return }
        segments[index].lastObservedAt = date
        persistSegments()
    }

    /// Applies classifier-owned fields in bulk. Patches whose segment changed
    /// since the caller's snapshot (revision mismatch) are skipped so stale
    /// analysis cannot overwrite fresher data; the next cycle recomputes them.
    func applyClassificationPatches(
        _ patches: [ClassificationPatch],
        expectedRevisions: [UUID: Int]
    ) throws {
        try loadIfNeeded()
        guard !patches.isEmpty else { return }
        var changed = false
        for patch in patches {
            guard let expected = expectedRevisions[patch.id],
                  segmentRevisions[patch.id] == expected,
                  let index = segments.firstIndex(where: { $0.id == patch.id })
            else { continue }
            var segment = segments[index]
            if segment.category != patch.category { segment.category = patch.category }
            if segment.sessionKind != patch.sessionKind { segment.sessionKind = patch.sessionKind }
            if segment.topics != patch.topics { segment.topics = patch.topics }
            if segment != segments[index] {
                segments[index] = segment
                bumpRevision(patch.id)
                changed = true
            }
        }
        if changed { persistSegments() }
    }

    /// Marks a capture attempt started. A no-op when the segment no longer exists.
    func setContentStatus(id: UUID, status: ContentStatus) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard segments[index].contentStatus != status else { return }
        segments[index].contentStatus = status
        bumpRevision(id)
        persistSegments()
    }

    /// Stores the outcome of a capture. Content status/summary are applied
    /// whenever the segment still exists; the reclassification is applied only
    /// when nothing changed while the request ran. Returns false when the
    /// segment was deleted meanwhile so the caller drops the captured content.
    func applyCaptureResult(
        id: UUID,
        contentStatus: ContentStatus,
        contentSummary: String?,
        classification: ClassificationPatch?,
        expectedRevision: Int
    ) throws -> Bool {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return false }
        var segment = segments[index]
        if segment.contentStatus != contentStatus { segment.contentStatus = contentStatus }
        if segment.contentSummary != contentSummary { segment.contentSummary = contentSummary }
        if let classification, segmentRevisions[id] == expectedRevision {
            segment.category = classification.category
            segment.sessionKind = classification.sessionKind
            segment.topics = classification.topics
        }
        if segment != segments[index] {
            segments[index] = segment
            bumpRevision(id)
            persistSegments()
        }
        return true
    }

    func closeSegment(id: UUID, at date: Date, minimumDuration: TimeInterval) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].endAt = date
        segments[index].lastObservedAt = date
        bumpRevision(id)
        if segments[index].duration < minimumDuration {
            let removedID = segments[index].id
            segments.remove(at: index)
            segmentRevisions[removedID] = nil
            contents.removeAll { $0.segmentID == removedID }
            persistContents()
        }
        persistSegments()
    }

    /// Reconciles closed active rows with the real inactivity boundary. Polling
    /// can close several rows after input stopped (for example as apps quit),
    /// so trimming only the latest one would still credit inactivity as work.
    func trimLastClosedSegment(to idleStart: Date) throws {
        try loadIfNeeded()
        var changed = false
        var removedIDs: Set<UUID> = []
        // Walk backwards so removals are safe regardless of chronological order.
        for index in segments.indices.reversed() {
            guard let endAt = segments[index].endAt,
                  !segments[index].isIdle, endAt > idleStart else { continue }
            if idleStart > segments[index].startAt {
                segments[index].endAt = idleStart
                segments[index].lastObservedAt = min(segments[index].lastObservedAt ?? idleStart, idleStart)
                bumpRevision(segments[index].id)
            } else {
                // This whole row lies inside the inactivity window.
                let removedID = segments[index].id
                segments.remove(at: index)
                segmentRevisions[removedID] = nil
                removedIDs.insert(removedID)
            }
            changed = true
        }
        if !removedIDs.isEmpty {
            contents.removeAll { removedIDs.contains($0.segmentID) }
            persistContents()
        }
        if changed { persistSegments() }
    }

    func deleteSegment(id: UUID) throws {
        try loadIfNeeded()
        segments.removeAll { $0.id == id }
        segmentRevisions[id] = nil
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

        // Minutes must be clipped to the day like every other headline metric:
        // a session crossing midnight contributes only its portion of this day.
        func minutes(where predicate: (ActivitySegment) -> Bool) -> Double {
            todaySegments
                .filter(predicate)
                .reduce(0.0) {
                    $0 + AnalyticsService.clippedDuration(
                        $1,
                        dayStart: todayAnalytics.dayStart,
                        dayEnd: todayAnalytics.dayEnd
                    )
                } / 60.0
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

    /// Deletes raw activity older than `days`. Saved reports are always kept so
    /// history stays readable after the raw segments are gone. Content,
    /// unpinned insights, finished focus sessions, and warnings for the removed
    /// window are cleaned up too — including orphans left by earlier deletes,
    /// even when no raw segment currently qualifies. Returns segments removed.
    @discardableResult
    func pruneSegments(olderThan days: Int, calendar: Calendar = .current) throws -> Int {
        try loadIfNeeded()
        guard days > 0 else { return 0 }
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: .now))
            ?? Date.distantPast

        let doomed = segments.filter { ($0.endAt ?? .now) < cutoff }
        if !doomed.isEmpty {
            let doomedIDs = Set(doomed.map(\.id))
            segments.removeAll { doomedIDs.contains($0.id) }
            for id in doomedIDs { segmentRevisions[id] = nil }
            persistSegments()
        }

        // Content for removed segments, plus orphans from earlier deletes.
        let liveIDs = Set(segments.map(\.id))
        let doomedContentIDs = Set(
            contents.filter { !liveIDs.contains($0.segmentID) }.map(\.id)
        )
        if !doomedContentIDs.isEmpty {
            contents.removeAll { doomedContentIDs.contains($0.id) }
            persistContents()
        }

        let doomedInsights = insightRecords.filter { $0.dayStart < cutoff && !$0.isPinned }
        if !doomedInsights.isEmpty {
            let doomedInsightIDs = Set(doomedInsights.map(\.id))
            insightRecords.removeAll { doomedInsightIDs.contains($0.id) }
            persistInsights()
        }

        // Finished focus sessions and stale warnings carry no saved-report value.
        let doomedSessions = focusSessions.filter { session in
            guard session.status != .active else { return false }
            return (session.endAt ?? session.scheduledEndAt) < cutoff
        }
        if !doomedSessions.isEmpty {
            let doomedSessionIDs = Set(doomedSessions.map(\.id))
            focusSessions.removeAll { doomedSessionIDs.contains($0.id) }
            persistFocusSessions()
        }

        let doomedWarnings = warnings.filter { $0.createdAt < cutoff }
        if !doomedWarnings.isEmpty {
            let doomedWarningIDs = Set(doomedWarnings.map(\.id))
            warnings.removeAll { doomedWarningIDs.contains($0.id) }
            persistWarnings()
        }

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

    /// Atomic add: the tag is applied to the live row, never to a stale copy.
    func addTag(_ name: String, to segmentID: UUID) throws {
        try loadIfNeeded()
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if let index = segments.firstIndex(where: { $0.id == segmentID }),
           !segments[index].tags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            segments[index].tags.append(cleaned)
            bumpRevision(segmentID)
            persistSegments()
        }
        try upsertTag(name: cleaned)
    }

    /// Atomic remove, so an analysis write racing the removal cannot resurrect it.
    func removeTag(_ name: String, from segmentID: UUID) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { return }
        let before = segments[index].tags
        segments[index].tags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        if segments[index].tags != before {
            bumpRevision(segmentID)
            persistSegments()
        }
    }

    /// Sets the whole tag list on the live row (used by the timeline editor).
    func setTags(id: UUID, tags: [String]) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard segments[index].tags != tags else { return }
        segments[index].tags = tags
        bumpRevision(id)
        persistSegments()
    }

    func setNotes(id: UUID, notes: String) throws {
        try loadIfNeeded()
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        guard segments[index].notes != notes else { return }
        segments[index].notes = notes
        bumpRevision(id)
        persistSegments()
    }

    func deleteTag(id: UUID) throws {
        try loadIfNeeded()
        guard let tag = tags.first(where: { $0.id == id }) else { return }
        tags.removeAll { $0.id == id }
        for index in segments.indices {
            let before = segments[index].tags
            segments[index].tags.removeAll {
                $0.caseInsensitiveCompare(tag.name) == .orderedSame
            }
            if segments[index].tags != before { bumpRevision(segments[index].id) }
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
            insightKey($0)
        })
        let fresh = insights.filter { insight in
            let key = insightKey(insight)
            return !keptKeys.contains(key)
                && !dismissedInsightKeys.contains(key)
                && !isMuted(insight)
        }
        insightRecords = kept + fresh
        persistInsights()
    }

    /// Deleting an insight dismisses that occurrence: the key includes the day,
    /// so tomorrow's summary with the same title still appears.
    func deleteInsight(id: UUID) throws {
        try loadIfNeeded()
        if let record = insightRecords.first(where: { $0.id == id }) {
            dismissedInsightKeys.insert(insightKey(record))
        }
        insightRecords.removeAll { $0.id == id }
        persistInsights()
        persistDismissedInsightKeys()
    }

    // MARK: - Muted insight topics

    func upsertInsight(_ insight: InsightRecord) throws {
        try loadIfNeeded()
        if let index = insightRecords.firstIndex(where: { $0.id == insight.id }) {
            insightRecords[index] = insight
        } else {
            insightRecords.append(insight)
        }
        persistInsights()
    }

    /// A separate, persistent mute: silenced topics never regenerate on any day,
    /// unlike the day-scoped dismissal a plain delete performs.
    func muteTopic(_ topic: String) throws {
        try loadIfNeeded()
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        guard !mutedTopics.contains(cleaned) else { return }
        mutedTopics.insert(cleaned)
        persistMutedTopics()
    }

    func unmuteTopic(_ topic: String) throws {
        try loadIfNeeded()
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mutedTopics.contains(cleaned) else { return }
        mutedTopics.remove(cleaned)
        persistMutedTopics()
    }

    /// Undo path for every persistent mute at once.
    func unmuteAllTopics() throws {
        try loadIfNeeded()
        guard !mutedTopics.isEmpty else { return }
        mutedTopics = []
        persistMutedTopics()
    }

    func dismissedInsightCount() throws -> Int {
        try loadIfNeeded()
        return dismissedInsightKeys.count
    }

    func resetDismissedInsights() throws {
        try loadIfNeeded()
        guard !dismissedInsightKeys.isEmpty else { return }
        dismissedInsightKeys = []
        persistDismissedInsightKeys()
    }

    private func isMuted(_ insight: InsightRecord) -> Bool {
        let title = insight.title.lowercased()
        if mutedTopics.contains(title) { return true }
        return insight.topics.contains { mutedTopics.contains($0.lowercased()) }
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
        // Day-scoped: deleting "Learning summary" from one day must not suppress
        // the same-titled summary generated for later days.
        let day = Calendar.current.startOfDay(for: insight.dayStart).timeIntervalSince1970
        return "\(insight.kind.rawValue)|\(Int(day))|\(insight.title.lowercased())"
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
    private func persistMutedTopics() { markDirty(.mutedTopics) }

    private func bumpRevision(_ id: UUID) {
        segmentRevisions[id, default: 0] += 1
    }

    private func markDirty(_ file: StoreFile) {
        dirtyFiles.insert(file)
        scheduleFlush(delay: Self.flushDelay)
    }

    private func scheduleFlush(delay: Duration) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            // A cancelled sleeper must not clear a newer retry's task handle.
            guard !Task.isCancelled else { return }
            try? await self?.performFlush()
        }
    }

    /// Writes every pending change immediately, throwing the last write error so
    /// callers can tell the user their data is not saved yet. Failed files stay
    /// dirty and keep retrying on the normal schedule.
    func flush() throws {
        flushTask?.cancel()
        flushTask = nil
        try performFlush()
    }

    /// Both explicit and scheduled flushes share retry and health bookkeeping.
    private func performFlush() throws {
        flushTask = nil
        let pending = dirtyFiles
        dirtyFiles.removeAll()
        var failed: Set<StoreFile> = []
        var lastError: Error?
        for file in pending {
            do {
                try write(file)
                failedFiles.remove(file)
            } catch {
                failed.insert(file)
                recordPersistenceError("Saving \(file.rawValue) failed: \(error.localizedDescription)", file: file)
                lastError = error
            }
        }
        persistenceHealth.failedFileNames = failedFiles.map(\.rawValue).sorted()
        if failedFiles.isEmpty {
            persistenceHealth.lastError = nil
            persistenceHealth.lastErrorAt = nil
        }
        if failed.isEmpty {
            flushRetryCount = 0
            if !pending.isEmpty {
                persistenceHealth.lastSuccessfulFlushAt = .now
            }
        } else {
            // Retry with a bounded backoff instead of waiting for the next
            // mutation — a failing disk must not silently hold writes forever.
            dirtyFiles.formUnion(failed)
            flushRetryCount = min(flushRetryCount + 1, 5)
            let seconds = min(
                60.0,
                Double(Self.flushDelay.components.seconds) * pow(2.0, Double(flushRetryCount))
            )
            scheduleFlush(delay: .seconds(max(1, seconds)))
        }
        if let lastError { throw lastError }
    }

    private func recordPersistenceError(_ message: String, file: StoreFile) {
        failedFiles.insert(file)
        persistenceHealth.lastError = message
        persistenceHealth.lastErrorAt = .now
        persistenceHealth.failedFileNames = failedFiles.map(\.rawValue).sorted()
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
        case .mutedTopics: try write(mutedTopics, to: file.rawValue)
        }
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let url = directory.appendingPathComponent(name)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    /// Reads one file independently. A malformed file is moved aside under a
    /// `.corrupt-` name so the original stays available for inspection — the
    /// store never silently resets user history — and the rest of the store
    /// still loads.
    private func read<T: Decodable>(_ type: T.Type, from file: StoreFile) throws -> T? {
        let url = directory.appendingPathComponent(file.rawValue)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            // An I/O failure says nothing about whether the data is corrupt.
            // Refuse to load rather than rename it and start empty history.
            recordPersistenceError("Reading \(file.rawValue) failed: \(error.localizedDescription)", file: file)
            throw error
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            let backup = directory.appendingPathComponent(
                "\(file.rawValue).corrupt-\(UUID().uuidString)"
            )
            do {
                try FileManager.default.moveItem(at: url, to: backup)
            } catch {
                // Without a preserved copy, accepting mutations would risk
                // overwriting the only recoverable version on the next flush.
                recordPersistenceError("Preserving \(file.rawValue) failed: \(error.localizedDescription)", file: file)
                throw error
            }
            recordPersistenceError(
                "\(file.rawValue) could not be decoded (\(error.localizedDescription)); kept a copy as \(backup.lastPathComponent).",
                file: file
            )
            return nil
        }
    }
}
