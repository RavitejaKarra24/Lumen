import AppKit
import Foundation
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case today
    case timeline
    case apps
    case websites
    case intelligence
    case behaviour
    case tags
    case reports
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .timeline: "Timeline"
        case .apps: "Apps"
        case .websites: "Websites"
        case .intelligence: "Intelligence"
        case .behaviour: "Behaviour"
        case .tags: "Tags"
        case .reports: "Reports"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max.fill"
        case .timeline: "timeline.selection"
        case .apps: "square.grid.2x2.fill"
        case .websites: "globe"
        case .intelligence: "sparkles"
        case .behaviour: "flame.fill"
        case .tags: "tag.fill"
        case .reports: "doc.richtext"
        case .settings: "gearshape.fill"
        }
    }
}

@MainActor
@Observable
final class AppState {
    let recorder = ActivityRecorder()
    let permissions = PermissionManager()
    let store = ActivityStore.shared
    let intelligence = IntelligenceService()
    let behaviour = BehaviourEngine()
    let loginItem = LoginItemController()
    let noteDrafts = NoteDrafts()

    var selectedSidebar: SidebarItem = .today
    var selectedDay: Date = .now
    var analytics: DayAnalytics?
    private(set) var analyticsRevision = 0
    var tagDefinitions: [TagDefinition] = []
    var snapshots: [DailySnapshot] = []
    var insights: [InsightRecord] = []
    var isRefreshing = false
    var statusMessage: String?
    var showOnboarding: Bool = !UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
    var didBootstrap = false

    var idleThresholdMinutes: Double {
        didSet {
            UserDefaults.standard.set(idleThresholdMinutes, forKey: "idleThresholdMinutes")
            recorder.updateIdleThreshold(idleThresholdMinutes * 60)
        }
    }

    /// Show the current app or site as text next to the menu bar icon. Off by
    /// default: the title changes on every app switch and shuffles the menu bar.
    var showMenuBarTitle: Bool {
        didSet { UserDefaults.standard.set(showMenuBarTitle, forKey: "showMenuBarTitle") }
    }

