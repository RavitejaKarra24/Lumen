import Foundation

enum WeeklyPatternAnalyzer {
    static func analyze(
        segments: [ActivitySegment],
        endingOn day: Date = .now,
        interests: [InterestSignal] = []
    ) -> WeeklyPatternReport {
        let cal = Calendar.current
        let endDay = cal.startOfDay(for: day)
        let endExclusive = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay.addingTimeInterval(86400)
        let start = cal.date(byAdding: .day, value: -6, to: endDay) ?? endDay.addingTimeInterval(-6 * 86400)

        let window = segments.filter { segment in
            guard !segment.isIdle else { return false }
            let segEnd = segment.endAt ?? .now
            return segment.startAt < endExclusive && segEnd >= start
        }

        var hourActive = Array(repeating: 0.0, count: 24)
        var hourDeep = Array(repeating: 0.0, count: 24)
        var hourDistract = Array(repeating: 0.0, count: 24)

        // weekday: 1=Sun ... 7=Sat (Calendar)
        var dayActive: [Int: TimeInterval] = [:]
        var dayDeep: [Int: TimeInterval] = [:]
        var dayDistract: [Int: TimeInterval] = [:]
        var dayFocusWeighted: [Int: (weighted: TimeInterval, active: TimeInterval)] = [:]

        var totalActive: TimeInterval = 0
        var totalDeep: TimeInterval = 0
        var totalDistract: TimeInterval = 0
        var totalWeighted: TimeInterval = 0

        for segment in window {
            var cursor = max(segment.startAt, start)
            let segmentEnd = min(segment.endAt ?? .now, endExclusive)
            while cursor < segmentEnd {
                let hourStart = cal.dateInterval(of: .hour, for: cursor)?.start ?? cursor
                let nextHour = cal.date(byAdding: .hour, value: 1, to: hourStart) ?? segmentEnd
                let chunkEnd = min(segmentEnd, nextHour)
                let duration = chunkEnd.timeIntervalSince(cursor)
                guard duration > 0 else { break }

                totalActive += duration
                totalWeighted += duration * segment.category.focusWeight
                let isDeep = segment.sessionKind == .deepWork || segment.sessionKind == .creation
                let isDistraction = segment.sessionKind == .distraction
                if isDeep { totalDeep += duration }
                if isDistraction { totalDistract += duration }

                let hour = cal.component(.hour, from: cursor)
                hourActive[hour] += duration
                if isDeep { hourDeep[hour] += duration }
                if isDistraction { hourDistract[hour] += duration }

                let weekday = cal.component(.weekday, from: cursor)
                dayActive[weekday, default: 0] += duration
                if isDeep { dayDeep[weekday, default: 0] += duration }
                if isDistraction { dayDistract[weekday, default: 0] += duration }
                var focus = dayFocusWeighted[weekday] ?? (0, 0)
                focus.active += duration
                focus.weighted += duration * segment.category.focusWeight
                dayFocusWeighted[weekday] = focus

                cursor = chunkEnd
            }
        }

        let hourBuckets = (0..<24).map { hour in
            HourBucket(
                hour: hour,
                activeDuration: hourActive[hour],
                deepWorkDuration: hourDeep[hour],
                distractionDuration: hourDistract[hour]
            )
        }

        let weekdaySymbols = cal.shortWeekdaySymbols // Sun...Sat
        let weekdayBuckets: [WeekdayBucket] = (1...7).map { wd in
            let focusPair = dayFocusWeighted[wd] ?? (0, 0)
            let focus = focusPair.active > 0 ? (focusPair.weighted / focusPair.active) * 100 : 0
            return WeekdayBucket(
                weekday: wd,
                label: weekdaySymbols[wd - 1],
                activeDuration: dayActive[wd] ?? 0,
                focusScore: focus,
                deepWorkDuration: dayDeep[wd] ?? 0,
                distractionDuration: dayDistract[wd] ?? 0
            )
        }

        let bestFocusHour = hourBuckets
            .filter { $0.deepWorkDuration > 60 }
            .max(by: { $0.deepWorkDuration < $1.deepWorkDuration })?
            .hour

        let worstDistractHour = hourBuckets
            .filter { $0.distractionDuration > 60 }
            .max(by: { $0.distractionDuration < $1.distractionDuration })?
            .hour

        let bestWeekday = weekdayBuckets
            .filter { $0.activeDuration > 15 * 60 }
            .max(by: { $0.focusScore < $1.focusScore })?
            .label

        let avgFocus = totalActive > 0 ? (totalWeighted / totalActive) * 100 : 0

        let narrative = buildNarrative(
            totalActive: totalActive,
            totalDeep: totalDeep,
            totalDistract: totalDistract,
            avgFocus: avgFocus,
            bestFocusHour: bestFocusHour,
            worstDistractionHour: worstDistractHour,
            bestWeekday: bestWeekday,
            interests: interests
        )

        return WeeklyPatternReport(
            generatedAt: .now,
            rangeStart: start,
            rangeEnd: endDay,
            totalActive: totalActive,
            totalDeepWork: totalDeep,
            totalDistraction: totalDistract,
            averageFocusScore: avgFocus,
            bestFocusHour: bestFocusHour,
            worstDistractionHour: worstDistractHour,
            bestWeekday: bestWeekday,
            hourBuckets: hourBuckets,
            weekdayBuckets: weekdayBuckets,
            topInterests: Array(interests.prefix(8)),
            narrative: narrative
        )
    }

    private static func buildNarrative(
        totalActive: TimeInterval,
        totalDeep: TimeInterval,
        totalDistract: TimeInterval,
        avgFocus: Double,
        bestFocusHour: Int?,
        worstDistractionHour: Int?,
        bestWeekday: String?,
        interests: [InterestSignal]
    ) -> String {
        var lines: [String] = []
        lines.append(
            "Last 7 days: \(DurationFormat.compact(totalActive)) active · \(DurationFormat.compact(totalDeep)) deep/creation · \(DurationFormat.compact(totalDistract)) distraction · focus \(Int(avgFocus.rounded()))."
        )
        if let hour = bestFocusHour {
            lines.append("Deep work peaks around \(formatHour(hour)).")
        }
        if let hour = worstDistractionHour {
            lines.append("Distractions cluster near \(formatHour(hour)).")
        }
        if let day = bestWeekday {
            lines.append("\(day) tends to be your highest-focus day.")
        }
        if let top = interests.first {
            lines.append("Strongest recurring interest: \(top.topic).")
        }
        if totalDeep > totalDistract * 1.5 {
            lines.append("Creation is beating distraction — protect the streak.")
        } else if totalDistract > totalDeep {
            lines.append("Distraction is outpacing deep work. Set a creation goal and a distraction cap.")
        }
        return lines.joined(separator: " ")
    }

    private static func formatHour(_ hour: Int) -> String {
        var comps = DateComponents()
        comps.hour = hour
        let cal = Calendar.current
        let date = cal.date(from: comps) ?? Date()
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f.string(from: date).lowercased()
    }
}
