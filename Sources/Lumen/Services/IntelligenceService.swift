import Foundation

/// Orchestrates content capture, classification, and insight generation.
@MainActor
@Observable
final class IntelligenceService {
    private(set) var isRunning = false
    private(set) var lastRunAt: Date?
    private(set) var lastError: String?
    private(set) var progressLabel: String = ""
    private(set) var report: IntelligenceReport?
    private(set) var insights: [InsightRecord] = []
    private(set) var recentArtifacts: [ContentArtifact] = []
    private var reportsByDay: [Date: IntelligenceReport] = [:]
    private var artifactsByDay: [Date: [ContentArtifact]] = [:]

    var autoCaptureEnabled: Bool {
        didSet { UserDefaults.standard.set(autoCaptureEnabled, forKey: "intel.autoCapture") }
    }

    /// Minimum segment duration before we bother fetching content.
    var minimumCaptureDuration: TimeInterval {
        didSet { UserDefaults.standard.set(minimumCaptureDuration, forKey: "intel.minCaptureDuration") }
    }

    private let store: ActivityStore
    private let capture = ContentCaptureService.shared
    private var loopTask: Task<Void, Never>?

    init(store: ActivityStore = .shared) {
        self.store = store
        let auto = UserDefaults.standard.object(forKey: "intel.autoCapture") as? Bool
        autoCaptureEnabled = auto ?? true
        let minDur = UserDefaults.standard.object(forKey: "intel.minCaptureDuration") as? Double
        minimumCaptureDuration = minDur ?? 45
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            // Initial delay so recorder can create segments first.
            try? await Task.sleep(for: .seconds(8))
            while !Task.isCancelled {
                await self?.runCycle()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func runNow(for day: Date = .now) async {
        while isRunning {
            try? await Task.sleep(for: .milliseconds(200))
        }
        await runCycle(forceDay: day, forceAll: true)
    }

    func report(for day: Date) -> IntelligenceReport? {
        reportsByDay[Calendar.current.startOfDay(for: day)]
    }

    func artifacts(for day: Date) -> [ContentArtifact] {
        artifactsByDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    private func runCycle(forceDay: Date? = nil, forceAll: Bool = false) async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        progressLabel = "Classifying sessions…"
        defer {
            isRunning = false
            progressLabel = ""
            lastRunAt = .now
        }

        do {
            try await store.loadIfNeeded()
            let all = try await store.allSegments()
            let day = forceDay ?? .now
            let (dayStart, dayEnd) = AnalyticsService.dayInterval(for: day)
            let daySegments = all.filter { segment in
                let end = segment.endAt ?? .now
                return segment.startAt < dayEnd && end >= dayStart
            }

            // 1) Classify all day segments missing kind / refresh closed ones.
            progressLabel = "Updating classifications…"
            for segment in daySegments where !segment.isIdle {
                let content = try await store.content(for: segment.id)
                let result = SessionClassifier.classify(segment, contentText: content?.text)
                var updated = segment
                var dirty = false
                if updated.sessionKind != result.kind {
                    updated.sessionKind = result.kind
                    dirty = true
                }
                if updated.topics != result.topics {
                    updated.topics = result.topics
                    dirty = true
                }
                if updated.category != result.category {
                    updated.category = result.category
                    dirty = true
                }
                if dirty {
                    try await store.replaceSegment(updated)
                }
            }

            // 2) Capture content for eligible browser segments.
            if autoCaptureEnabled || forceAll {
                progressLabel = "Capturing page content…"
                let candidates = daySegments.filter { segment in
                    guard !segment.isIdle else { return false }
                    guard segment.duration >= minimumCaptureDuration else { return false }
                    guard segment.urlString != nil || CategoryClassifier.isBrowser(bundleIdentifier: segment.bundleIdentifier) else {
                        return false
                    }
                    if segment.contentStatus == .ready || segment.contentStatus == .skipped {
                        return forceAll && segment.contentStatus != .ready
                    }
                    // Don't hammer failures every cycle unless forced.
                    if segment.contentStatus == .failed, !forceAll { return false }
                    return true
                }
                // Prefer longer sessions first; limit per cycle.
                let batch = candidates.sorted { $0.duration > $1.duration }.prefix(forceAll ? 25 : 6)
                for segment in batch {
                    progressLabel = "Fetching \(segment.domain ?? segment.appName)…"
                    var pending = segment
                    pending.contentStatus = .pending
                    try await store.replaceSegment(pending)

                    let artifact = await capture.capture(for: segment)
                    try await store.upsertContent(artifact)

                    var updated = try await store.segment(id: segment.id) ?? segment
                    updated.contentStatus = artifact.status
                    if artifact.status == .ready {
                        updated.contentSummary = InsightEngine.summarizeText(artifact.text, maxSentences: 2)
                        let reclass = SessionClassifier.classify(updated, contentText: artifact.text)
                        updated.sessionKind = reclass.kind
                        updated.topics = reclass.topics
                        updated.category = reclass.category
                    }
                    try await store.replaceSegment(updated)
                }
            }

            // 3) Build insights for the day.
            progressLabel = "Generating insights…"
            let refreshed = try await store.segments(from: dayStart, to: dayEnd)
            let contentMap = try await store.contentMap(for: refreshed.map(\.id))
            let analysis = InsightEngine.analyze(
                dayStart: dayStart,
                segments: refreshed,
                contentBySegment: contentMap
            )

            // Replace auto-generated insights for the day; keep user-pinned/completed.
            try await store.replaceGeneratedInsights(dayStart: dayStart, with: analysis.insights)

            let artifacts = Array(
                contentMap.values
                    .sorted { $0.fetchedAt > $1.fetchedAt }
                    .prefix(12)
            )
            self.report = analysis.report
            self.insights = try await store.insights(on: dayStart)
            self.recentArtifacts = artifacts
            self.reportsByDay[dayStart] = analysis.report
            self.artifactsByDay[dayStart] = artifacts
        } catch {
            lastError = error.localizedDescription
        }
    }
}
