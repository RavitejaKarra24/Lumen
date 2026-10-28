import SwiftUI

struct TodayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            header
            Divider()
            if let analytics = appState.analytics {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        metrics(analytics)
                        HStack(alignment: .top, spacing: 20) {
                            categoriesCard(analytics)
                            focusCard(analytics)
                        }
                        deepWorkCard(analytics)
                        appsCard(analytics)
                        sitesCard(analytics)
                        behaviourTeaser
                        intelligenceTeaser
                        liveCard
                    }
                    .padding(24)
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Today")
        .toolbar {
            ToolbarItemGroup {
                DayPickerBar(day: $appState.selectedDay) { date in
                    appState.selectDay(date)
                }
                Button {
                    Task {
                        if appState.behaviour.activeFocusSession == nil {
                            await appState.behaviour.startFocusSession(
                                title: appState.behaviour.snapshot?.recommendations.first?.title
                            )
                        } else {
                            appState.selectedSidebar = .behaviour
                        }
                    }
                } label: {
                    Label(
                        appState.behaviour.activeFocusSession == nil ? "Start Focus" : "View Focus",
                        systemImage: appState.behaviour.activeFocusSession == nil ? "timer" : "timer.circle.fill"
                    )
                }

                Button {
                    appState.refreshAnalytics()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dayTitle)
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = appState.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var dayTitle: String {
        if Calendar.current.isDateInToday(appState.selectedDay) {
            return "Today"
        }
        if Calendar.current.isDateInYesterday(appState.selectedDay) {
            return "Yesterday"
        }
        let f = DateFormatter()
        f.dateStyle = .full
        return f.string(from: appState.selectedDay)
    }

    private var subtitle: String {
        if appState.recorder.isRunning {
            if appState.recorder.isCurrentlyIdle {
                return "You’re idle · tracking continues when you return"
            }
            if let snap = appState.recorder.currentSnapshot {
                return "Now: \(snap.appName)"
            }
            return "Recording"
        }
        return "Tracking paused"
    }

    private func metrics(_ analytics: DayAnalytics) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), spacing: 14)],
            spacing: 14
        ) {
            MetricCard(
                title: "Active",
                value: DurationFormat.compact(analytics.activeDuration),
                subtitle: "Focused computer time",
                symbol: "bolt.fill",
                accent: .orange
            )
            MetricCard(
                title: "Idle",
                value: DurationFormat.compact(analytics.idleDuration),
                subtitle: "Away from keyboard",
                symbol: "moon.zzz.fill",
                accent: .indigo
            )
            MetricCard(
                title: "Deep work",
                value: DurationFormat.compact(analytics.deepWorkDuration),
                subtitle: appState.behaviour.activeFocusSession == nil
                    ? "Automatic + focus sessions"
                    : "\(DurationFormat.clock(appState.behaviour.focusRemainingSeconds)) remaining",
                symbol: "brain.head.profile",
                accent: .blue
            )
            MetricCard(
                title: "Switches",
                value: "\(analytics.contextSwitches)",
                subtitle: "App context changes",
                symbol: "arrow.left.arrow.right",
                accent: .pink
            )
        }
    }

    private func categoriesCard(_ analytics: DayAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Categories")
                .font(.headline)
            if analytics.categoryUsages.isEmpty {
                Text("No data yet — keep working and Lumen will fill this in.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(analytics.categoryUsages.prefix(6)) { item in
                    UsageBarRow(
                        title: item.category.displayName,
                        subtitle: nil,
                        duration: item.duration,
                        total: max(analytics.activeDuration, 1),
                        symbol: item.category.symbolName,
                        color: item.category.color
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func focusCard(_ analytics: DayAnalytics) -> some View {
        VStack(spacing: 16) {
            Text("Focus score")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            FocusRing(score: analytics.focusScore)
            Text(focusBlurb(analytics.focusScore))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                labeled("Top app", analytics.topAppName)
                labeled("Top site", analytics.topDomain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(width: 260, alignment: .top)
        .background(cardBackground)
    }

    private func deepWorkCard(_ analytics: DayAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Deep work blocks", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Text(DurationFormat.compact(analytics.deepWorkDuration))
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.blue)
            }

            if analytics.deepWorkBlocks.isEmpty {
                Text("No sustained blocks yet. Lumen counts a run of focused work lasting \(Int(AnalyticsService.deepWorkMinimumBlock / 60)) minutes or more — brief interruptions won’t break it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(analytics.deepWorkBlocks) { block in
                    HStack(spacing: 12) {
                        Image(systemName: block.isFocusSession ? "timer" : block.dominantCategory.symbolName)
                            .foregroundStyle(block.isFocusSession ? Color.blue : block.dominantCategory.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blockRange(block))
                                .font(.body.monospacedDigit().weight(.medium))
                            Text(block.appNames.isEmpty ? "—" : block.appNames.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(DurationFormat.compact(block.focusedDuration))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func blockRange(_ block: DeepWorkBlock) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: block.start)) – \(formatter.string(from: block.end))"
    }

    private func appsCard(_ analytics: DayAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top apps")
                    .font(.headline)
                Spacer()
                Button("See all") { appState.selectedSidebar = .apps }
                    .buttonStyle(.borderless)
            }
            if analytics.appUsages.isEmpty {
                Text("No apps yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(analytics.appUsages.prefix(5)) { app in
                    UsageBarRow(
                        title: app.appName,
                        subtitle: app.category.displayName,
                        duration: app.duration,
                        total: max(analytics.activeDuration, 1),
                        symbol: "app.fill",
                        color: app.category.color
                    )
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private func sitesCard(_ analytics: DayAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top websites")
                    .font(.headline)
                Spacer()
                Button("See all") { appState.selectedSidebar = .websites }
                    .buttonStyle(.borderless)
            }
            if analytics.domainUsages.isEmpty {
                Text("No websites yet. Grant Accessibility so Lumen can read browser URLs.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                ForEach(analytics.domainUsages.prefix(5)) { site in
                    UsageBarRow(
                        title: site.domain,
                        subtitle: "\(site.visitCount) visits",
                        duration: site.duration,
                        total: max(analytics.domainUsages.first?.duration ?? 1, 1),
                        symbol: "globe",
                        color: .cyan
                    )
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var behaviourTeaser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Behaviour", systemImage: "flame.fill")
                    .font(.headline)
                Spacer()
                Button("Open") { appState.selectedSidebar = .behaviour }
                    .buttonStyle(.borderless)
            }

            if let warning = appState.behaviour.activeWarning, warning.isActive {
                Label(warning.title, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let next = appState.behaviour.snapshot?.recommendations.first {
                Text(next.title)
                    .font(.body.weight(.semibold))
                Text(next.suggestedFirstStep)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Goals, distraction guards, and “what to build next” live here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let progress = appState.behaviour.snapshot?.goalProgress.prefix(3), !progress.isEmpty {
                ForEach(Array(progress)) { item in
                    HStack {
                        Text(item.goal.title)
                        Spacer()
                        Text(item.isMet ? "✓" : String(format: "%.0f/%.0f", item.currentValue, item.goal.targetValue))
                            .foregroundStyle(item.isMet ? .green : .secondary)
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var intelligenceTeaser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Intelligence", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Button("Open") { appState.selectedSidebar = .intelligence }
                    .buttonStyle(.borderless)
            }
            if let summary = appState.insights.first(where: { $0.kind == .learningSummary })?.body {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                Text("Capture pages, classify sessions, and extract ideas — run Analyze in Intelligence.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            let topics = appState.insights.filter { $0.kind == .interest }.prefix(5).map(\.title)
            if !topics.isEmpty {
                Text(topics.joined(separator: " · "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
            }
            HStack(spacing: 16) {
                Label("\(appState.actionInsights.count) actions", systemImage: "checklist")
                Label("\(appState.ideaInsights.count) ideas", systemImage: "lightbulb")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(cardBackground)
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live")
                .font(.headline)
            HStack(spacing: 16) {
                statusPill
                if let snap = appState.recorder.currentSnapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.appName).font(.body.weight(.medium))
                        if let url = snap.urlString {
                            Text(url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else if !snap.windowTitle.isEmpty {
                            Text(snap.windowTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                Text("Idle \(DurationFormat.clock(appState.recorder.secondsIdle))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(cardBackground)
    }

    private var statusPill: some View {
        let color: Color = {
            if !appState.permissions.hasAccessibility { return .orange }
            if !appState.recorder.isRunning { return .secondary }
            if appState.recorder.isCurrentlyIdle { return .yellow }
            return .green
        }()
        let text: String = {
            if !appState.permissions.hasAccessibility { return "Permission" }
            if !appState.recorder.isRunning { return "Paused" }
            if appState.recorder.isCurrentlyIdle { return "Idle" }
            return "Live"
        }()
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
    }

    private func focusBlurb(_ score: Double) -> String {
        switch score {
        case 80...: return "Strong focus day — deep work is winning."
        case 60..<80: return "Solid mix of deep and shallow work."
        case 40..<60: return "Attention is split. Try longer single-app blocks."
        case 1..<40: return "Lots of shallow time. Protect a focus block next."
        default: return "Start working and your score will appear."
        }
    }
}