    /// Days of raw activity to keep. 0 keeps everything.
    var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: "retentionDays")
            applyRetentionPolicy()
        }
    }

    private var refreshTask: Task<Void, Never>?
    private var analyticsRefreshTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?
    private var lastRetentionRunAt: Date?
    private var isApplyingRetention = false
    private var surfacedPersistenceError: String?
    private var surfacedRecorderError: String?

    init() {
        let stored = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Double
        idleThresholdMinutes = stored ?? 2
        showMenuBarTitle = UserDefaults.standard.bool(forKey: "showMenuBarTitle")
        retentionDays = (UserDefaults.standard.object(forKey: "retentionDays") as? Int) ?? 0
    }

    func bootstrap() {
        guard !didBootstrap else {
            refreshAnalytics()
            return
        }
        didBootstrap = true
        recorder.updateIdleThreshold(idleThresholdMinutes * 60)
        permissions.refresh()
        loginItem.refresh()
        if permissions.hasAccessibility || !showOnboarding {
            // Start even without AX (still tracks apps); URLs need AX.
            recorder.start()
        }
        refreshAnalytics()
        intelligence.start()
        behaviour.start()
        startPeriodicRefresh()
        // didSet does not fire for values loaded during init, so retention is
        // applied explicitly here and then kept on a daily schedule.
        applyRetentionPolicy()
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
        showOnboarding = false
        permissions.refresh()
        recorder.start()
        intelligence.start()
        behaviour.start()
        refreshAnalytics()
    }

    func startRecordingIfPossible() {
        permissions.refresh()
        recorder.start()
        refreshAnalytics()
    }

    func stopRecording() {
        recorder.stop()
    }

    /// - Parameter showsProgress: background ticks pass `false` so the spinner
    ///   does not flash every few seconds while the user is reading.
    func refreshAnalytics(showsProgress: Bool = true) {
        analyticsRefreshTask?.cancel()
        if showsProgress { isRefreshing = true }
        let day = selectedDay
        analyticsRefreshTask = Task {
            do {
                // The store analyses the day on its own actor, so only the finished
                // result crosses back to the main thread.
                let result = try await store.analytics(for: day)
                let tags = try await store.allTags()
                let snaps = try await store.allSnapshots()
                let dayInsights = try await store.insights(on: day)
                guard !Task.isCancelled,
                      Calendar.current.isDate(day, inSameDayAs: selectedDay)
                else { return }
                analytics = result
                analyticsRevision += 1
                tagDefinitions = tags
                snapshots = snaps
                insights = dayInsights
                surfacePersistenceHealth()
                if statusMessage?.hasPrefix("Failed to load analytics") == true {
                    statusMessage = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                statusMessage = "Failed to load analytics: \(error.localizedDescription)"
            }
            if !Task.isCancelled {
                isRefreshing = false
            }
        }
    }

    /// Saves are batched and retried in the background; when the store reports a
    /// problem the user hears about it here instead of losing data silently.
    private func surfacePersistenceHealth() {
        if let error = recorder.lastError {
            if surfacedRecorderError != error {
                surfacedRecorderError = error
                setStatus("Recording failed: \(error)")
            }
        } else {
            surfacedRecorderError = nil
        }
        Task {
            let health = await store.persistenceHealth
            guard let error = health.lastError else {
                surfacedPersistenceError = nil
                return
            }
            guard error != surfacedPersistenceError else { return }
            surfacedPersistenceError = error
            setStatus("Data may not be saved — \(error)")
        }
    }

    func selectDay(_ date: Date) {
        selectedDay = date
        refreshAnalytics()
    }

    /// - Parameter mode: `.automatic` respects the capture setting; `.localOnly`
    ///   never fetches; `.full` is an explicit fetch/retry action and may fetch
    ///   even with auto-capture off.
    func runIntelligence(for day: Date? = nil, mode: IntelligenceRunMode = .automatic) async {
        let target = day ?? selectedDay
        await intelligence.runNow(for: target, mode: mode)
        await behaviour.refresh(triggerWarnings: false)
        refreshAnalytics()
        setStatus(intelligence.lastError == nil ? "Intelligence updated" : intelligence.lastError)
    }

    func refreshBehaviour(triggerWarnings: Bool = false) async {
        await behaviour.refresh(triggerWarnings: triggerWarnings)
    }

    var actionInsights: [InsightRecord] {
        insights.filter { $0.kind == .actionItem }
    }

    var ideaInsights: [InsightRecord] {
        insights.filter { $0.kind == .idea }
    }

    func toggleInsightCompleted(_ insight: InsightRecord) {
        Task {
            var updated = insight
            updated.isCompleted.toggle()
            updated.updatedAt = .now
            try? await store.upsertInsight(updated)
            insights = (try? await store.insights(on: selectedDay)) ?? insights
        }
    }

    func toggleInsightPinned(_ insight: InsightRecord) {
        Task {
            var updated = insight
            updated.isPinned.toggle()
            updated.updatedAt = .now
            try? await store.upsertInsight(updated)
            insights = (try? await store.insights(on: selectedDay)) ?? insights
        }
    }

    func deleteInsight(_ insight: InsightRecord) {
        Task {
            try? await store.deleteInsight(id: insight.id)
            insights = (try? await store.insights(on: selectedDay)) ?? insights
        }
    }

    func content(for segmentID: UUID) async -> ContentArtifact? {
        try? await store.content(for: segmentID)
    }

    @discardableResult
    func generateReport(for day: Date? = nil) async -> DailySnapshot? {
        let targetDay = day ?? selectedDay
        do {
            let reportAnalytics = try await store.analytics(for: targetDay)
            let behaviourSnapshot = Calendar.current.isDateInToday(reportAnalytics.dayStart)
                ? behaviour.snapshot
                : nil
            let snapshot = ReportGenerator.makeSnapshot(
                from: reportAnalytics,
                behaviour: behaviourSnapshot
            )
            try await store.upsertSnapshot(snapshot)
            snapshots = try await store.allSnapshots()
            setStatus("Report generated")
            return snapshot
        } catch {
            setStatus("Report failed: \(error.localizedDescription)")
            return nil
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case csv

        var id: String { rawValue }
        var fileExtension: String { self == .markdown ? "md" : "csv" }
        var displayName: String { self == .markdown ? "Markdown" : "CSV" }
    }

    /// Exports the report for the selected day, regenerated from raw activity.
    /// A saved snapshot can be exported verbatim with `exportSavedReport`.
    func exportReportToDownloads(format: ExportFormat = .markdown) {
        let targetDay = selectedDay
        Task {
            do {
                let analytics = try await store.analytics(for: targetDay)
                let behaviourSnapshot = Calendar.current.isDateInToday(analytics.dayStart)
                    ? behaviour.snapshot
                    : nil
                let body: String
                switch format {
                case .markdown:
                    body = ReportGenerator.markdown(for: analytics, behaviour: behaviourSnapshot)
                case .csv:
                    body = ReportGenerator.csv(for: analytics)
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let filename = "lumen-\(formatter.string(from: analytics.dayStart)).\(format.fileExtension)"
                let url = try writeExport(body, filename: filename)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                setStatus("Exported \(url.lastPathComponent)")
            } catch {
                setStatus("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Exports the stored Markdown of a saved report exactly as it was
    /// generated. Used from History: after retention removes raw sessions, a
    /// regenerated export would be empty or materially different.
    func exportSavedReport(_ snapshot: DailySnapshot, format: ExportFormat = .markdown) {
        Task {
            do {
                switch format {
                case .markdown:
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd"
                    let filename = "lumen-saved-\(formatter.string(from: snapshot.dayStart)).md"
                    let url = try writeExport(snapshot.markdown, filename: filename)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    setStatus("Exported \(url.lastPathComponent)")
                case .csv:
                    // CSV rows come from raw sessions; once retention has pruned
                    // them there is nothing faithful to serialize.
                    setStatus("CSV is unavailable for this day — its raw sessions are gone. Export the saved Markdown instead.")
                }
            } catch {
                setStatus("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Writes beside previous exports without silently replacing them.
    private func writeExport(_ body: String, filename: String) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let proposed = downloads.appendingPathComponent(filename)
        let url: URL
        if FileManager.default.fileExists(atPath: proposed.path) {
            let base = proposed.deletingPathExtension().lastPathComponent
            let ext = proposed.pathExtension
            var counter = 2
            var candidate = downloads.appendingPathComponent("\(base)-\(counter).\(ext)")
            while FileManager.default.fileExists(atPath: candidate.path) {
                counter += 1
                candidate = downloads.appendingPathComponent("\(base)-\(counter).\(ext)")
            }
            url = candidate
        } else {
            url = proposed
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func addTag(_ tag: String, to segmentID: UUID) {
        Task {
            do {
                // Atomic store operation: the tag lands on the live row, and a
                // concurrent analysis write cannot resurrect a stale tag list.
                try await store.addTag(tag, to: segmentID)
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    func removeTag(_ tag: String, from segmentID: UUID) {
        Task {
            do {
                try await store.removeTag(tag, from: segmentID)
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    /// Returns false when the save failed so callers can keep the draft.
    @discardableResult
    func setNotes(_ notes: String, for segmentID: UUID) async -> Bool {
        do {
            try await store.setNotes(id: segmentID, notes: notes)
            refreshAnalytics()
            return true
        } catch {
            setStatus("Note not saved: \(error.localizedDescription)")
            return false
        }
    }

    func revealDataFolder() {
        let directory = ActivityStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func createTagDefinition(name: String, colorHex: String = "#5B8DEF") {
        Task {
            do {
                try await store.upsertTag(name: name, colorHex: colorHex)
                tagDefinitions = try await store.allTags()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    func deleteTagDefinition(_ tag: TagDefinition) {
        Task {
            do {
                try await store.deleteTag(id: tag.id)
                tagDefinitions = try await store.allTags()
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    var menuBarTitle: String {
        // A running focus session is worth the menu bar space unconditionally —
        // a live countdown is the reason to look up there.
        if behaviour.activeFocusSession != nil {
            return DurationFormat.clock(behaviour.focusRemainingSeconds)
        }
        guard showMenuBarTitle else { return "" }
        if let warning = behaviour.activeWarning, warning.isActive {
            return short(warning.title)
        }
        if recorder.isCurrentlyIdle {
            return "Idle"
        }
        if let snap = recorder.currentSnapshot {
            if let url = snap.urlString, let host = CategoryClassifier.domain(from: url) {
                return short(host)
            }
            return short(snap.appName)
        }
        return "Lumen"
    }

    var menuBarSymbol: String {
        if behaviour.activeFocusSession != nil { return "timer" }
        if let warning = behaviour.activeWarning, warning.isActive {
            return warning.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        }
        if !permissions.hasAccessibility { return "exclamationmark.triangle" }
        if !recorder.isRunning { return "pause.circle" }
        if recorder.isCurrentlyIdle { return "moon.zzz" }
        return "circle.fill"
    }

    private func short(_ text: String) -> String {
        if text.count <= 18 { return text }
        return String(text.prefix(16)) + "…"
    }

    /// Shows a transient message in the header and clears it on its own, so a
    /// stale "Report generated" does not sit there for the rest of the session.
    func setStatus(_ message: String?) {
        statusMessage = message
        statusClearTask?.cancel()
        guard message != nil else { return }
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                // The behaviour engine runs its own loop; refreshing it here too
                // ran the whole history through the analyser twice as often.
                self?.permissions.refresh()
                self?.refreshAnalytics(showsProgress: false)
                // Retention runs once per calendar day (and after wake, since
                // the timer keeps firing) without touching Settings.
                if self?.retentionDue() == true {
                    self?.applyRetentionPolicy()
                }
            }
        }
    }

    private func retentionDue() -> Bool {
        guard let last = lastRetentionRunAt else { return true }
        return !Calendar.current.isDate(last, inSameDayAs: .now)
    }

    private func applyRetentionPolicy() {
        guard retentionDays > 0, !isApplyingRetention else { return }
        let days = retentionDays
        isApplyingRetention = true
        Task {
            defer { isApplyingRetention = false }
            do {
                let removed = try await store.pruneSegments(olderThan: days)
                // A failed run must remain due, and a policy changed during
                // this await still needs its own run on the next tick.
                if retentionDays == days { lastRetentionRunAt = .now }
                else { lastRetentionRunAt = nil }
                if removed > 0 {
                    refreshAnalytics(showsProgress: false)
                }
            } catch {
                setStatus("Retention failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Insight muting (F14)

    func muteTopic(of insight: InsightRecord) {
        Task {
            do {
                try await store.muteTopic(insight.title)
                for topic in insight.topics {
                    try await store.muteTopic(topic)
                }
                insights = (try? await store.insights(on: selectedDay)) ?? insights
                setStatus("Muted “\(insight.title)” — it will not regenerate. Reset in Settings.")
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    func resetMutedTopics() async {
        do {
            try await store.unmuteAllTopics()
            insights = (try? await store.insights(on: selectedDay)) ?? insights
            setStatus("Muted topics reset")
        } catch {
            setStatus(error.localizedDescription)
        }
    }

    func resetDismissedInsights() async {
        do {
            try await store.resetDismissedInsights()
            insights = (try? await store.insights(on: selectedDay)) ?? insights
            setStatus("Dismissed insights restored; run intelligence to regenerate them")
        } catch {
            setStatus(error.localizedDescription)
        }
    }
}
