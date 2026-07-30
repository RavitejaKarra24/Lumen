import Foundation

struct AppUsage: Identifiable, Sendable {
    var id: String { bundleIdentifier }
    var appName: String
    var bundleIdentifier: String
    var duration: TimeInterval
    var category: ActivityCategory
}

struct DomainUsage: Identifiable, Sendable {
    var id: String { domain }
    var domain: String
    var duration: TimeInterval
    var visitCount: Int
}

struct CategoryUsage: Identifiable, Sendable {
    var id: String { category.rawValue }
    var category: ActivityCategory
    var duration: TimeInterval
}

/// A stretch of sustained focused work, merged across the many short segments the
/// recorder emits when a window title changes.
struct DeepWorkBlock: Identifiable, Sendable, Hashable {
    var id: Date { start }
    var start: Date
    var end: Date
    /// Wall-clock span, including any brief interruptions bridged into the block.
    var span: TimeInterval { max(0, end.timeIntervalSince(start)) }
    /// Time actually spent on focused work inside the span.
    var focusedDuration: TimeInterval
    var dominantCategory: ActivityCategory
    var appNames: [String]
    /// True when an explicit focus session anchors the block.
    var isFocusSession: Bool
}

struct DayAnalytics: Sendable {
    var dayStart: Date
    var dayEnd: Date
    var activeDuration: TimeInterval
    var idleDuration: TimeInterval
    var focusScore: Double
    var appUsages: [AppUsage]
    var domainUsages: [DomainUsage]
    var categoryUsages: [CategoryUsage]
    var segments: [ActivitySegment]
    var topAppName: String
    var topDomain: String
    var deepWorkDuration: TimeInterval
    var deepWorkBlocks: [DeepWorkBlock]
    var contextSwitches: Int
}

enum AnalyticsService {
    /// A block survives interruptions shorter than this (an app switch, a quick
    /// Slack reply) without being torn in two.
    static let deepWorkGapTolerance: TimeInterval = 2 * 60
    /// Minimum wall-clock span before a run of focused work counts as deep work.
    static let deepWorkMinimumBlock: TimeInterval = 25 * 60

    static func dayInterval(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
    }

    /// Focused work is high-weight categories plus anything the classifier already
    /// judged to be deep work or creation.
    static func isFocusedWork(_ segment: ActivitySegment) -> Bool {
        guard !segment.isIdle else { return false }
        if segment.sessionKind == .deepWork || segment.sessionKind == .creation { return true }
        if segment.sessionKind == .distraction { return false }
        return segment.category.focusWeight >= 0.9
    }

    static func analyze(
        day: Date,
        segments all: [ActivitySegment],
        focusSessions: [FocusSession] = [],
        calendar: Calendar = .current
    ) -> DayAnalytics {
        let (start, end) = dayInterval(for: day, calendar: calendar)
        let segments = all
            .filter { segment in
                let segEnd = segment.endAt ?? .now
                return segment.startAt < end && segEnd >= start
            }
            .sorted { $0.startAt < $1.startAt }
        return analyze(
            segments: segments,
            focusSessions: focusSessions,
            dayStart: start,
            dayEnd: end
        )
    }

