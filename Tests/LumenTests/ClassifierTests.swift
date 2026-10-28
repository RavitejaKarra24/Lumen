import Foundation
@testable import LumenKit

// F10: classification must be unambiguous, token-aware, and recomputable from
// base evidence.

func runClassifierTests() async {
    await runTest("classifier: Figma is design, not coding") {
        let category = CategoryClassifier.classify(
            bundleIdentifier: "com.figma.Desktop",
            appName: "Figma",
            domain: nil
        )
        checkEqual(category, ActivityCategory.design, "Figma bundle")
    }

    await runTest("classifier: a window titled async.swift is not a meeting") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            windowTitle: "async.swift — MyApp",
            category: .coding,
            sessionKind: .creation
        )
        let result = SessionClassifier.classify(segment, extractTopics: false)
        check(result.kind != .meeting, "async.swift must not match the sync keyword")
        checkEqual(result.category, ActivityCategory.coding, "still coding")
    }

    await runTest("classifier: 11:10 in a standup title does not corrupt the match") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            appName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            windowTitle: "Standup moved to 11:10",
            category: .productivity
        )
        let result = SessionClassifier.classify(segment, extractTopics: false)
        // "standup" still matches as its own token; the time must not break it.
        checkEqual(result.kind, SessionKind.meeting, "standup still a meeting")
    }

    await runTest("classifier: calendar time without meeting words is admin") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            appName: "Calendar",
            bundleIdentifier: "com.apple.iCal",
            windowTitle: "Dentist at 11:10",
            category: .productivity
        )
        let result = SessionClassifier.classify(segment, extractTopics: false)
        checkEqual(result.kind, SessionKind.admin, "no meeting keywords matched")
    }

    await runTest("classifier: educational YouTube content reclassifies entertainment") {
        var segment = TestSupport.segment(
            from: Date().addingTimeInterval(-600),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Funny cats compilation",
            domain: "www.youtube.com",
            category: .entertainment,
            sessionKind: .distraction
        )
        let first = SessionClassifier.classify(segment, contentText: nil, extractTopics: false)
        checkEqual(first.kind, SessionKind.distraction, "entertainment before content arrives")

        // Captured transcript arrives later; classification must recompute from
        // the new evidence instead of trusting the stored entertainment kind.
        segment.sessionKind = first.kind
        let reclassified = SessionClassifier.classify(
            segment,
            contentText: "In this tutorial we build a Swift app step by step and learn the language fundamentals.",
            extractTopics: false
        )
        checkEqual(reclassified.kind, SessionKind.learning, "responds to new evidence")
        checkEqual(reclassified.category, ActivityCategory.learning, "category follows")
    }

    await runTest("classifier: keyword boundaries stop latest matching test/build") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Release notes for the latest version",
            domain: "example.org",
            category: .browsing
        )
        let result = SessionClassifier.classify(segment, extractTopics: false)
        // Plain browsing is research; substring hits on "test" inside "latest"
        // would have made it deep work.
        checkEqual(result.kind, SessionKind.research, "browsing stays research")
        checkEqual(result.category, ActivityCategory.browsing, "category stays browsing")
    }

    await runTest("classifier: educational word forms survive token-boundary matching") {
        let end = TestSupport.date(2026, 9, 1, 12)
        for title in ["Guitar tutorials", "Cooking lessons", "Learning piano", "Ocean documentaries", "Algorithms", "SwiftUI navigation"] {
            let segment = TestSupport.segment(
                from: end.addingTimeInterval(-600),
                to: end,
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                windowTitle: title,
                domain: "youtube.com",
                category: .learning,
                sessionKind: .learning
            )
            let result = SessionClassifier.classify(segment, extractTopics: false)
            checkEqual(result.kind, SessionKind.learning, "educational video: \(title)")
            checkEqual(result.category, ActivityCategory.learning, "educational category: \(title)")
        }
    }

    await runTest("classifier: educational keywords still reject accidental substrings") {
        let end = TestSupport.date(2026, 9, 1, 12)
        for title in ["Trust no one", "Offcourse adventures", "The latest highlights"] {
            let segment = TestSupport.segment(
                from: end.addingTimeInterval(-600),
                to: end,
                appName: "Safari",
                bundleIdentifier: "com.apple.Safari",
                windowTitle: title,
                domain: "youtube.com",
                category: .learning
            )
            let result = SessionClassifier.classify(segment, extractTopics: false)
            checkEqual(result.kind, SessionKind.distraction, "no educational token: \(title)")
            checkEqual(result.category, ActivityCategory.entertainment, "no sticky learning category: \(title)")
        }
    }

    await runTest("classifier: plural meeting keywords remain meetings") {
        let end = TestSupport.date(2026, 9, 1, 12)
        for title in ["Weekly meetings", "Candidate interviews", "Morning standups", "Daily syncs"] {
            let segment = TestSupport.segment(
                from: end.addingTimeInterval(-600),
                to: end,
                appName: "Calendar",
                bundleIdentifier: "com.apple.iCal",
                windowTitle: title,
                category: .productivity
            )
            let result = SessionClassifier.classify(segment, extractTopics: false)
            checkEqual(result.kind, SessionKind.meeting, "plural meeting token: \(title)")
            checkEqual(result.category, ActivityCategory.communication, "meeting category: \(title)")
        }
    }

    await runTest("classifier: educational interviews are not live meetings") {
        let end = Date.now
        let segment = TestSupport.segment(
            from: end.addingTimeInterval(-600), to: end,
            appName: "Safari", bundleIdentifier: "com.apple.Safari",
            windowTitle: "Interview with an architect — tutorial", domain: "youtube.com",
            category: .entertainment
        )
        let result = SessionClassifier.classify(segment, contentText: "Our teams sync weekly.", extractTopics: false)
        checkEqual(result.kind, SessionKind.learning, "educational content outranks meeting words")
    }

    await runTest("classifier: genuine meeting apps still classify as meetings") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            appName: "Zoom",
            bundleIdentifier: "us.zoom.xos",
            category: .communication
        )
        let result = SessionClassifier.classify(segment, extractTopics: false)
        checkEqual(result.kind, SessionKind.meeting, "Zoom is a meeting")
        checkEqual(result.category, ActivityCategory.communication, "communication")
    }

    await runTest("classifier: documentation mentioning meetings stays learning") {
        let segment = TestSupport.segment(
            from: Date().addingTimeInterval(-60),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "Developer documentation: meetings and scheduling API",
            domain: "developer.apple.com",
            category: .learning
        )
        let result = SessionClassifier.classify(
            segment,
            contentText: "Meetings, interviews, and syncs are examples in this API guide.",
            extractTopics: false
        )
        checkEqual(result.kind, SessionKind.learning, "docs are not a meeting")
        checkEqual(result.category, ActivityCategory.learning, "docs stay learning")
    }
}
