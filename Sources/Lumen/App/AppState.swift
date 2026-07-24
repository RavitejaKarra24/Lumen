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

    private var refreshTask: Task<Void, Never>?
    private var analyticsRefreshTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Double
        idleThresholdMinutes = stored ?? 2
        launchAtLogin = UserDefaults.standard.bool(forKey: "launchAtLogin")
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

    func refreshAnalytics() {
        analyticsRefreshTask?.cancel()
        isRefreshing = true
        let day = selectedDay
        analyticsRefreshTask = Task {
            do {
                try await store.loadIfNeeded()
                let segments = try await store.allSegments()
                let tags = try await store.allTags()
                let snaps = try await store.allSnapshots()
                let focusSessions = try await store.allFocusSessions()
                let dayInsights = try await store.insights(on: day)
                let result = AnalyticsService.analyze(
                    day: day,
                    segments: segments,
                    focusSessions: focusSessions
                )
                guard !Task.isCancelled,
                      Calendar.current.isDate(day, inSameDayAs: selectedDay)
                else { return }
                analytics = result
                tagDefinitions = tags
                snapshots = snaps
                insights = dayInsights
                statusMessage = nil
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
        statusMessage = intelligence.lastError == nil ? "Intelligence updated" : intelligence.lastError
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
            try await store.loadIfNeeded()
            let segments = try await store.allSegments()
            let focusSessions = try await store.allFocusSessions()
            let reportAnalytics = AnalyticsService.analyze(
                day: targetDay,
                segments: segments,
                focusSessions: focusSessions
            )
            let behaviourSnapshot = Calendar.current.isDateInToday(reportAnalytics.dayStart)
                ? behaviour.snapshot
                : nil
            let snapshot = ReportGenerator.makeSnapshot(
                from: reportAnalytics,
                behaviour: behaviourSnapshot
            )
            try await store.upsertSnapshot(snapshot)
            snapshots = try await store.allSnapshots()
            statusMessage = "Report generated"
            return snapshot
        } catch {
            statusMessage = "Report failed: \(error.localizedDescription)"
            return nil
        }
    }

    func exportReportToDownloads() {
        let targetDay = selectedDay
        Task {
            do {
                try await store.loadIfNeeded()
                let segments = try await store.allSegments()
                let focusSessions = try await store.allFocusSessions()
                let analytics = AnalyticsService.analyze(
                    day: targetDay,
                    segments: segments,
                    focusSessions: focusSessions
                )
                let behaviourSnapshot = Calendar.current.isDateInToday(analytics.dayStart)
                    ? behaviour.snapshot
                    : nil
                let md = ReportGenerator.markdown(for: analytics, behaviour: behaviourSnapshot)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let filename = "lumen-\(formatter.string(from: analytics.dayStart)).md"

                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                let url = downloads.appendingPathComponent(filename)
                try md.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self.statusMessage = "Exported \(filename)"
            } catch {
                self.statusMessage = "Export failed: \(error.localizedDescription)"
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
                statusMessage = error.localizedDescription
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
                statusMessage = error.localizedDescription
            }
        }
    }

    func setNotes(_ notes: String, for segmentID: UUID) {
        Task {
            do {
                try await store.setNotes(id: segmentID, notes: notes)
                refreshAnalytics()
            } catch {
                statusMessage = error.localizedDescription
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
                statusMessage = error.localizedDescription
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
                statusMessage = error.localizedDescription
            }
        }
    }

    var menuBarTitle: String {
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

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    self?.permissions.refresh()
                    self?.refreshAnalytics()
                }
                // Behaviour engine has its own loop; light refresh keeps UI in sync.
                await self?.behaviour.refresh(triggerWarnings: false)
            }
        }
    }
}