    static func analyze(
        segments: [ActivitySegment],
        focusSessions: [FocusSession] = [],
        dayStart: Date,
        dayEnd: Date
    ) -> DayAnalytics {
        var appDurations: [String: (name: String, duration: TimeInterval)] = [:]
        var appCategoryDurations: [String: [ActivityCategory: TimeInterval]] = [:]
        var domainDurations: [String: (duration: TimeInterval, visits: Int)] = [:]
        var categoryDurations: [ActivityCategory: TimeInterval] = [:]

        var active: TimeInterval = 0
        var idle: TimeInterval = 0
        var weightedFocus: TimeInterval = 0
        var activeIntervals: [(start: Date, end: Date)] = []
        var focusedSpans: [FocusedSpan] = []
        var switches = 0
        var previousBundle: String?

        for segment in segments {
            let clipped = clippedDuration(segment, dayStart: dayStart, dayEnd: dayEnd)
            guard clipped > 0 else { continue }

            if segment.isIdle {
                idle += clipped
                // Stepping away and returning to the same app is not a context switch.
                continue
            }

            active += clipped
            weightedFocus += clipped * segment.category.focusWeight
            let clippedStart = max(segment.startAt, dayStart)
            let clippedEnd = min(segment.endAt ?? .now, dayEnd)
            activeIntervals.append((start: clippedStart, end: clippedEnd))

            if isFocusedWork(segment) {
                focusedSpans.append(
                    FocusedSpan(
                        start: clippedStart,
                        end: clippedEnd,
                        category: segment.category,
                        appName: segment.appName,
                        isFocusSession: false
                    )
                )
            }

            let key = segment.bundleIdentifier
            let existing = appDurations[key]
            appDurations[key] = (
                name: segment.appName,
                duration: (existing?.duration ?? 0) + clipped
            )
            appCategoryDurations[key, default: [:]][segment.category, default: 0] += clipped

            categoryDurations[segment.category, default: 0] += clipped

            if let domain = segment.domain, !domain.isEmpty {
                let prior = domainDurations[domain] ?? (0, 0)
                let visitBump = segment.startAt >= dayStart && segment.startAt < dayEnd ? 1 : 0
                domainDurations[domain] = (prior.0 + clipped, prior.1 + visitBump)
            }

            if let previousBundle, previousBundle != key {
                switches += 1
            }
            previousBundle = key
        }

        let apps = appDurations
            .map { bundleIdentifier, usage in
                let category = appCategoryDurations[bundleIdentifier]?
                    .max(by: { $0.value < $1.value })?
                    .key ?? .other
                return AppUsage(
                    appName: usage.name,
                    bundleIdentifier: bundleIdentifier,
                    duration: usage.duration,
                    category: category
                )
            }
            .sorted { $0.duration > $1.duration }

        let domains = domainDurations
            .map { DomainUsage(domain: $0.key, duration: $0.value.duration, visitCount: $0.value.visits) }
            .sorted { $0.duration > $1.duration }

        let categories = categoryDurations
            .map { CategoryUsage(category: $0.key, duration: $0.value) }
            .sorted { $0.duration > $1.duration }

        // Any active time inside an explicit focus session is focused work by
        // definition, whatever the app happened to be.
        for session in focusSessions {
            let focusStart = max(session.startAt, dayStart)
            let focusEnd = min(session.endAt ?? .now, min(session.scheduledEndAt, dayEnd))
            guard focusEnd > focusStart else { continue }
            for activeInterval in activeIntervals {
                let start = max(focusStart, activeInterval.start)
                let end = min(focusEnd, activeInterval.end)
                if end > start {
                    focusedSpans.append(
                        FocusedSpan(
                            start: start,
                            end: end,
                            category: .productivity,
                            appName: session.title,
                            isFocusSession: true
                        )
                    )
                }
            }
        }

        let blocks = deepWorkBlocks(from: focusedSpans)
        let deepWork = blocks.reduce(0) { $0 + $1.focusedDuration }

        let focusScore: Double
        if active > 0 {
            focusScore = min(100, max(0, (weightedFocus / active) * 100))
        } else {
            focusScore = 0
        }

        return DayAnalytics(
            dayStart: dayStart,
            dayEnd: dayEnd,
            activeDuration: active,
            idleDuration: idle,
            focusScore: focusScore,
            appUsages: apps,
            domainUsages: domains,
            categoryUsages: categories,
            segments: segments,
            topAppName: apps.first?.appName ?? "—",
            topDomain: domains.first?.domain ?? "—",
            deepWorkDuration: deepWork,
            deepWorkBlocks: blocks,
            contextSwitches: switches
        )
    }

    // MARK: - Deep work blocks

    struct FocusedSpan: Sendable {
        var start: Date
        var end: Date
        var category: ActivityCategory
        var appName: String
        var isFocusSession: Bool
    }

