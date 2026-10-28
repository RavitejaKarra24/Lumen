import Foundation
@testable import LumenKit

// F05: daily deep-work totals and the streak table must agree — merged
// focused intervals, never the gap-inclusive block span.

func runDeepWorkTests() async {
    let calendar = Calendar.current

    await runTest("deep work: 14m + 1m gap + 15m counts as 29 minutes everywhere") {
        let day = TestSupport.date(2026, 9, 1, 12)
        let segments = [
            TestSupport.segment(from: day, to: day.addingTimeInterval(14 * 60)),
            TestSupport.segment(
                from: day.addingTimeInterval(15 * 60),
                to: day.addingTimeInterval(30 * 60)
            ),
        ]
        let dayStart = calendar.startOfDay(for: day)
        let analytics = AnalyticsService.analyze(
            segments: segments,
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400)
        )
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: segments, focusSessions: [])

        checkEqual(analytics.deepWorkDuration, TimeInterval(29 * 60), "daily analytics excludes the gap")
        checkEqual(byDay[dayStart] ?? -1, TimeInterval(29 * 60), "streak table excludes the gap")
    }

    await runTest("deep work: a block crossing midnight contributes only qualifying day portions") {
        // 40-minute block spanning midnight (23:40 -> 00:20): each day's
        // 20-minute piece is too short to qualify on its own, so both
        // calculations must report zero — not the streak table crediting 20
        // minutes the dashboard never shows.
        let start = TestSupport.date(2026, 9, 1, 23, 40)
        let segments = [TestSupport.segment(from: start, to: start.addingTimeInterval(40 * 60))]
        let day1Start = calendar.startOfDay(for: start)
        let day2Start = day1Start.addingTimeInterval(86_400)

        let analyticsDay1 = AnalyticsService.analyze(segments: segments, dayStart: day1Start, dayEnd: day2Start)
        let analyticsDay2 = AnalyticsService.analyze(
            segments: segments,
            dayStart: day2Start,
            dayEnd: day2Start.addingTimeInterval(86_400)
        )
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: segments, focusSessions: [])

        checkEqual(analyticsDay1.deepWorkDuration, TimeInterval(0), "day 1 analytics")
        checkEqual(analyticsDay2.deepWorkDuration, TimeInterval(0), "day 2 analytics")
        checkEqual(byDay[day1Start] ?? -1, TimeInterval(0), "day 1 streak")
        checkEqual(byDay[day2Start] ?? -1, TimeInterval(0), "day 2 streak")
    }

    await runTest("deep work: long midnight-crossing block is credited per day portion") {
        let start = TestSupport.date(2026, 9, 1, 23)
        let segments = [TestSupport.segment(from: start, to: start.addingTimeInterval(2 * 60 * 60))]
        let day1Start = calendar.startOfDay(for: start)
        let day2Start = day1Start.addingTimeInterval(86_400)
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: segments, focusSessions: [])

        checkEqual(byDay[day1Start] ?? -1, TimeInterval(60 * 60), "day 1 portion")
        checkEqual(byDay[day2Start] ?? -1, TimeInterval(60 * 60), "day 2 portion")
    }

    await runTest("deep work: a focus anchor cannot qualify the other side of midnight") {
        let midnight = TestSupport.date(2026, 9, 2)
        let start = midnight.addingTimeInterval(-10 * 60)
        let end = midnight.addingTimeInterval(10 * 60)
        let segments = [TestSupport.segment(from: start, to: end)]
        let firstDay = AnalyticsService.dayInterval(for: start, calendar: calendar)
        let secondDay = AnalyticsService.dayInterval(for: midnight, calendar: calendar)

        // Exercise anchors on both sides: neither tomorrow's nor yesterday's
        // deliberate focus should qualify a short unanchored block today.
        for anchorFirstDay in [true, false] {
            let session = FocusSession(
                title: "Focus",
                startAt: anchorFirstDay ? start : midnight,
                endAt: anchorFirstDay ? midnight : end,
                plannedDuration: 10 * 60,
                status: .completed
            )
            let byDay = AnalyticsService.deepWorkSecondsByDay(
                segments: segments,
                focusSessions: [session],
                calendar: calendar
            )
            for (index, day) in [firstDay, secondDay].enumerated() {
                let analytics = AnalyticsService.analyze(
                    segments: segments,
                    focusSessions: [session],
                    dayStart: day.start,
                    dayEnd: day.end
                )
                let expected: TimeInterval = (index == 0) == anchorFirstDay ? 10 * 60 : 0
                checkEqual(analytics.deepWorkDuration, expected, "dashboard day \(index), first-day anchor \(anchorFirstDay)")
                checkEqual(byDay[day.start] ?? 0, expected, "streak day \(index), first-day anchor \(anchorFirstDay)")
            }
        }
    }

    await runTest("deep work: overlapping segments and focus anchors count covered time once") {
        let start = TestSupport.date(2026, 9, 1, 12)
        let segments = [
            TestSupport.segment(from: start, to: start.addingTimeInterval(20 * 60)),
            TestSupport.segment(from: start.addingTimeInterval(10 * 60), to: start.addingTimeInterval(35 * 60)),
        ]
        let session = FocusSession(
            startAt: start.addingTimeInterval(15 * 60),
            endAt: start.addingTimeInterval(25 * 60),
            plannedDuration: 10 * 60,
            status: .completed
        )
        let analytics = AnalyticsService.analyze(day: start, segments: segments, focusSessions: [session])
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: segments, focusSessions: [session])
        checkEqual(analytics.deepWorkDuration, TimeInterval(35 * 60), "dashboard union")
        checkEqual(byDay[calendar.startOfDay(for: start)] ?? 0, analytics.deepWorkDuration, "streak union")
        checkEqual(analytics.deepWorkBlocks.first?.focusedIntervals.count, 1, "overlapping coverage is merged")
    }

    await runTest("deep work: day splitting follows a 25-hour daylight-saving day") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let day = TestSupport.date(2026, 11, 1, calendar: calendar)
        let interval = AnalyticsService.dayInterval(for: day, calendar: calendar)
        let segments = [TestSupport.segment(from: interval.start, to: interval.end)]
        let analytics = AnalyticsService.analyze(day: day, segments: segments, calendar: calendar)
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: segments, focusSessions: [], calendar: calendar)
        checkEqual(analytics.deepWorkDuration, TimeInterval(25 * 3600), "25-hour dashboard day")
        checkEqual(byDay[interval.start] ?? 0, analytics.deepWorkDuration, "25-hour streak day")
        checkEqual(byDay.count, 1, "no phantom day at the midnight endpoint")
    }

    await runTest("behaviour: a successful refresh clears a prior evaluation error") {
        let directory = TestSupport.makeStoreDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = directory.appendingPathComponent("store-meta.json")
        try Data(#"{"schemaVersion":999,"writtenAt":"2026-09-01T00:00:00Z"}"#.utf8).write(to: metadata)
        let engine = BehaviourEngine(store: ActivityStore(directory: directory))

        await engine.refresh()
        check(engine.lastError != nil, "evaluation failure is visible")
        check(engine.snapshot == nil, "failed evaluation has no snapshot")

        // Repair only this temporary fixture, then retry the same engine/store.
        try FileManager.default.removeItem(at: metadata)
        await engine.refresh()
        check(engine.snapshot != nil, "successful retry produces a snapshot")
        check(engine.lastError == nil, "successful retry clears the stale error")
    }

    await runTest("deep work: an explicit focus session counts even when short") {
        let start = TestSupport.date(2026, 9, 1, 10)
        let session = FocusSession(
            title: "Focus",
            startAt: start,
            endAt: start.addingTimeInterval(10 * 60),
            plannedDuration: 25 * 60,
            status: .endedEarly
        )
        let active = TestSupport.segment(
            from: start,
            to: start.addingTimeInterval(10 * 60),
            category: .browsing,
            sessionKind: .research
        )
        let byDay = AnalyticsService.deepWorkSecondsByDay(segments: [active], focusSessions: [session])
        checkEqual(byDay[calendar.startOfDay(for: start)] ?? -1, TimeInterval(10 * 60), "focus session minutes counted")
    }
}
