import AppKit
import Foundation
import UserNotifications

/// Goalpost 3 orchestrator: goals, warnings, projects, weekly patterns, next-build picks.
@MainActor
@Observable
final class BehaviourEngine {
    private(set) var snapshot: BehaviourSnapshot?
    private(set) var activeWarning: BehaviourWarning?
    private(set) var recentWarnings: [BehaviourWarning] = []
    private(set) var goals: [CreationGoal] = []
    private(set) var projects: [ProjectDefinition] = []
    private(set) var lastEvaluatedAt: Date?
    private(set) var isEvaluating = false
    private(set) var lastError: String?
    private(set) var activeFocusSession: FocusSession?
    private(set) var focusElapsedSeconds: TimeInterval = 0

    // Settings
    var warningsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(warningsEnabled, forKey: "behaviour.warningsEnabled")
            if !warningsEnabled { activeWarning = nil }
        }
    }

    var distractionWarningMinutes: Double {
        didSet { UserDefaults.standard.set(distractionWarningMinutes, forKey: "behaviour.distractWarnMin") }
    }

    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "behaviour.notifications")
            if notificationsEnabled { requestNotificationPermissionIfNeeded() }
        }
    }

    var snoozeMinutes: Double {
        didSet { UserDefaults.standard.set(snoozeMinutes, forKey: "behaviour.snoozeMinutes") }
    }

    var defaultFocusMinutes: Double {
        didSet { UserDefaults.standard.set(defaultFocusMinutes, forKey: "behaviour.focusMinutes") }
    }

    var focusRemainingSeconds: TimeInterval {
        guard let session = activeFocusSession else { return 0 }
        return max(0, session.plannedDuration - focusElapsedSeconds)
    }

    var focusProgress: Double {
        guard let session = activeFocusSession, session.plannedDuration > 0 else { return 0 }
        return min(1, focusElapsedSeconds / session.plannedDuration)
    }

    private let store: ActivityStore
    private var loopTask: Task<Void, Never>?
    private var focusClockTask: Task<Void, Never>?
    private var lastWarningSegmentID: UUID?
    private var lastNotificationAt: Date?
    private var didSeedDefaults = false

    init(store: ActivityStore = .shared) {
        self.store = store
        warningsEnabled = (UserDefaults.standard.object(forKey: "behaviour.warningsEnabled") as? Bool) ?? true
        distractionWarningMinutes = (UserDefaults.standard.object(forKey: "behaviour.distractWarnMin") as? Double) ?? 8
        notificationsEnabled = (UserDefaults.standard.object(forKey: "behaviour.notifications") as? Bool) ?? true
        snoozeMinutes = (UserDefaults.standard.object(forKey: "behaviour.snoozeMinutes") as? Double) ?? 20
        defaultFocusMinutes = (UserDefaults.standard.object(forKey: "behaviour.focusMinutes") as? Double) ?? 25
    }

    func start() {
        requestNotificationPermissionIfNeeded()
        Task { await restoreFocusSession() }
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            while !Task.isCancelled {
                await self?.evaluate(triggerWarnings: true)
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        focusClockTask?.cancel()
        focusClockTask = nil
    }

    func refresh(triggerWarnings: Bool = false) async {
        await evaluate(triggerWarnings: triggerWarnings)
    }

    // MARK: - Focus sessions

    func startFocusSession(title: String? = nil, durationMinutes: Double? = nil) async {
        guard activeFocusSession == nil else { return }
        let minutes = max(1, durationMinutes ?? defaultFocusMinutes)
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionTitle = cleanedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Focus session"
        let session = FocusSession(
            title: sessionTitle,
            plannedDuration: minutes * 60
        )

        do {
            lastError = nil
            try await store.upsertFocusSession(session)
            activeFocusSession = session
            focusElapsedSeconds = 0
            startFocusClock()
            if let warning = activeWarning {
                await dismissWarning(warning)
            }
            await evaluate(triggerWarnings: false)
        } catch {
            lastError = "Could not start focus session: \(error.localizedDescription)"
        }
    }

    func endFocusSession() async {
        await finishFocusSession(status: .endedEarly, endAt: .now)
    }

    func completeRecommendation(_ recommendation: BuildRecommendation) async {
        do {
            let sourceIDs = Set(recommendation.sourceActionIDs + recommendation.sourceIdeaIDs)
            guard !sourceIDs.isEmpty else { return }
            let records = try await store.allInsights()
            for var record in records where sourceIDs.contains(record.id) {
                record.isCompleted = true
                record.updatedAt = .now
                try await store.upsertInsight(record)
            }
            await evaluate(triggerWarnings: false)
        } catch { }
    }

    private func restoreFocusSession() async {
        do {
            guard let session = try await store.activeFocusSession() else { return }
            if session.scheduledEndAt <= .now {
                activeFocusSession = session
                await finishFocusSession(status: .completed, endAt: session.scheduledEndAt)
            } else {
                activeFocusSession = session
                focusElapsedSeconds = session.duration()
                startFocusClock()
            }
        } catch { }
    }

    private func startFocusClock() {
        focusClockTask?.cancel()
        focusClockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let session = self.activeFocusSession else { return }
                self.focusElapsedSeconds = session.duration()
                if self.focusRemainingSeconds <= 0 {
                    await self.finishFocusSession(status: .completed, endAt: session.scheduledEndAt)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func finishFocusSession(status: FocusSessionStatus, endAt: Date) async {
        guard var session = activeFocusSession else { return }
        session.endAt = min(endAt, session.scheduledEndAt)
        session.status = status
        do {
            try await store.upsertFocusSession(session)
        } catch {
            lastError = "Could not save focus session: \(error.localizedDescription)"
            return
        }
        focusClockTask?.cancel()
        focusClockTask = nil
        activeFocusSession = nil
        focusElapsedSeconds = 0
        if status == .completed {
            postFocusCompletionNotification(session)
        }
        await evaluate(triggerWarnings: false)
    }

    // MARK: - CRUD helpers

    func saveGoal(_ goal: CreationGoal) async {
        do {
            try await store.upsertGoal(goal)
            goals = try await store.allGoals()
            await evaluate(triggerWarnings: false)
        } catch { }
    }

    func deleteGoal(_ goal: CreationGoal) async {
        do {
            try await store.deleteGoal(id: goal.id)
            goals = try await store.allGoals()
            await evaluate(triggerWarnings: false)
        } catch { }
    }

    func saveProject(_ project: ProjectDefinition) async {
        do {
            try await store.upsertProject(project)
            projects = try await store.allProjects()
            await evaluate(triggerWarnings: false)
        } catch { }
    }

    func deleteProject(_ project: ProjectDefinition) async {
        do {
            try await store.deleteProject(id: project.id)
            projects = try await store.allProjects()
            await evaluate(triggerWarnings: false)
        } catch { }
    }

    func dismissWarning(_ warning: BehaviourWarning) async {
        var updated = warning
        updated.dismissed = true
        try? await store.upsertWarning(updated)
        if activeWarning?.id == warning.id { activeWarning = nil }
        recentWarnings = (try? await store.recentWarnings(limit: 20)) ?? recentWarnings
    }

    func snoozeWarning(_ warning: BehaviourWarning) async {
        var updated = warning
        updated.snoozedUntil = Date().addingTimeInterval(snoozeMinutes * 60)
        try? await store.upsertWarning(updated)
        if activeWarning?.id == warning.id { activeWarning = nil }
        recentWarnings = (try? await store.recentWarnings(limit: 20)) ?? recentWarnings
    }

    func seedDefaultsIfNeeded() async {
        guard !didSeedDefaults else { return }
        didSeedDefaults = true
        do {
            try await store.loadIfNeeded()
            let existingGoals = try await store.allGoals()
            let defaultsSeededKey = "behaviour.defaultGoalsSeeded"
            if !UserDefaults.standard.bool(forKey: defaultsSeededKey) {
                if existingGoals.isEmpty {
                    let defaults = [
                        CreationGoal(title: "Deep work", metric: .deepWorkMinutes, targetValue: 120),
                        CreationGoal(title: "Creation time", metric: .creationMinutes, targetValue: 90),
                        CreationGoal(title: "Distraction cap", metric: .maxDistractionMinutes, targetValue: 45),
                        CreationGoal(title: "Focus score", metric: .focusScore, targetValue: 65),
                    ]
                    for goal in defaults {
                        try await store.upsertGoal(goal)
                    }
                }
                UserDefaults.standard.set(true, forKey: defaultsSeededKey)
            }
            goals = try await store.allGoals()
            projects = try await store.allProjects()
        } catch { }
    }

    // MARK: - Core evaluation

    private func evaluate(triggerWarnings: Bool) async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer {
            isEvaluating = false
            lastEvaluatedAt = .now
        }

        do {
            await seedDefaultsIfNeeded()

            // One hop to the store actor; all the heavy analysis happens there
            // rather than on the main thread.
            let inputs = try await store.behaviourInputs()

            goals = inputs.goals
            projects = inputs.projects
            recentWarnings = inputs.recentWarnings

            let todayDeep = inputs.todayAnalytics.deepWorkDuration / 60
            let todayDistract = inputs.todayDistractionMinutes

            let goalProgress = goals.map { goal -> GoalProgress in
                let current: Double
                switch goal.metric {
                case .deepWorkMinutes: current = todayDeep
                case .creationMinutes: current = inputs.todayCreationMinutes
                case .learningMinutes: current = inputs.todayLearningMinutes
                case .focusScore: current = inputs.todayAnalytics.focusScore
                case .maxDistractionMinutes: current = todayDistract
                }
                return GoalProgress(goal: goal, currentValue: current, unitLabel: goal.metric.unitLabel)
            }

            let streak = focusStreakDays(deepWorkByDay: inputs.deepWorkByDay)

            if triggerWarnings {
                await maybeEmitDistractionWarning(
                    openSegment: inputs.openSegment,
                    todayDistractMinutes: todayDistract,
                    goalProgress: goalProgress
                )
            }

            // Pick latest active warning
            let active = recentWarnings.first(where: \.isActive)
            activeWarning = active

            snapshot = BehaviourSnapshot(
                generatedAt: .now,
                goalProgress: goalProgress,
                projectScores: inputs.projectScores,
                weekly: inputs.weekly,
                recommendations: inputs.recommendations,
                activeWarning: active,
                todayDistractionMinutes: todayDistract,
                todayDeepWorkMinutes: todayDeep,
                todayCreationMinutes: inputs.todayCreationMinutes,
                focusStreakDays: streak
            )
        } catch {
            // Keep last snapshot
        }
    }

    private func maybeEmitDistractionWarning(
        openSegment open: ActivitySegment?,
        todayDistractMinutes: Double,
        goalProgress: [GoalProgress]
    ) async {
        guard warningsEnabled else {
            activeWarning = nil
            return
        }

        // Snooze global if any warning still snoozed.
        if recentWarnings.contains(where: { ($0.snoozedUntil ?? .distantPast) > .now }) {
            activeWarning = nil
            return
        }

        let currentIsDistraction = open.map {
            $0.sessionKind == .distraction || $0.category == .entertainment
        } ?? false

        var shouldWarn = false
        var severity: WarningSeverity = .caution
        var title = "Distraction alert"
        var message = ""
        var domain = open?.domain
        var appName = open?.appName
        var segmentID = open?.id

        if currentIsDistraction, let open {
            let minutes = open.duration / 60
            if minutes >= distractionWarningMinutes {
                shouldWarn = true
                severity = minutes >= distractionWarningMinutes * 2 ? .critical : .caution
                let label = open.domain ?? open.appName
                title = "Still on \(label)?"
                message = "You've been in a distraction session for \(Int(minutes)) minutes. Return to a creation block?"
            }
        }

        // Daily distraction cap goals
        if let cap = goalProgress.first(where: { $0.goal.metric == .maxDistractionMinutes && $0.goal.isEnabled }),
           !cap.isMet {
            shouldWarn = true
            severity = .critical
            title = "Distraction cap exceeded"
            message = String(
                format: "Today’s distraction is %.0f min (cap %.0f). Time to switch to deep work.",
                cap.currentValue,
                cap.goal.targetValue
            )
            domain = open?.domain
            appName = open?.appName
            segmentID = open?.id
        }

        // Deep work goal lagging late day with high distraction
        let hour = Calendar.current.component(.hour, from: .now)
        if hour >= 16,
           activeFocusSession == nil,
           let deepGoal = goalProgress.first(where: { $0.goal.metric == .deepWorkMinutes && $0.goal.isEnabled }),
           deepGoal.ratio < 0.4,
           todayDistractMinutes > deepGoal.currentValue {
            shouldWarn = true
            if severity != .critical { severity = .caution }
            title = "Deep work behind"
            message = String(
                format: "Deep work %.0f/%.0f min and distraction is winning. Start a focus block now.",
                deepGoal.currentValue,
                deepGoal.goal.targetValue
            )
        }

        guard shouldWarn else {
            if let activeWarning, activeWarning.segmentID != nil {
                await dismissWarning(activeWarning)
            }
            return
        }

        if let existing = recentWarnings.first(where: {
            $0.title == title && $0.isActive && Date().timeIntervalSince($0.createdAt) < 60 * 60
        }) {
            activeWarning = existing
            return
        }

        // Avoid spamming same segment.
        if let segmentID, segmentID == lastWarningSegmentID,
           let last = recentWarnings.first,
           Date().timeIntervalSince(last.createdAt) < 10 * 60 {
            activeWarning = last.isActive ? last : activeWarning
            return
        }

        let warning = BehaviourWarning(
            severity: severity,
            title: title,
            message: message,
            domain: domain,
            appName: appName,
            segmentID: segmentID
        )
        try? await store.upsertWarning(warning)
        recentWarnings = (try? await store.recentWarnings(limit: 20)) ?? [warning]
        activeWarning = warning
        lastWarningSegmentID = segmentID
        postNotification(warning)
    }

    private func minutes(of segments: [ActivitySegment], where pred: (ActivitySegment) -> Bool) -> Double {
        segments.filter(pred).reduce(0.0) { $0 + $1.duration } / 60.0
    }

    /// Consecutive days ending today that cleared the deep-work bar.
    ///
    /// Takes a precomputed per-day table: analysing the full history once per day
    /// of the streak turned every refresh into thirty passes over every segment.
    private func focusStreakDays(deepWorkByDay: [Date: TimeInterval]) -> Int {
        let cal = Calendar.current
        var streak = 0
        var day = cal.startOfDay(for: .now)
        for _ in 0..<365 {
            if (deepWorkByDay[day] ?? 0) >= 30 * 60 {
                streak += 1
            } else if streak == 0 && cal.isDateInToday(day) {
                // Today may simply not be finished yet; don't break the streak on it.
            } else {
                break
            }
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    private func requestNotificationPermissionIfNeeded() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postFocusCompletionNotification(_ session: FocusSession) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Focus session complete"
        content.body = "You completed \(Int(session.plannedDuration / 60)) minutes on \(session.title)."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "focus-\(session.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func postNotification(_ warning: BehaviourWarning) {
        guard notificationsEnabled else { return }
        if let lastNotificationAt, Date().timeIntervalSince(lastNotificationAt) < 15 * 60 {
            return
        }
        lastNotificationAt = .now

        let content = UNMutableNotificationContent()
        content.title = warning.title
        content.body = warning.message
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: warning.id.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