    /// Merges overlapping and near-adjacent focused spans into blocks, then keeps
    /// the ones long enough to count as deep work.
    ///
    /// The recorder splits a segment on every window-title change, so a two-hour
    /// coding session arrives here as dozens of short spans. Testing each span on
    /// its own would find no deep work at all.
    static func deepWorkBlocks(
        from spans: [FocusedSpan],
        gapTolerance: TimeInterval = deepWorkGapTolerance,
        minimumBlock: TimeInterval = deepWorkMinimumBlock
    ) -> [DeepWorkBlock] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }

        struct Run {
            var start: Date
            var end: Date
            var covered: [(start: Date, end: Date)]
            var categoryTime: [ActivityCategory: TimeInterval]
            var appTime: [String: TimeInterval]
            var isFocusSession: Bool
        }

        var runs: [Run] = []
        for span in sorted {
            let duration = span.end.timeIntervalSince(span.start)
            if var current = runs.last, span.start <= current.end.addingTimeInterval(gapTolerance) {
                current.end = max(current.end, span.end)
                current.covered.append((span.start, span.end))
                current.categoryTime[span.category, default: 0] += duration
                current.appTime[span.appName, default: 0] += duration
                current.isFocusSession = current.isFocusSession || span.isFocusSession
                runs[runs.count - 1] = current
            } else {
                runs.append(
                    Run(
                        start: span.start,
                        end: span.end,
                        covered: [(span.start, span.end)],
                        categoryTime: [span.category: duration],
                        appTime: [span.appName: duration],
                        isFocusSession: span.isFocusSession
                    )
                )
            }
        }

        return runs.compactMap { run -> DeepWorkBlock? in
            // A deliberate focus session always counts, even if it was cut short.
            guard run.isFocusSession || run.end.timeIntervalSince(run.start) >= minimumBlock else {
                return nil
            }
            return DeepWorkBlock(
                start: run.start,
                end: run.end,
                focusedDuration: mergedDuration(run.covered),
                dominantCategory: run.categoryTime.max(by: { $0.value < $1.value })?.key ?? .other,
                appNames: run.appTime
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map(\.key),
                isFocusSession: run.isFocusSession
            )
        }
    }

    static func mergedDuration(_ intervals: [(start: Date, end: Date)]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var current = sorted.first else { return 0 }
        var total: TimeInterval = 0

        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                total += current.end.timeIntervalSince(current.start)
                current = interval
            }
        }
        total += current.end.timeIntervalSince(current.start)
        return total
    }

    /// Deep-work seconds per calendar day across a whole history, in one pass.
    ///
    /// Cheaper than running `analyze` once per day when computing streaks.
    static func deepWorkSecondsByDay(
        segments: [ActivitySegment],
        focusSessions: [FocusSession],
        calendar: Calendar = .current
    ) -> [Date: TimeInterval] {
        var spans: [FocusedSpan] = []
        var activeIntervals: [(start: Date, end: Date)] = []

        for segment in segments where !segment.isIdle {
            let end = segment.endAt ?? .now
            guard end > segment.startAt else { continue }
            activeIntervals.append((segment.startAt, end))
            if isFocusedWork(segment) {
                spans.append(
                    FocusedSpan(
                        start: segment.startAt,
                        end: end,
                        category: segment.category,
                        appName: segment.appName,
                        isFocusSession: false
                    )
                )
            }
        }

        for session in focusSessions {
            let start = session.startAt
            let end = min(session.endAt ?? .now, session.scheduledEndAt)
            guard end > start else { continue }
            for interval in activeIntervals {
                let overlapStart = max(start, interval.start)
                let overlapEnd = min(end, interval.end)
                if overlapEnd > overlapStart {
                    spans.append(
                        FocusedSpan(
                            start: overlapStart,
                            end: overlapEnd,
                            category: .productivity,
                            appName: session.title,
                            isFocusSession: true
                        )
                    )
                }
            }
        }

        var totals: [Date: TimeInterval] = [:]
        for block in deepWorkBlocks(from: spans) {
            // Split the block across midnight so a late-night session is not
            // credited entirely to the day it started on.
            var cursor = block.start
            while cursor < block.end {
                let dayStart = calendar.startOfDay(for: cursor)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? block.end
                let chunkEnd = min(block.end, nextDay)
                totals[dayStart, default: 0] += chunkEnd.timeIntervalSince(cursor)
                cursor = chunkEnd
            }
        }
        return totals
    }

    static func clippedDuration(_ segment: ActivitySegment, dayStart: Date, dayEnd: Date) -> TimeInterval {
        let start = max(segment.startAt, dayStart)
        let end = min(segment.endAt ?? .now, dayEnd)
        return max(0, end.timeIntervalSince(start))
    }
}

enum DurationFormat {
    static func compact(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }
        return String(format: "%ds", seconds)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
