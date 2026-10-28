import SwiftUI

struct BehaviourView: View {
    @Environment(AppState.self) private var appState
    @State private var newProjectName = ""
    @State private var newProjectKeywords = ""
    @State private var editingGoal: CreationGoal?
    @State private var showGoalSheet = false

    var body: some View {
        let engine = appState.behaviour
        let snap = engine.snapshot

        VStack(spacing: 0) {
            header(engine: engine)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = engine.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if let warning = engine.activeWarning {
                        warningBanner(warning)
                    }

                    FocusSessionCard()
                    nextBuildCard(snap?.recommendations ?? [], engine: engine)
                    goalsCard(snap?.goalProgress ?? [])
                    HStack(alignment: .top, spacing: 16) {
                        weeklyCard(snap?.weekly)
                        streakCard(snap)
                    }
                    projectsCard(snap?.projectScores ?? [], engine: engine)
                    warningsHistory(engine.recentWarnings)
                }
                .padding(24)
            }
        }
        .navigationTitle("Behaviour")
        .sheet(isPresented: $showGoalSheet) {
            GoalEditorSheet(goal: editingGoal) { goal in
                Task { await engine.saveGoal(goal) }
            }
        }
        .onAppear {
            Task { await appState.refreshBehaviour() }
        }
    }

    private func header(engine: BehaviourEngine) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Behaviour")
                    .font(.largeTitle.weight(.semibold))
                Text(engine.lastEvaluatedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                     ?? "Goals · warnings · projects · weekly patterns · next build")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await appState.refreshBehaviour(triggerWarnings: true) }
            } label: {
                if engine.isEvaluating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .buttonStyle(.bordered)
            .disabled(engine.isEvaluating)
        }
        .padding(20)
    }

    private func warningBanner(_ warning: BehaviourWarning) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: warning.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(warning.severity == .critical ? .red : .orange)
                Text(warning.title)
                    .font(.headline)
                Spacer()
                Text(warning.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(warning.message)
                .font(.callout)
            HStack {
                Button("Start \(Int(appState.behaviour.defaultFocusMinutes))m Focus") {
                    Task {
                        await appState.behaviour.startFocusSession(
                            title: appState.behaviour.snapshot?.recommendations.first?.title
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.behaviour.activeFocusSession != nil)
                Button("Snooze \(Int(appState.behaviour.snoozeMinutes))m") {
                    Task { await appState.behaviour.snoozeWarning(warning) }
                }
                .buttonStyle(.bordered)
                Button("Dismiss") {
                    Task { await appState.behaviour.dismissWarning(warning) }
                }
                .buttonStyle(.bordered)
                Spacer()
                if let domain = warning.domain {
                    Text(domain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(
            (warning.severity == .critical ? Color.red : Color.orange).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((warning.severity == .critical ? Color.red : Color.orange).opacity(0.35), lineWidth: 1)
        }
    }

    private func nextBuildCard(_ recs: [BuildRecommendation], engine: BehaviourEngine) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recommended next action", systemImage: "hammer.fill")
                .font(.headline)
            Text("Lumen ranks recent open actions, repeated interests, and project momentum. Recommendations stay on this Mac and never start work automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let top = recs.first {
                VStack(alignment: .leading, spacing: 8) {
                    Text(top.title)
                        .font(.title2.weight(.semibold))
                    Text(top.summary)
                        .foregroundStyle(.secondary)
                    if !top.reasons.isEmpty {
                        Text(top.reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    Label(top.suggestedFirstStep, systemImage: "arrow.right.circle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                    HStack {
                        Button("Start Focus Session") {
                            Task { await engine.startFocusSession(title: top.title) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(engine.activeFocusSession != nil)

                        if !top.sourceActionIDs.isEmpty || !top.sourceIdeaIDs.isEmpty {
                            Button("Mark Source Done") {
                                Task { await engine.completeRecommendation(top) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                if recs.count > 1 {
                    Text("Also consider")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(recs.dropFirst().prefix(3)) { rec in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rec.title).font(.body.weight(.medium))
                                Text(rec.suggestedFirstStep)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                Text("No recommendation yet. Add a project or an explicit TODO in a session note, then run Intelligence.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func goalsCard(_ progress: [GoalProgress]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Creation goals", systemImage: "target")
                    .font(.headline)
                Spacer()
                Button {
                    editingGoal = nil
                    showGoalSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            if progress.isEmpty {
                Text("No goals yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(progress) { item in
                    GoalProgressRow(item: item) {
                        editingGoal = item.goal
                        showGoalSheet = true
                    } onDelete: {
                        Task { await appState.behaviour.deleteGoal(item.goal) }
                    }
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func weeklyCard(_ weekly: WeeklyPatternReport?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Weekly patterns", systemImage: "calendar")
                .font(.headline)
            if let weekly {
                Text(weekly.narrative)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Simple hour bars for deep work
                Text("Deep work by hour")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)

                let maxDeep = max(weekly.hourBuckets.map(\.deepWorkDuration).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(weekly.hourBuckets) { bucket in
                        let h = max(4, CGFloat(bucket.deepWorkDuration / maxDeep) * 64)
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue.opacity(bucket.deepWorkDuration > 0 ? 0.85 : 0.15))
                                .frame(width: 8, height: h)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    metricChip("Active", DurationFormat.compact(weekly.totalActive))
                    metricChip("Deep", DurationFormat.compact(weekly.totalDeepWork))
                    metricChip("Distract", DurationFormat.compact(weekly.totalDistraction))
                }
            } else {
                Text("Collect a few days of data to see weekly patterns.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func streakCard(_ snap: BehaviourSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Focus pulse", systemImage: "flame.fill")
                .font(.headline)
            Text("\(snap?.focusStreakDays ?? 0)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
            Text("day deep-work streak")
                .foregroundStyle(.secondary)
            Divider()
            labeled("Deep work today", String(format: "%.0f min", snap?.todayDeepWorkMinutes ?? 0))
            labeled("Creation today", String(format: "%.0f min", snap?.todayCreationMinutes ?? 0))
            labeled("Distraction today", String(format: "%.0f min", snap?.todayDistractionMinutes ?? 0))
        }
        .padding(16)
        .frame(width: 220, alignment: .leading)
        .background(cardBackground)
    }

    private func projectsCard(_ scores: [ProjectScore], engine: BehaviourEngine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Project scores", systemImage: "folder.fill")
                .font(.headline)

            HStack {
                TextField("New project name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)
                TextField("Keywords (comma-separated)", text: $newProjectKeywords)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    let keywords = newProjectKeywords
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let project = ProjectDefinition(name: name, keywords: keywords.isEmpty ? [name] : keywords)
                    Task {
                        await engine.saveProject(project)
                        newProjectName = ""
                        newProjectKeywords = ""
                    }
                }
                .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if scores.isEmpty {
                Text("Add projects with keywords matching apps, domains, titles, or tags. Lumen scores momentum and deep work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(scores) { score in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle()
                                .fill(Color(hex: score.project.colorHex) ?? .blue)
                                .frame(width: 10, height: 10)
                            Text(score.project.name)
                                .font(.body.weight(.semibold))
                            Spacer()
                            Text(String(format: "%.0f", score.score))
                                .font(.title3.monospacedDigit().weight(.bold))
                                .foregroundStyle(score.score >= 60 ? .green : (score.score >= 35 ? .orange : .secondary))
                            if score.isInferred {
                                Button("Save as Project") {
                                    Task { await engine.saveProject(score.project) }
                                }
                                .buttonStyle(.borderless)
                            } else {
                                Button(role: .destructive) {
                                    Task { await engine.deleteProject(score.project) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Delete \(score.project.name)")
                            }
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(Color.blue.gradient)
                                    .frame(width: max(4, geo.size.width * CGFloat(min(1, score.score / 100))))
                            }
                        }
                        .frame(height: 6)
                        Text(score.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Text("Active \(DurationFormat.compact(score.activeDuration))")
                            Text("Deep \(DurationFormat.compact(score.deepWorkDuration))")
                            Text(String(format: "Momentum %.0f%%", score.momentum * 100))
                        }
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func warningsHistory(_ warnings: [BehaviourWarning]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Warning history", systemImage: "bell.fill")
                .font(.headline)
            if warnings.isEmpty {
                Text("No distraction warnings yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(warnings.prefix(8)) { warning in
                    HStack(alignment: .top) {
                        Image(systemName: warning.severity == .critical ? "exclamationmark.octagon" : "exclamationmark.triangle")
                            .foregroundStyle(warning.severity == .critical ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.title).font(.body.weight(.medium))
                            Text(warning.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Text(warning.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func metricChip(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

struct FocusSessionCard: View {
    @Environment(AppState.self) private var appState
    @State private var durationMinutes = 25.0

    var body: some View {
        let engine = appState.behaviour
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Focus session", systemImage: "timer")
                    .font(.headline)
                Spacer()
                if engine.activeFocusSession != nil {
                    Text("In progress")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            if let session = engine.activeFocusSession {
                Text(session.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(DurationFormat.clock(engine.focusRemainingSeconds))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: engine.focusProgress)
                    .tint(.blue)
                HStack {
                    Text("Started \(session.startAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("End Session") {
                        Task { await engine.endFocusSession() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Start an intentional work block. Active computer time during the session contributes to your deep-work goal, and the timer survives app relaunches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Picker("Duration", selection: $durationMinutes) {
                        Text("25 min").tag(25.0)
                        Text("45 min").tag(45.0)
                        Text("60 min").tag(60.0)
                        Text("90 min").tag(90.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    Spacer()
                    Button("Start Focus Session") {
                        engine.defaultFocusMinutes = durationMinutes
                        Task {
                            await engine.startFocusSession(
                                title: engine.snapshot?.recommendations.first?.title,
                                durationMinutes: durationMinutes
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
        )
        .onAppear {
            durationMinutes = [25, 45, 60, 90].contains(engine.defaultFocusMinutes)
                ? engine.defaultFocusMinutes
                : 25
        }
    }
}

struct GoalProgressRow: View {
    let item: GoalProgress
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.goal.metric.symbolName)
                    .foregroundStyle(item.isMet ? .green : .orange)
                Text(item.goal.title)
                    .font(.body.weight(.medium))
                Spacer()
                Text(valueLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(item.statusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((item.isMet ? Color.green : Color.orange).opacity(0.15), in: Capsule())
                    .foregroundStyle(item.isMet ? .green : .orange)
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            GeometryReader { geo in
                let ratio = CGFloat(min(1, item.goal.metric == .maxDistractionMinutes
                                        ? (item.isMet ? item.ratio : 1)
                                        : item.ratio))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill((item.isMet ? Color.green : Color.orange).gradient)
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
        .opacity(item.goal.isEnabled ? 1 : 0.55)
    }

    private var valueLabel: String {
        if item.goal.metric == .focusScore {
            return String(format: "%.0f / %.0f", item.currentValue, item.goal.targetValue)
        }
        return String(format: "%.0f / %.0f %@", item.currentValue, item.goal.targetValue, item.unitLabel)
    }
}

struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let goal: CreationGoal?
    var onSave: (CreationGoal) -> Void

    @State private var title: String = ""
    @State private var metric: GoalMetric = .deepWorkMinutes
    @State private var target: Double = 120
    @State private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(goal == nil ? "New goal" : "Edit goal")
                .font(.title2.weight(.semibold))
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Picker("Metric", selection: $metric) {
                ForEach(GoalMetric.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            HStack {
                Text("Target")
                Slider(value: $target, in: rangeForMetric, step: stepForMetric)
                Text(String(format: "%.0f %@", target, metric.unitLabel))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            Toggle("Enabled", isOn: $enabled)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cleaned.isEmpty else { return }
                    let saved = CreationGoal(
                        id: goal?.id ?? UUID(),
                        title: cleaned,
                        metric: metric,
                        targetValue: target,
                        isEnabled: enabled,
                        createdAt: goal?.createdAt ?? .now
                    )
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            if let goal {
                title = goal.title
                metric = goal.metric
                target = goal.targetValue
                enabled = goal.isEnabled
            } else {
                title = GoalMetric.deepWorkMinutes.displayName
                metric = .deepWorkMinutes
                target = 120
            }
        }
        .onChange(of: metric) { _, newValue in
            if goal == nil {
                title = newValue.displayName
                target = defaultTarget(newValue)
            }
        }
    }

    private var rangeForMetric: ClosedRange<Double> {
        switch metric {
        case .focusScore: 30...100
        case .maxDistractionMinutes: 10...240
        default: 15...480
        }
    }

    private var stepForMetric: Double {
        metric == .focusScore ? 1 : 5
    }

    private func defaultTarget(_ metric: GoalMetric) -> Double {
        switch metric {
        case .deepWorkMinutes: 120
        case .creationMinutes: 90
        case .learningMinutes: 60
        case .focusScore: 65
        case .maxDistractionMinutes: 45
        }
    }
}
