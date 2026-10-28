import Foundation
@testable import LumenKit

// F01 (stale writes cannot clobber newer data), F03 (retention), F04
// (idle backdating), F11 (persistence health and recovery), and F14
// (day-scoped dismissal).

func runStoreTests() async {
    // MARK: F01

    await runTest("store: classification patches never touch tags, notes, or timestamps") {
        let store = TestSupport.makeStore()
        let start = Date().addingTimeInterval(-600)
        let segment = TestSupport.segment(from: start, to: Date(), tags: ["important"], notes: "user note")
        try await store.insert(segment)

        let revisions = try await store.allSegmentRevisions()
        let patch = ActivityStore.ClassificationPatch(
            id: segment.id,
            category: .learning,
            sessionKind: .learning,
            topics: ["swift"]
        )
        try await store.applyClassificationPatches([patch], expectedRevisions: revisions)

        let updated = try await store.segment(id: segment.id)
        checkEqual(updated?.tags ?? [], ["important"], "tags preserved")
        checkEqual(updated?.notes ?? "", "user note", "notes preserved")
        checkEqual(updated?.endAt, segment.endAt, "endAt preserved")
        checkEqual(updated?.category, ActivityCategory.learning, "category applied")
        checkEqual(updated?.sessionKind, SessionKind.learning, "kind applied")
    }

    await runTest("store: a patch derived from a stale snapshot is dropped") {
        let store = TestSupport.makeStore()
        let segment = TestSupport.segment(from: Date().addingTimeInterval(-600), to: Date())
        try await store.insert(segment)
        let staleRevisions = try await store.allSegmentRevisions()

        // The recorder touches the row after the analysis snapshot was taken.
        try await store.applyRecordingTouch(
            id: segment.id,
            windowTitle: "Renamed window",
            urlString: nil,
            domain: nil,
            lastObservedAt: Date(),
            category: .coding,
            sessionKind: .creation,
            topics: []
        )

        let patch = ActivityStore.ClassificationPatch(
            id: segment.id,
            category: .entertainment,
            sessionKind: .distraction,
            topics: []
        )
        try await store.applyClassificationPatches([patch], expectedRevisions: staleRevisions)

        let updated = try await store.segment(id: segment.id)
        checkEqual(updated?.windowTitle ?? "", "Renamed window", "fresher title kept")
        checkEqual(updated?.category, ActivityCategory.coding, "stale category rejected")
        checkEqual(updated?.sessionKind, SessionKind.creation, "stale kind rejected")
    }

    await runTest("store: tags are applied atomically and survive concurrent-style writes") {
        let store = TestSupport.makeStore()
        let segment = TestSupport.segment(from: Date().addingTimeInterval(-600), to: Date(), notes: "keep me")
        try await store.insert(segment)

        try await store.addTag("deep", to: segment.id)
        try await store.addTag("Deep", to: segment.id) // duplicate, case-insensitive
        try await store.setNotes(id: segment.id, notes: "changed later")

        var updated = try await store.segment(id: segment.id)
        checkEqual(updated?.tags ?? [], ["deep"], "tag added once")
        checkEqual(updated?.notes ?? "", "changed later", "note write applied")

        try await store.removeTag("DEEP", from: segment.id)
        updated = try await store.segment(id: segment.id)
        checkEqual(updated?.tags ?? [], [], "tag removed")
        checkEqual(updated?.notes ?? "", "changed later", "note survived removal")
    }

    await runTest("store: capturing a deleted segment reports a miss") {
        let store = TestSupport.makeStore()
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-600),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            urlString: "https://example.com/article",
            domain: "example.com"
        )
        try await store.insert(segment)
        try await store.deleteSegment(id: segment.id)

        let result = try await store.applyCaptureResult(
            id: segment.id,
            contentStatus: .ready,
            contentSummary: "summary",
            classification: nil,
            expectedRevision: 1
        )
        checkEqual(result, false, "deleted segment reports false so content is dropped")
        let content = try await store.content(for: segment.id)
        check(content == nil, "no content persisted")
    }

    await runTest("store: idle backdating reconciles all trailing rows and their content") {
        let directory = TestSupport.makeStoreDirectory()
        let store = ActivityStore(directory: directory)
        let boundary = TestSupport.date(2026, 9, 1, 10)
        let earlier = TestSupport.segment(from: boundary.addingTimeInterval(-1200), to: boundary.addingTimeInterval(-600))
        let crossing = TestSupport.segment(from: boundary.addingTimeInterval(-600), to: boundary.addingTimeInterval(60))
        let trailing = TestSupport.segment(from: boundary.addingTimeInterval(60), to: boundary.addingTimeInterval(120))
        let latest = TestSupport.segment(from: boundary.addingTimeInterval(120), to: boundary.addingTimeInterval(180))
        var idle = TestSupport.segment(from: boundary, to: boundary.addingTimeInterval(180))
        idle.isIdle = true
        let open = ActivitySegment(startAt: boundary.addingTimeInterval(180), appName: "Idle", bundleIdentifier: "lumen.idle", isIdle: true)
        // Deliberately not in chronological order.
        for segment in [latest, earlier, idle, trailing, crossing, open] {
            try await store.insert(segment)
            try await store.upsertContent(ContentArtifact(segmentID: segment.id, kind: .metadata, text: "keep with row"))
        }
        let revisionsBefore = try await store.allSegmentRevisions()

        try await store.trimLastClosedSegment(to: boundary)

        let rows = try await store.allSegments()
        checkEqual(Set(rows.map(\.id)), Set([earlier.id, crossing.id, idle.id, open.id]), "all inactive closed rows removed; idle and open rows kept")
        let trimmed = try await store.segment(id: crossing.id)
        checkEqual(trimmed?.endAt, boundary, "crossing row trimmed after trailing rows removed")
        checkEqual(trimmed?.lastObservedAt, boundary, "heartbeat rewound")
        let revisions = try await store.allSegmentRevisions()
        checkEqual(revisions[crossing.id], (revisionsBefore[crossing.id] ?? 0) + 1, "trim invalidates stale classifications")
        check(revisions[trailing.id] == nil && revisions[latest.id] == nil, "deleted revisions removed")
        let content = try await store.allContent()
        checkEqual(Set(content.map(\.segmentID)), Set(rows.map(\.id)), "content follows removed rows")
        try await store.flush()
        let reloaded = ActivityStore(directory: directory)
        let persisted = try await reloaded.segment(id: crossing.id)
        checkEqual(persisted?.endAt, boundary, "trim persisted")
        let persistedContent = try await reloaded.allContent()
        checkEqual(Set(persistedContent.map(\.segmentID)), Set(rows.map(\.id)), "content cleanup persisted")
    }

    // MARK: F03

    await runTest("store: retention prunes all expired data but keeps saved reports") {
        let store = TestSupport.makeStore()
        let now = Date()
        let old45 = Calendar.current.date(byAdding: .day, value: -45, to: now)!

        let oldSegment = TestSupport.segment(from: old45, to: old45.addingTimeInterval(600))
        let newSegment = TestSupport.segment(from: now.addingTimeInterval(-60), to: now)
        try await store.insert(oldSegment)
        try await store.insert(newSegment)

        try await store.upsertContent(ContentArtifact(segmentID: oldSegment.id, kind: .page, text: "old page"))
        try await store.upsertContent(ContentArtifact(segmentID: UUID(), kind: .page, text: "orphan"))

        try await store.upsertInsight(InsightRecord(dayStart: old45, kind: .learningSummary, title: "Old summary"))
        try await store.upsertInsight(InsightRecord(dayStart: now, kind: .learningSummary, title: "New summary"))

        var oldSession = FocusSession(title: "Old focus", startAt: old45, plannedDuration: 600)
        oldSession.endAt = old45.addingTimeInterval(600)
        oldSession.status = .completed
        try await store.upsertFocusSession(oldSession)

        try await store.upsertWarning(BehaviourWarning(
            createdAt: old45,
            severity: .caution,
            title: "Old warning",
            message: "m",
            expiresAt: nil
        ))

        let oldSnapshot = DailySnapshot(dayStart: old45, markdown: "# Old report", activeSeconds: 600)
        try await store.upsertSnapshot(oldSnapshot)

        let removed = try await store.pruneSegments(olderThan: 30)

        checkEqual(removed, 1, "one old segment removed")
        let segments = try await store.allSegments()
        checkEqual(segments.map(\.id), [newSegment.id], "new segment kept")
        let oldContent = try await store.content(for: oldSegment.id)
        check(oldContent == nil, "old content removed")
        let insights = try await store.allInsights()
        checkEqual(insights.map(\.title), ["New summary"], "old insight removed")
        let sessions = try await store.allFocusSessions()
        check(sessions.isEmpty, "old focus session removed")
        let warnings = try await store.recentWarnings()
        check(warnings.isEmpty, "old warning removed")
        // Saved reports are kept per the documented policy.
        let snapshots = try await store.allSnapshots()
        checkEqual(snapshots.map(\.id), [oldSnapshot.id], "saved report kept")
    }

    await runTest("store: orphan content is cleaned even when no raw segment qualifies") {
        let store = TestSupport.makeStore()
        try await store.upsertContent(ContentArtifact(segmentID: UUID(), kind: .page, text: "orphan"))
        let removed = try await store.pruneSegments(olderThan: 30)
        checkEqual(removed, 0, "no segments qualified")
        let content = try await store.allContent()
        check(content.isEmpty, "orphan content still cleaned")
    }

    // MARK: F11

    await runTest("store: a malformed file is quarantined and the rest of the store loads") {
        let directory = TestSupport.makeStoreDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = "{ this is not json".data(using: .utf8)!
        try original.write(to: directory.appendingPathComponent("segments.json"))

        let store = ActivityStore(directory: directory)
        // Must not throw: healthy recording and analytics continue.
        let segments = try await store.allSegments()
        check(segments.isEmpty, "load continues with empty segments")

        let health = await store.persistenceHealth
        check(health.lastError != nil, "health records the problem")

        // The damaged original was preserved for inspection, not overwritten.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let quarantine = contents.filter { $0.hasPrefix("segments.json.corrupt-") }
        checkEqual(quarantine.count, 1, "quarantine copy created")
        guard let backup = quarantine.first else { return }
        let preserved = try Data(contentsOf: directory.appendingPathComponent(backup))
        checkEqual([UInt8](preserved), [UInt8](original), "original bytes preserved")
    }

    await runTest("store: a newer schema refuses to load") {
        let directory = TestSupport.makeStoreDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        struct FakeMeta: Codable { var schemaVersion: Int; var writtenAt: Date }
        let meta = FakeMeta(schemaVersion: 99, writtenAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: directory.appendingPathComponent("store-meta.json"))

        let store = ActivityStore(directory: directory)
        var threw = false
        do {
            _ = try await store.allSegments()
        } catch {
            threw = true
        }
        check(threw, "newer schema is refused")
    }

    await runTest("store: failed quarantine refuses to accept replacement history") {
        let directory = TestSupport.makeStoreDirectory()
        // Create metadata before making the directory read-only, so this tests
        // the quarantine move rather than a metadata write failure.
        try await ActivityStore(directory: directory).loadIfNeeded()
        let source = directory.appendingPathComponent("segments.json")
        let original = Data("malformed history".utf8)
        try original.write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        guard !FileManager.default.isWritableFile(atPath: directory.path) else {
            // Root can bypass directory permissions; do not claim to exercise
            // the failure branch when this environment cannot enforce it.
            FileHandle.standardError.write(Data("SKIP: quarantine permission test requires an unprivileged user\n".utf8))
            return
        }
        let store = ActivityStore(directory: directory)
        var threw = false
        do {
            _ = try await store.allSegments()
        } catch {
            threw = true
        }
        check(threw, "failed preservation prevents loading empty replacement history")
        checkEqual(try Data(contentsOf: source), original, "only copy remains untouched")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(!files.contains { $0.hasPrefix("segments.json.corrupt-") }, "no backup was falsely reported as saved")
        let health = await store.persistenceHealth
        check(health.lastError?.contains("Preserving segments.json failed") == true, "actual preservation failure surfaced")
    }

    await runTest("store: invalid schema metadata is never silently overwritten") {
        for original in [Data("not json".utf8), Data(#"{"schemaVersion":99,"writtenAt":"invalid-date"}"#.utf8)] {
            let directory = TestSupport.makeStoreDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let marker = directory.appendingPathComponent("store-meta.json")
            try original.write(to: marker)
            let store = ActivityStore(directory: directory)
            var threw = false
            do {
                _ = try await store.allSegments()
            } catch {
                threw = true
            }
            check(threw, "unverifiable schema refuses to load")
            checkEqual(try Data(contentsOf: marker), original, "metadata preserved byte-for-byte")
        }
    }

    await runTest("store: an I/O read failure does not quarantine or replace history") {
        let directory = TestSupport.makeStoreDirectory()
        let source = directory.appendingPathComponent("segments.json", isDirectory: true)
        // Reading a directory as Data fails without relying on user privileges.
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let store = ActivityStore(directory: directory)
        var threw = false
        do {
            _ = try await store.allSegments()
        } catch {
            threw = true
        }
        check(threw, "I/O failure is surfaced rather than treated as empty history")
        var isDirectory: ObjCBool = false
        check(FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue, "original path untouched")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        check(!files.contains { $0.hasPrefix("segments.json.corrupt-") }, "no false corruption quarantine")
        // Retrying after the external I/O problem is fixed still works.
        try FileManager.default.removeItem(at: source)
        let rows = try await store.allSegments()
        check(rows.isEmpty, "load can be retried")
    }

    await runTest("store: failed explicit flush retains data and health clears on recovery") {
        let directory = TestSupport.makeStoreDirectory()
        let store = ActivityStore(directory: directory)
        let segment = TestSupport.segment(from: Date().addingTimeInterval(-600), to: Date())
        try await store.insert(segment)
        try await store.upsertTag(name: "saved independently")
        let blocked = directory.appendingPathComponent("segments.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        var threw = false
        do {
            try await store.flush()
        } catch {
            threw = true
        }
        check(threw, "explicit flush reports failure")
        let failed = await store.persistenceHealth
        checkEqual(failed.failedFileNames, ["segments.json"], "only failed file reported")
        check(failed.lastError != nil, "failure surfaced")
        check(FileManager.default.fileExists(atPath: directory.appendingPathComponent("tags.json").path), "other files still saved")

        try FileManager.default.removeItem(at: blocked)
        try await store.flush()
        let recovered = await store.persistenceHealth
        check(recovered.failedFileNames.isEmpty, "failed files clear on successful retry")
        check(recovered.lastError == nil && recovered.lastErrorAt == nil, "recovered store no longer reports an active failure")
        check(recovered.lastSuccessfulFlushAt != nil, "successful flush recorded")
        let reloaded = ActivityStore(directory: directory)
        let rows = try await reloaded.allSegments()
        checkEqual(rows.map(\.id), [segment.id], "failed write was retained for retry")
    }

    await runTest("store: failed explicit flush retries without another mutation") {
        let directory = TestSupport.makeStoreDirectory()
        let store = ActivityStore(directory: directory)
        let segment = TestSupport.segment(from: Date().addingTimeInterval(-600), to: Date())
        try await store.insert(segment)
        let blocked = directory.appendingPathComponent("segments.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        do {
            try await store.flush()
            check(false, "blocked explicit flush must fail")
        } catch {
            // Expected: the same path can now recover without another mutation.
        }
        try FileManager.default.removeItem(at: blocked)

        // First backoff is six seconds. Poll with headroom for slow CI; do not
        // call flush or mutate the store, which would mask a missing retry.
        let deadline = Date().addingTimeInterval(10)
        var recovered = false
        while Date() < deadline {
            let health = await store.persistenceHealth
            if health.lastSuccessfulFlushAt != nil && health.failedFileNames.isEmpty {
                recovered = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        check(recovered, "scheduled retry saves without another mutation")
        let reloaded = ActivityStore(directory: directory)
        let rows = try await reloaded.allSegments()
        checkEqual(rows.map(\.id), [segment.id], "automatic retry wrote the retained segment")
    }

    // MARK: F14

    await runTest("store: deleting an insight dismisses only that day's occurrence") {
        let store = TestSupport.makeStore()
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!

        let todayInsight = InsightRecord(dayStart: today, kind: .learningSummary, title: "Learning summary")
        try await store.replaceGeneratedInsights(dayStart: today, with: [todayInsight])
        var stored = try await store.insights(on: today)
        checkEqual(stored.count, 1, "generated for today")
        try await store.deleteInsight(id: stored[0].id)

        // Same title tomorrow must still appear.
        let tomorrowInsight = InsightRecord(dayStart: tomorrow, kind: .learningSummary, title: "Learning summary")
        try await store.replaceGeneratedInsights(dayStart: tomorrow, with: [tomorrowInsight])
        stored = try await store.insights(on: tomorrow)
        checkEqual(stored.count, 1, "tomorrow still appears")

        // And regenerating today keeps it suppressed for today only.
        let regenerated = InsightRecord(dayStart: today, kind: .learningSummary, title: "Learning summary")
        try await store.replaceGeneratedInsights(dayStart: today, with: [regenerated])
        stored = try await store.insights(on: today)
        check(stored.isEmpty, "today stays dismissed")
    }

    await runTest("store: muted topics suppress regeneration until reset") {
        let store = TestSupport.makeStore()
        let today = Calendar.current.startOfDay(for: Date())

        try await store.muteTopic("swift")
        let insight = InsightRecord(dayStart: today, kind: .interest, title: "Swift", topics: ["Swift"])
        try await store.replaceGeneratedInsights(dayStart: today, with: [insight])
        var stored = try await store.insights(on: today)
        check(stored.isEmpty, "muted topic suppressed")

        try await store.unmuteAllTopics()
        try await store.replaceGeneratedInsights(dayStart: today, with: [insight])
        stored = try await store.insights(on: today)
        checkEqual(stored.count, 1, "reset restores generation")
    }
}
