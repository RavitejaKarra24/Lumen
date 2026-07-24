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
    var contextSwitches: Int
}

enum AnalyticsService {
    static func dayInterval(for date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return (start, end)
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
        var deepWorkIntervals: [(start: Date, end: Date)] = []
        var switches = 0
        var previousBundle: String?

        for segment in segments {
            let clipped = clippedDuration(segment, dayStart: dayStart, dayEnd: dayEnd)
            guard clipped > 0 else { continue }

            if segment.isIdle {
                idle += clipped
                previousBundle = "lumen.idle"
                continue
            }

            active += clipped
            weightedFocus += clipped * segment.category.focusWeight
            activeIntervals.append((
                start: max(segment.startAt, dayStart),
                end: min(segment.endAt ?? .now, dayEnd)
            ))

            if segment.category.focusWeight >= 0.9, clipped >= 25 * 60 {
                deepWorkIntervals.append((
                    start: max(segment.startAt, dayStart),
                    end: min(segment.endAt ?? .now, dayEnd)
                ))
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

        for session in focusSessions {
            let focusStart = max(session.startAt, dayStart)
            let focusEnd = min(session.endAt ?? .now, min(session.scheduledEndAt, dayEnd))
            guard focusEnd > focusStart else { continue }
            for activeInterval in activeIntervals {
                let start = max(focusStart, activeInterval.start)
                let end = min(focusEnd, activeInterval.end)
                if end > start {
                    deepWorkIntervals.append((start: start, end: end))
                }
            }
        }
        let deepWork = mergedDuration(deepWorkIntervals)

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
            contextSwitches: switches
        )
    }

    private static func mergedDuration(_ intervals: [(start: Date, end: Date)]) -> TimeInterval {
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
