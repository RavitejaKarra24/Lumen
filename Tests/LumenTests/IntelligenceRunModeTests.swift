import Foundation
@testable import LumenKit

// F02: the capture preference gates automatic fetching; opening a page runs
// local analysis only; an explicit action may force a fetch. F01: content
// captured for a segment deleted mid-request is dropped.

actor MockCapture: ContentCapturing {
    private(set) var calls: [UUID] = []
    private(set) var cancelledCalls: [UUID] = []
    private var onCapture: (@Sendable (UUID) async -> Void)?

    init(onCapture: (@Sendable (UUID) async -> Void)? = nil) {
        self.onCapture = onCapture
    }

    func setOnCapture(_ action: @escaping @Sendable (UUID) async -> Void) {
        onCapture = action
    }

    func capture(for segment: ActivitySegment) async -> ContentArtifact {
        calls.append(segment.id)
        await onCapture?(segment.id)
        if Task.isCancelled { cancelledCalls.append(segment.id) }
        return ContentArtifact(
            segmentID: segment.id,
            urlString: segment.urlString,
            kind: .page,
            title: segment.windowTitle,
            text: "Captured body text for \(segment.id)"
        )
    }
}

@MainActor
func runIntelligenceModeTests() async {
    func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lumen-tests-\(UUID().uuidString)")!
    }

    func eligibleSegment() -> ActivitySegment {
        TestSupport.segment(
            from: Date().addingTimeInterval(-10 * 60),
            to: Date(),
            appName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            windowTitle: "An interesting article",
            urlString: "https://example.com/article",
            domain: "example.com",
            category: .browsing,
            sessionKind: .research
        )
    }

    await runTest("intelligence: local analysis never fetches, even for eligible sessions") {
        let store = TestSupport.makeStore()
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }

        try await store.insert(eligibleSegment())
        await service.runNow(for: .now, mode: .localOnly)

        check(await mock.calls.isEmpty, "no network request in local-only mode")
    }

    await runTest("intelligence: automatic mode respects a disabled capture preference") {
        let store = TestSupport.makeStore()
        let defaults = makeDefaults()
        defaults.set(false, forKey: "intel.autoCapture")
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: defaults, capture: mock)
        defer { service.stop() }

        try await store.insert(eligibleSegment())
        await service.runNow(for: .now, mode: .automatic)

        check(await mock.calls.isEmpty, "disabled preference means no fetch")
    }

    await runTest("intelligence: automatic mode fetches when the preference is on") {
        let store = TestSupport.makeStore()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "intel.autoCapture")
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: defaults, capture: mock)
        defer { service.stop() }

        try await store.insert(eligibleSegment())
        await service.runNow(for: .now, mode: .automatic)

        checkEqual(await mock.calls.count, 1, "eligible session fetched once")
        // A captured segment is no longer a candidate, and with the preference
        // off nothing else may fetch either.
        service.autoCaptureEnabled = false
        await service.runNow(for: .now, mode: .automatic)
        checkEqual(await mock.calls.count, 1, "no refetch after capture")
    }

    await runTest("intelligence: an explicit fetch runs even with auto-capture off") {
        let store = TestSupport.makeStore()
        let defaults = makeDefaults()
        defaults.set(false, forKey: "intel.autoCapture")
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: defaults, capture: mock)
        defer { service.stop() }

        try await store.insert(eligibleSegment())
        await service.runNow(for: .now, mode: .full)

        checkEqual(await mock.calls.count, 1, "explicit action may fetch")
    }

    await runTest("intelligence: content captured for a segment deleted mid-request is dropped") {
        let store = TestSupport.makeStore()
        let defaults = makeDefaults()
        defaults.set(true, forKey: "intel.autoCapture")
        let segment = eligibleSegment()
        try await store.insert(segment)

        let mock = MockCapture { _ in
            try? await store.deleteSegment(id: segment.id)
        }
        let service = IntelligenceService(store: store, defaults: defaults, capture: mock)
        defer { service.stop() }

        await service.runNow(for: .now, mode: .automatic)

        checkEqual(await mock.calls.count, 1, "capture ran once")
        let content = try await store.content(for: segment.id)
        check(content == nil, "artifact not persisted for the deleted row")
        let all = try await store.allSegments()
        check(all.isEmpty, "segment stays deleted")
    }

    await runTest("intelligence: a queued row deleted by an earlier request is never fetched") {
        let store = TestSupport.makeStore()
        let first = eligibleSegment()
        var queued = eligibleSegment()
        queued.startAt = first.startAt.addingTimeInterval(60)
        let second = queued
        try await store.insert(first)
        try await store.insert(second)
        let mock = MockCapture { id in
            if id == first.id { try? await store.deleteSegment(id: second.id) }
        }
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }

        await service.runNow(mode: .full)

        checkEqual(await mock.calls, [first.id], "deleted queued URL never requested")
        check(try await store.content(for: second.id) == nil, "no orphaned artifact")
    }

    await runTest("intelligence: a changed queued URL is read fresh before fetching") {
        let store = TestSupport.makeStore()
        let first = eligibleSegment()
        var queued = eligibleSegment()
        queued.startAt = first.startAt.addingTimeInterval(60)
        let second = queued
        try await store.insert(first)
        try await store.insert(second)
        let mock = MockCapture { id in
            if id == first.id {
                try? await store.applyRecordingTouch(
                    id: second.id, windowTitle: second.windowTitle,
                    urlString: "https://example.com/revised", domain: second.domain,
                    lastObservedAt: second.lastObservedAt, category: second.category,
                    sessionKind: second.sessionKind, topics: second.topics
                )
            }
        }
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }

        await service.runNow(mode: .full)

        let artifact = try await store.content(for: second.id)
        checkEqual(artifact?.urlString, "https://example.com/revised", "request used the live URL")
    }

    await runTest("intelligence: a URL changed during capture cannot receive old page content") {
        let store = TestSupport.makeStore()
        let segment = eligibleSegment()
        try await store.insert(segment)
        let mock = MockCapture { _ in
            try? await store.applyRecordingTouch(
                id: segment.id, windowTitle: segment.windowTitle,
                urlString: "https://example.com/different", domain: segment.domain,
                lastObservedAt: segment.lastObservedAt, category: segment.category,
                sessionKind: segment.sessionKind, topics: segment.topics
            )
        }
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }

        await service.runNow(mode: .full)

        check(try await store.content(for: segment.id) == nil, "old URL artifact discarded")
        check(try await store.segment(id: segment.id)?.contentStatus != .ready, "new URL not marked captured")
    }

    await runTest("intelligence: disabling capture during a batch prevents subsequent requests") {
        let store = TestSupport.makeStore()
        try await store.insert(eligibleSegment())
        try await store.insert(eligibleSegment())
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }
        await mock.setOnCapture { @MainActor [weak service] _ in
            service?.autoCaptureEnabled = false
        }

        await service.runNow(mode: .automatic)

        checkEqual(await mock.calls.count, 1, "batch stops when preference is disabled")
        checkEqual(await mock.cancelledCalls.count, 1, "in-flight automatic request is cancelled")
        check(try await store.allContent().isEmpty, "cancelled content is not persisted")
    }

    await runTest("intelligence: a pre-cancelled explicit run does not fetch") {
        let store = TestSupport.makeStore()
        try await store.insert(eligibleSegment())
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await service.runNow(mode: .full)
        }
        await task.value
        check(await mock.calls.isEmpty, "cancelled run never fetches")
    }

    await runTest("intelligence: a cancelled waiter exits while another cycle is still running") {
        let store = TestSupport.makeStore()
        try await store.insert(eligibleSegment())
        let mock = MockCapture()
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }
        await mock.setOnCapture { @MainActor [weak service] _ in
            guard let service else { return }
            // The outer cycle remains running until this callback returns.
            let waiter = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await service.runNow(mode: .full)
            }
            await waiter.value
        }

        await service.runNow(mode: .full)

        checkEqual(await mock.calls.count, 1, "cancelled waiter does not run a second capture")
        check(!service.isRunning, "outer cycle completes without a busy wait")
    }

    await runTest("intelligence: cancellation during capture drops the result and stops the batch") {
        let store = TestSupport.makeStore()
        let segment = eligibleSegment()
        try await store.insert(segment)
        try await store.insert(eligibleSegment())
        let mock = MockCapture { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let service = IntelligenceService(store: store, defaults: makeDefaults(), capture: mock)
        defer { service.stop() }
        let task = Task { await service.runNow(mode: .full) }
        await task.value

        let calls = await mock.calls
        checkEqual(calls.count, 1, "no requests after cancellation")
        if let id = calls.first {
            check(try await store.content(for: id) == nil, "cancelled result not persisted")
            checkEqual(try await store.segment(id: id)?.contentStatus, ContentStatus.none, "pending status restored")
        }
        check(service.lastError == nil, "cancellation is not a failure")
    }
}
