import AppKit
import Foundation

/// Polls the frontmost app/URL and writes continuous ActivitySegment rows.
@MainActor
@Observable
final class ActivityRecorder {
    private(set) var isRunning = false
    private(set) var currentSnapshot: BrowserInspector.Snapshot?
    private(set) var isCurrentlyIdle = false
    private(set) var lastTickAt: Date?
    private(set) var secondsIdle: TimeInterval = 0
    private(set) var openSegmentID: UUID?

    var pollInterval: TimeInterval = 2.0
    var idleThreshold: TimeInterval = 120
    /// Minimum duration before a segment is kept when it ends (filters flicker).
    var minimumSegmentDuration: TimeInterval = 1.5

    private let store: ActivityStore
    private var timer: Timer?
    private var transitionTask: Task<Void, Never>?
    private let inspector = BrowserInspector()
    private var idleDetector = IdleDetector(threshold: 120)
    private var workspaceObservers: [NSObjectProtocol] = []

    init(store: ActivityStore = .shared) {
        self.store = store
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        idleDetector = IdleDetector(threshold: idleThreshold)
        installWorkspaceObservers()
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        Task { await stopAndClose() }
    }

    func stopAndClose() async {
        isRunning = false
        timer?.invalidate()
        timer = nil
        removeWorkspaceObservers()
        let pending = transitionTask
        await pending?.value
        await closeOpenSegment(at: .now)
    }

    func updateIdleThreshold(_ value: TimeInterval) {
        idleThreshold = value
        idleDetector = IdleDetector(threshold: value)
    }

    // MARK: - Tick

    private func tick() {
        guard isRunning, transitionTask == nil else { return }
        lastTickAt = .now

        secondsIdle = idleDetector.secondsIdle()
        let idle = secondsIdle >= idleThreshold
        isCurrentlyIdle = idle

        let snapshot = inspector.captureFrontmost()
        currentSnapshot = snapshot

        let now = Date.now
        transitionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.transitionTask = nil }
            do {
                try await self.store.loadIfNeeded()
                let open = try await self.store.openSegment()
                if idle {
                    try await self.handleIdle(now: now, open: open)
                } else if let snapshot {
                    try await self.handleActive(snapshot: snapshot, now: now, open: open)
                }
                self.openSegmentID = try await self.store.openSegment()?.id
            } catch {
                // Keep running; surface later via AppState if needed.
            }
        }
    }

    private func handleIdle(now: Date, open: ActivitySegment?) async throws {
        if let open {
            if open.isIdle {
                try await touch(open, at: now)
                return
            }
            try await store.closeSegment(id: open.id, at: now, minimumDuration: minimumSegmentDuration)
        }

        if try await store.openSegment() == nil {
            let segment = ActivitySegment(
                startAt: now,
                appName: "Idle",
                bundleIdentifier: "lumen.idle",
                windowTitle: "Away",
                isIdle: true,
                category: .other,
                sessionKind: .idle
            )
            try await store.insert(segment)
        }
    }

    private func handleActive(
        snapshot: BrowserInspector.Snapshot,
        now: Date,
        open: ActivitySegment?
    ) async throws {
        let domain = CategoryClassifier.domain(from: snapshot.urlString)
        let baseCategory = CategoryClassifier.classify(
            bundleIdentifier: snapshot.bundleIdentifier,
            appName: snapshot.appName,
            domain: domain
        )

        if let open {
            if open.isIdle {
                try await store.closeSegment(id: open.id, at: now, minimumDuration: minimumSegmentDuration)
            } else if sameContext(open, snapshot: snapshot) {
                var updated = open
                if updated.windowTitle != snapshot.windowTitle {
                    updated.windowTitle = snapshot.windowTitle
                }
                if updated.urlString != snapshot.urlString {
                    updated.urlString = snapshot.urlString
                    updated.domain = domain
                }
                if now.timeIntervalSince(updated.lastObservedAt ?? updated.startAt) >= 10 {
                    updated.lastObservedAt = now
                }
                // Lightweight live reclassify on title/url drift.
                if updated != open {
                    var probe = updated
                    probe.category = baseCategory
                    let classified = SessionClassifier.classify(probe)
                    updated.category = classified.category
                    updated.sessionKind = classified.kind
                    updated.topics = classified.topics
                    try await store.replaceSegment(updated)
                }
                return
            } else {
                try await store.closeSegment(id: open.id, at: now, minimumDuration: minimumSegmentDuration)
            }
        }

        var segment = ActivitySegment(
            startAt: now,
            appName: snapshot.appName,
            bundleIdentifier: snapshot.bundleIdentifier,
            windowTitle: snapshot.windowTitle,
            urlString: snapshot.urlString,
            domain: domain,
            isIdle: false,
            category: baseCategory
        )
        let classified = SessionClassifier.classify(segment)
        segment.category = classified.category
        segment.sessionKind = classified.kind
        segment.topics = classified.topics
        try await store.insert(segment)
    }

    private func sameContext(
        _ segment: ActivitySegment,
        snapshot: BrowserInspector.Snapshot
    ) -> Bool {
        if segment.bundleIdentifier != snapshot.bundleIdentifier {
            return false
        }
        if CategoryClassifier.isBrowser(bundleIdentifier: snapshot.bundleIdentifier) {
            return normalizedTrackingURL(segment.urlString) == normalizedTrackingURL(snapshot.urlString)
        }
        return normalizedTitle(segment.windowTitle) == normalizedTitle(snapshot.windowTitle)
    }

    private func normalizedTrackingURL(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value) else { return value }
        components.fragment = nil
        components.queryItems = components.queryItems?
            .filter {
                let name = $0.name.lowercased()
                return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
            }
            .sorted { $0.name < $1.name }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func touch(_ segment: ActivitySegment, at date: Date) async throws {
        guard date.timeIntervalSince(segment.lastObservedAt ?? segment.startAt) >= 10 else { return }
        var updated = segment
        updated.lastObservedAt = date
        try await store.replaceSegment(updated)
    }

    private func closeAfterPendingTransition(at date: Date) async {
        let pending = transitionTask
        await pending?.value
        await closeOpenSegment(at: date)
    }

    private func closeOpenSegment(at date: Date) async {
        do {
            if let open = try await store.openSegment() {
                try await store.closeSegment(id: open.id, at: date, minimumDuration: minimumSegmentDuration)
            }
            openSegmentID = nil
        } catch {
            // ignore
        }
    }

    // MARK: - Workspace

    private func installWorkspaceObservers() {
        removeWorkspaceObservers()
        let center = NSWorkspace.shared.notificationCenter
        let obs = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        workspaceObservers.append(obs)

        let sleepObs = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.closeAfterPendingTransition(at: .now)
            }
        }
        workspaceObservers.append(sleepObs)

        let wakeObs = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        workspaceObservers.append(wakeObs)
    }

    private func removeWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            center.removeObserver(obs)
        }
        workspaceObservers.removeAll()
    }
}
