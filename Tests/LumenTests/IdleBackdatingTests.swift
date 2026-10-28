import Foundation
@testable import LumenKit

// F04: the idle boundary comes from last input time, not the polling
// heartbeat, and already-closed rows are reconciled.

func runIdleBackdatingTests() async {
    await runTest("idle: heartbeats during the pre-threshold window are not treated as activity") {
        // Input stopped at 10:00; the recorder wrote heartbeats up to 10:01:30
        // while waiting for the threshold. The close must land at 10:00.
        let openStart = TestSupport.date(2026, 9, 1, 9)
        let idleSince = openStart.addingTimeInterval(3 * 3600) // 10:00
        let now = idleSince.addingTimeInterval(120) // 10:02 tick
        let heartbeat = idleSince.addingTimeInterval(90) // 10:01:30 heartbeat

        let closeStart = ActivityRecorder.idleCloseStart(openStart: openStart, idleSince: idleSince, now: now)
        checkEqual(closeStart, idleSince, "close at last input, not the heartbeat")
        check(closeStart < heartbeat, "the 90 seconds of inactivity are not credited")
    }

    await runTest("idle: the close never precedes the segment start or lands after now") {
        let openStart = TestSupport.date(2026, 9, 1, 10)
        checkEqual(
            ActivityRecorder.idleCloseStart(
                openStart: openStart,
                idleSince: openStart.addingTimeInterval(-30),
                now: openStart.addingTimeInterval(120)
            ),
            openStart,
            "clamped to the segment start"
        )
        checkEqual(
            ActivityRecorder.idleCloseStart(
                openStart: openStart,
                idleSince: openStart.addingTimeInterval(600),
                now: openStart.addingTimeInterval(120)
            ),
            openStart.addingTimeInterval(120),
            "clamped to now"
        )
    }

    await runTest("idle: trailing closed rows are pulled back to the inactivity boundary") {
        let store = TestSupport.makeStore()
        let start = TestSupport.date(2026, 9, 1, 9)
        // A segment that polling closed at 10:05 even though input stopped at 10:00.
        let stale = TestSupport.segment(
            from: start,
            to: start.addingTimeInterval(3600 + 300),
            appName: "Preview",
            bundleIdentifier: "com.apple.Preview"
        )
        try await store.insert(stale)

        let idleBoundary = start.addingTimeInterval(3600) // 10:00
        try await store.trimLastClosedSegment(to: idleBoundary)

        let trimmed = try await store.segment(id: stale.id)
        checkEqual(trimmed?.endAt, idleBoundary, "end pulled back")
        check((trimmed?.lastObservedAt ?? .distantFuture) <= idleBoundary, "observation rewound with it")
    }

    await runTest("idle: a row wholly inside the inactivity window is removed") {
        let store = TestSupport.makeStore()
        let idleStart = TestSupport.date(2026, 9, 1, 10)
        let inflated = TestSupport.segment(
            from: idleStart.addingTimeInterval(60),
            to: idleStart.addingTimeInterval(300),
            appName: "Background",
            bundleIdentifier: "com.example.background"
        )
        try await store.insert(inflated)

        try await store.trimLastClosedSegment(to: idleStart)
        let removed = try await store.segment(id: inflated.id)
        check(removed == nil, "inflated row removed")
    }

    await runTest("idle: all overlapping transitions are replaced without leaving a gap") {
        let store = TestSupport.makeStore()
        let start = TestSupport.date(2026, 9, 1, 9)
        let boundary = start.addingTimeInterval(3600)
        let first = TestSupport.segment(from: start, to: boundary.addingTimeInterval(20))
        let second = TestSupport.segment(
            from: boundary.addingTimeInterval(20), to: boundary.addingTimeInterval(40)
        )
        let open = ActivitySegment(startAt: boundary.addingTimeInterval(40), appName: "Preview", bundleIdentifier: "com.apple.Preview")
        try await store.insert(first)
        try await store.insert(second)
        try await store.insert(open)

        try await ActivityRecorder.recordIdle(
            now: boundary.addingTimeInterval(120), idleSince: boundary,
            recordingSince: start, minimumDuration: 1.5, observationInterval: 30, store: store
        )

        let rows = try await store.allSegments()
        checkEqual(rows.count, 2, "only real work and the idle interval remain")
        checkEqual(rows.first(where: { $0.id == first.id })?.endAt, boundary, "earliest overlap trimmed")
        let idle = rows.first(where: \.isIdle)
        checkEqual(idle?.startAt, boundary, "idle begins where work ends, not at the newest app transition")
        check(idle?.isOpen == true, "idle interval stays open")
    }

    await runTest("idle: resuming recording cannot rewrite history across a pause") {
        let store = TestSupport.makeStore()
        let start = TestSupport.date(2026, 9, 1, 9)
        let previous = TestSupport.segment(from: start, to: start.addingTimeInterval(60))
        try await store.insert(previous)
        let resumed = start.addingTimeInterval(3600)

        try await ActivityRecorder.recordIdle(
            now: resumed.addingTimeInterval(10), idleSince: start.addingTimeInterval(30),
            recordingSince: resumed, minimumDuration: 1.5, observationInterval: 30, store: store
        )

        checkEqual(try await store.segment(id: previous.id), previous, "paused session is untouched")
        checkEqual(try await store.openSegment()?.startAt, resumed, "idle starts at recording restart")
    }

    await runTest("recorder: a heartbeat preserves content-derived classification and topics") {
        let store = TestSupport.makeStore()
        let start = TestSupport.date(2026, 9, 1, 9)
        let segment = ActivitySegment(
            startAt: start, appName: "Safari", bundleIdentifier: "com.apple.Safari",
            windowTitle: "A video", urlString: "https://youtube.com/watch?v=dQw4w9WgXcQ",
            domain: "youtube.com", category: .learning, sessionKind: .learning,
            topics: ["Captured topic"], contentStatus: .ready
        )
        try await store.insert(segment)
        let snapshot = BrowserInspector.Snapshot(
            appName: segment.appName, bundleIdentifier: segment.bundleIdentifier,
            windowTitle: segment.windowTitle, urlString: segment.urlString, pid: 0
        )
        let now = start.addingTimeInterval(60)

        try await ActivityRecorder.recordObservation(
            id: segment.id, snapshot: snapshot, now: now, observationInterval: 30, store: store
        )

        let updated = try await store.segment(id: segment.id)
        checkEqual(updated?.lastObservedAt, now, "heartbeat advances")
        checkEqual(updated?.category, ActivityCategory.learning, "content category preserved")
        checkEqual(updated?.sessionKind, SessionKind.learning, "content kind preserved")
        checkEqual(updated?.topics, ["Captured topic"], "live topics preserved")

        try await store.closeSegment(id: segment.id, at: now, minimumDuration: 0)
        try await ActivityRecorder.recordObservation(
            id: segment.id, snapshot: snapshot, now: now.addingTimeInterval(60),
            observationInterval: 30, store: store
        )
        checkEqual(try await store.segment(id: segment.id)?.lastObservedAt, now, "closed rows are not touched")
    }
}
