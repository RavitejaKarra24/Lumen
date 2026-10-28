import Foundation
@testable import LumenKit

// F06: every daily metric is clipped to the selected day.

func runDayClippingTests() async {
    let calendar = Calendar.current

    await runTest("clipping: a session crossing midnight gives each day its own 10 minutes") {
        let day1Start = calendar.startOfDay(for: TestSupport.date(2026, 9, 1))
        let day2Start = day1Start.addingTimeInterval(86_400)
        let session = TestSupport.segment(
            from: day1Start.addingTimeInterval(23 * 3600 + 50 * 60),
            to: day2Start.addingTimeInterval(10 * 60),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Swift tutorial",
            domain: "docs.swift.org",
            category: .learning,
            sessionKind: .learning
        )

        checkEqual(
            AnalyticsService.clippedDuration(session, dayStart: day1Start, dayEnd: day2Start),
            TimeInterval(10 * 60),
            "day 1 portion"
        )
        checkEqual(
            AnalyticsService.clippedDuration(session, dayStart: day2Start, dayEnd: day2Start.addingTimeInterval(86_400)),
            TimeInterval(10 * 60),
            "day 2 portion"
        )

        let analyticsDay1 = AnalyticsService.analyze(segments: [session], dayStart: day1Start, dayEnd: day2Start)
        checkEqual(analyticsDay1.activeDuration, TimeInterval(10 * 60), "headline active duration")
    }

    await runTest("clipping: a session ending exactly at midnight contributes nothing to the next day") {
        let day1Start = calendar.startOfDay(for: TestSupport.date(2026, 9, 1))
        let day2Start = day1Start.addingTimeInterval(86_400)
        let session = TestSupport.segment(from: day1Start.addingTimeInterval(3600), to: day2Start)
        checkEqual(
            AnalyticsService.clippedDuration(session, dayStart: day2Start, dayEnd: day2Start.addingTimeInterval(86_400)),
            TimeInterval(0),
            "next-day portion is zero"
        )
    }

    await runTest("clipping: behaviour goal minutes match the clipped totals") {
        let store = TestSupport.makeStore()
        let day1Start = calendar.startOfDay(for: TestSupport.date(2026, 9, 1))
        let day2Start = day1Start.addingTimeInterval(86_400)
        let session = TestSupport.segment(
            from: day1Start.addingTimeInterval(23 * 3600 + 50 * 60),
            to: day2Start.addingTimeInterval(10 * 60),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            domain: "docs.swift.org",
            category: .learning,
            sessionKind: .learning
        )
        try await store.insert(session)

        let noon1 = day1Start.addingTimeInterval(12 * 3600)
        let noon2 = day2Start.addingTimeInterval(12 * 3600)
        let inputsDay1 = try await store.behaviourInputs(now: noon1)
        let inputsDay2 = try await store.behaviourInputs(now: noon2)

        checkEqual(inputsDay1.todayLearningMinutes, 10.0, "day 1 learning minutes")
        checkEqual(inputsDay2.todayLearningMinutes, 10.0, "day 2 learning minutes")
    }

    await runTest("clipping: interests use the same day portion as the learning summary") {
        let day = AnalyticsService.dayInterval(for: TestSupport.date(2026, 9, 1), calendar: calendar)
        var session = TestSupport.segment(
            from: day.end.addingTimeInterval(-10 * 60),
            to: day.end.addingTimeInterval(110 * 60),
            windowTitle: "Astronomy",
            category: .learning,
            sessionKind: .learning
        )
        session.topics = ["astronomy"]
        let (report, insights) = InsightEngine.analyze(
            dayStart: day.start,
            dayEnd: day.end,
            segments: [session],
            contentBySegment: [:]
        )
        checkEqual(report.interests.first?.duration ?? -1, TimeInterval(10 * 60), "interest time is day-clipped")
        checkEqual(report.interests.first?.score ?? -1, Double(10 * 60 + 90), "interest score uses day time")
        check(report.learningSummary.contains("10m 00s"), "summary agrees with interests")
        check(insights.contains { $0.kind == .interest && $0.body.contains("10m 00s") }, "interest blurb agrees")
    }

    await runTest("clipping: zero-overlap rows cannot generate daily insights or content counts") {
        let day = AnalyticsService.dayInterval(for: TestSupport.date(2026, 9, 1), calendar: calendar)
        var included = TestSupport.segment(
            from: day.start.addingTimeInterval(3600),
            to: day.start.addingTimeInterval(4200),
            category: .learning,
            sessionKind: .learning,
            notes: "TODO: Keep today's task"
        )
        included.topics = ["astronomy"]
        let before = TestSupport.segment(
            from: day.start.addingTimeInterval(-3600),
            to: day.start,
            windowTitle: "Yesterday only",
            category: .learning,
            sessionKind: .learning,
            notes: "TODO: Ignore yesterday's task"
        )
        let after = TestSupport.segment(
            from: day.end,
            to: day.end.addingTimeInterval(3600),
            windowTitle: "Tomorrow only",
            category: .learning,
            sessionKind: .learning,
            notes: "TODO: Ignore tomorrow's task"
        )
        let content = [
            included.id: ContentArtifact(segmentID: included.id, kind: .page, text: "Today's page"),
            before.id: ContentArtifact(segmentID: before.id, kind: .transcript, text: "Yesterday's transcript"),
            after.id: ContentArtifact(segmentID: after.id, kind: .transcript, text: "Tomorrow's transcript"),
        ]
        let (report, insights) = InsightEngine.analyze(
            dayStart: day.start,
            dayEnd: day.end,
            segments: [before, included, after],
            contentBySegment: content
        )
        checkEqual(report.classifiedCounts[.learning] ?? 0, 1, "only overlapping session counted")
        checkEqual(report.capturedContentCount, 1, "only today's captured content counted")
        checkEqual(report.transcriptCount, 0, "boundary-only transcripts excluded")
        checkEqual(report.actionItems.map(\.title), ["Keep today's task"], "boundary-only notes excluded")
        checkEqual(insights.first { $0.kind == .learningSummary }?.sourceSegmentIDs, [included.id], "summary sources are day-scoped")
        check(!report.learningSummary.contains("Yesterday only"), "no zero-duration highlight")
        check(!report.learningSummary.contains("Tomorrow only"), "no future highlight")
    }

    await runTest("clipping: a long learning session cannot seed an idea from a short day portion") {
        let day = AnalyticsService.dayInterval(for: TestSupport.date(2026, 9, 1), calendar: calendar)
        var session = TestSupport.segment(
            from: day.end.addingTimeInterval(-2 * 60),
            to: day.end.addingTimeInterval(30 * 60),
            windowTitle: "Astronomy",
            category: .learning,
            sessionKind: .learning
        )
        session.topics = ["astronomy"]
        let (report, _) = InsightEngine.analyze(
            dayStart: day.start,
            dayEnd: day.end,
            segments: [session],
            contentBySegment: [:]
        )
        checkEqual(report.ideas.count, 0, "two-minute day portion does not meet the eight-minute idea threshold")
    }

    await runTest("clipping: learning summary reports the day portion, not the full session") {
        let day1Start = calendar.startOfDay(for: TestSupport.date(2026, 9, 1))
        let day2Start = day1Start.addingTimeInterval(86_400)
        let session = TestSupport.segment(
            from: day1Start.addingTimeInterval(23 * 3600 + 50 * 60),
            to: day2Start.addingTimeInterval(10 * 60),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            domain: "docs.swift.org",
            category: .learning,
            sessionKind: .learning
        )
        let (report, _) = InsightEngine.analyze(
            dayStart: day1Start,
            dayEnd: day2Start,
            segments: [session],
            contentBySegment: [:]
        )
        check(report.learningSummary.contains("10m 00s"), "summary shows the day portion")
        check(!report.learningSummary.contains("20m"), "summary does not show the full session")
    }
}
