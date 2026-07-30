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

    var selectedSidebar: SidebarItem = .today
    var selectedDay: Date = .now
    var analytics: DayAnalytics?
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

    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
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

    init() {
        let stored = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Double
        idleThresholdMinutes = stored ?? 2
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
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
        if permissions.hasAccessibility || !showOnboarding {
            // Start even without AX (still tracks apps); URLs need AX.
            recorder.start()
        }
        refreshAnalytics()
        intelligence.start()
        behaviour.start()
        startPeriodicRefresh()
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
                tagDefinitions = tags
                snapshots = snaps
                insights = dayInsights
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

    func selectDay(_ date: Date) {
        selectedDay = date
        refreshAnalytics()
    }

    func runIntelligence(for day: Date? = nil) async {
        let target = day ?? selectedDay
        await intelligence.runNow(for: target)
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

                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let url = downloads.appendingPathComponent(filename)
                try body.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                setStatus("Exported \(filename)")
            } catch {
                setStatus("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func addTag(_ tag: String, to segmentID: UUID) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        Task {
            do {
                guard var segment = try await store.segment(id: segmentID) else { return }
                if !segment.tags.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                    segment.tags.append(cleaned)
                    try await store.replaceSegment(segment)
                }
                try await store.upsertTag(name: cleaned)
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    func removeTag(_ tag: String, from segmentID: UUID) {
        Task {
            do {
                guard var segment = try await store.segment(id: segmentID) else { return }
                segment.tags = segment.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
                try await store.replaceSegment(segment)
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    func setNotes(_ notes: String, for segmentID: UUID) {
        Task {
            do {
                try await store.setNotes(id: segmentID, notes: notes)
                refreshAnalytics()
            } catch {
                setStatus(error.localizedDescription)
            }
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
            }
        }
    }

    private func applyRetentionPolicy() {
        guard retentionDays > 0 else { return }
        Task {
            let removed = (try? await store.pruneSegments(olderThan: retentionDays)) ?? 0
            if removed > 0 {
                refreshAnalytics(showsProgress: false)
            }
        }
    }
}
