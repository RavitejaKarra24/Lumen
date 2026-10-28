import Foundation
@testable import LumenKit

enum TestSupport {
    /// A fresh, unique store directory per test.
    static func makeStoreDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    static func makeStore() -> ActivityStore {
        ActivityStore(directory: makeStoreDirectory())
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    /// A closed, non-idle segment between two dates.
    static func segment(
        from start: Date,
        to end: Date,
        appName: String = "Xcode",
        bundleIdentifier: String = "com.apple.dt.Xcode",
        windowTitle: String = "",
        urlString: String? = nil,
        domain: String? = nil,
        category: ActivityCategory = .coding,
        sessionKind: SessionKind = .deepWork,
        tags: [String] = [],
        notes: String = ""
    ) -> ActivitySegment {
        ActivitySegment(
            startAt: start,
            endAt: end,
            lastObservedAt: end,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowTitle: windowTitle,
            urlString: urlString,
            domain: domain,
            isIdle: false,
            category: category,
            notes: notes,
            tags: tags,
            sessionKind: sessionKind
        )
    }
}
