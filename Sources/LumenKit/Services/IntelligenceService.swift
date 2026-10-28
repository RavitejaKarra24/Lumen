import Foundation

/// What a cycle is allowed to fetch. Local analysis and page capture are
/// separate concerns so a view appearing can never trigger network requests
/// unless the capture preference (or an explicit user action) allows it.
enum IntelligenceRunMode: Sendable {
    /// Background cycle: fetch only when auto-capture is enabled.
    case automatic
    /// Classification + insights only; never touches the network.
    case localOnly
    /// An explicitly chosen fetch/retry action: fetch even when auto-capture is off.
    case full
}

protocol ContentCapturing: Sendable {
    func capture(for segment: ActivitySegment) async -> ContentArtifact
}

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
        didSet {
            defaults.set(autoCaptureEnabled, forKey: "intel.autoCapture")
            if !autoCaptureEnabled, activeCaptureIsAutomatic { activeCaptureTask?.cancel() }
        }
    }

    /// Minimum segment duration before we bother fetching content.
    var minimumCaptureDuration: TimeInterval {
        didSet { defaults.set(minimumCaptureDuration, forKey: "intel.minCaptureDuration") }
    }

    private let store: ActivityStore
    private let capture: any ContentCapturing
    private let defaults: UserDefaults
    private var loopTask: Task<Void, Never>?
    private var activeCaptureTask: Task<ContentArtifact, Never>?
    private var activeCaptureIsAutomatic = false

    init(
        store: ActivityStore = .shared,
        defaults: UserDefaults = .standard,
        capture: any ContentCapturing = ContentCaptureService.shared
    ) {
        self.store = store
        self.defaults = defaults
        self.capture = capture
        let auto = defaults.object(forKey: "intel.autoCapture") as? Bool
        autoCaptureEnabled = auto ?? true
        let minDur = defaults.object(forKey: "intel.minCaptureDuration") as? Double
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
        activeCaptureTask?.cancel()
    }

    /// Explicit analysis. The default mode still respects the capture setting;
    /// pass `.full` only for a deliberate fetch/retry action.
    func runNow(for day: Date = .now, mode: IntelligenceRunMode = .automatic) async {
        while isRunning {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        await runCycle(forceDay: day, mode: mode)
    }

    func report(for day: Date) -> IntelligenceReport? {
        reportsByDay[Calendar.current.startOfDay(for: day)]
    }

    func artifacts(for day: Date) -> [ContentArtifact] {
        artifactsByDay[Calendar.current.startOfDay(for: day)] ?? []
    }

    private func runCycle(forceDay: Date? = nil, mode: IntelligenceRunMode = .automatic) async {
        guard !isRunning, !Task.isCancelled else { return }
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
            // Read revisions first. A mutation between these actor calls then
            // causes a conservative skip, never authorizes stale evidence with
            // a revision obtained after that evidence was read.
            let revisions = try await store.allSegmentRevisions()
            let all = try await store.allSegments()
            try Task.checkCancellation()
            let day = forceDay ?? .now
            let (dayStart, dayEnd) = AnalyticsService.dayInterval(for: day)
            let daySegments = all.filter { segment in
                let end = segment.endAt ?? .now
                return segment.startAt < dayEnd && end >= dayStart
            }

            // 1) Classify all day segments missing kind / refresh closed ones.
            // Classifier-owned fields are written as revision-checked patches:
            // a tag/note/timestamp change that happens during the cycle wins
            // over a result derived from an older snapshot.
            progressLabel = "Updating classifications…"
            let contentByID = try await store.contentMap(for: daySegments.map(\.id))
            var patches: [ActivityStore.ClassificationPatch] = []
            for segment in daySegments where !segment.isIdle {
                let result = SessionClassifier.classify(segment, contentText: contentByID[segment.id]?.text)
                if segment.category != result.category
                    || segment.sessionKind != result.kind
                    || segment.topics != result.topics {
                    patches.append(
                        ActivityStore.ClassificationPatch(
                            id: segment.id,
                            category: result.category,
                            sessionKind: result.kind,
                            topics: result.topics
                        )
                    )
                }
            }
            try await store.applyClassificationPatches(patches, expectedRevisions: revisions)

            // 2) Capture content for eligible browser segments. Local analysis
            // and automatic fetching stay separate: `.localOnly` never fetches,
            // and `.automatic` re-checks the preference between requests so
            // turning capture off stops the batch promptly.
            if mode == .full || (mode == .automatic && autoCaptureEnabled) {
                progressLabel = "Capturing page content…"
                let candidates = daySegments.filter {
                    Self.shouldCapture($0, mode: mode, minimumDuration: minimumCaptureDuration)
                }
                // Prefer longer sessions first; limit per cycle.
                let batch = candidates.sorted { $0.duration > $1.duration }.prefix(mode == .full ? 25 : 6)
                for candidate in batch {
                    try Task.checkCancellation()
                    if mode == .automatic && !autoCaptureEnabled { break }
                    // Earlier requests suspend the cycle. The queued row may
                    // since have been deleted, edited, or captured elsewhere.
                    guard let segment = try await Self.prepareCapture(
                        id: candidate.id, mode: mode,
                        minimumDuration: minimumCaptureDuration, store: store
                    ) else { continue }
                    // The preference can change during the store actor hop too.
                    guard !Task.isCancelled, mode != .automatic || autoCaptureEnabled else {
                        try await Self.restoreCaptureStatus(for: segment, store: store)
                        break
                    }
                    progressLabel = "Fetching \(segment.domain ?? segment.appName)…"
                    let captureTask = Task { await capture.capture(for: segment) }
                    activeCaptureTask = captureTask
                    activeCaptureIsAutomatic = mode == .automatic
                    let artifact = await withTaskCancellationHandler {
                        await captureTask.value
                    } onCancel: {
                        captureTask.cancel()
                    }
                    activeCaptureTask = nil
                    activeCaptureIsAutomatic = false
                    if captureTask.isCancelled {
                        try await Self.restoreCaptureStatus(for: segment, store: store)
                        break
                    } else {
                        try await Self.persistCapture(artifact, for: segment, store: store)
                    }
                }
            }

            // 3) Build insights for the day.
            try Task.checkCancellation()
            progressLabel = "Generating insights…"
            let refreshed = try await store.segments(from: dayStart, to: dayEnd)
            let contentMap = try await store.contentMap(for: refreshed.map(\.id))
            let analysis = InsightEngine.analyze(
                dayStart: dayStart,
                dayEnd: dayEnd,
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
        } catch is CancellationError {
            // A cancelled view/background task is not an analysis failure.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private nonisolated static func shouldCapture(
        _ segment: ActivitySegment, mode: IntelligenceRunMode, minimumDuration: TimeInterval
    ) -> Bool {
        guard !segment.isIdle, segment.duration >= minimumDuration,
              segment.urlString != nil || CategoryClassifier.isBrowser(bundleIdentifier: segment.bundleIdentifier)
        else { return false }
        if segment.contentStatus == .ready { return false }
        if segment.contentStatus == .skipped || segment.contentStatus == .failed { return mode == .full }
        return true
    }

    private static func prepareCapture(
        id: UUID, mode: IntelligenceRunMode, minimumDuration: TimeInterval, store: isolated ActivityStore
    ) throws -> ActivitySegment? {
        guard !Task.isCancelled,
              let segment = try store.segment(id: id),
              shouldCapture(segment, mode: mode, minimumDuration: minimumDuration)
        else { return nil }
        try store.setContentStatus(id: id, status: .pending)
        return segment
    }

    private static func restoreCaptureStatus(
        for captured: ActivitySegment, store: isolated ActivityStore
    ) throws {
        guard let current = try store.segment(id: captured.id), current.contentStatus == .pending else { return }
        let status = current.urlString == captured.urlString ? captured.contentStatus : .none
        try store.setContentStatus(id: captured.id, status: status)
    }

    /// Validation, result patch, and artifact insertion share a single store
    /// actor turn. Deletion cannot slip between them and leave orphaned text.
    private static func persistCapture(
        _ artifact: ContentArtifact, for captured: ActivitySegment, store: isolated ActivityStore
    ) throws {
        guard let current = try store.segmentSnapshot(id: captured.id) else { return }
        guard !Task.isCancelled, current.segment.urlString == captured.urlString, !current.segment.isIdle else {
            try restoreCaptureStatus(for: captured, store: store)
            return
        }
        var updated = current.segment
        updated.contentStatus = artifact.status
        if artifact.status == .ready {
            updated.contentSummary = InsightEngine.summarizeText(artifact.text, maxSentences: 2)
            let result = SessionClassifier.classify(updated, contentText: artifact.text)
            updated.sessionKind = result.kind
            updated.topics = result.topics
            updated.category = result.category
        }
        let applied = try store.applyCaptureResult(
            id: captured.id,
            contentStatus: updated.contentStatus,
            contentSummary: updated.contentSummary,
            classification: ActivityStore.ClassificationPatch(
                id: captured.id, category: updated.category,
                sessionKind: updated.sessionKind, topics: updated.topics
            ),
            expectedRevision: current.revision
        )
        if applied { try store.upsertContent(artifact) }
    }
}

extension ContentCaptureService: ContentCapturing {}
