import AppKit
import SwiftUI

/// Keeps the tracker alive when the dashboard window closes, and makes sure the
/// open segment and any batched writes reach disk before the process exits.
final class LumenAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Lumen lives in the menu bar; closing the dashboard should not stop tracking.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Detached so the wait below cannot deadlock against the main actor.
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let store = ActivityStore.shared
            try? await store.closeOpenSegment(at: .now, minimumDuration: 1.5)
            await store.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
    }
}

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(LumenAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("Lumen", id: "dashboard") {
            RootView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appState.bootstrap()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Generate Daily Report") {
                    Task { _ = await appState.generateReport() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Export Markdown Report…") {
                    appState.exportReportToDownloads(format: .markdown)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Export Sessions as CSV…") {
                    appState.exportReportToDownloads(format: .csv)
                }
            }
            CommandMenu("Tracking") {
                Button(appState.recorder.isRunning ? "Pause Tracking" : "Resume Tracking") {
                    if appState.recorder.isRunning {
                        appState.stopRecording()
                    } else {
                        appState.startRecordingIfPossible()
                    }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Run Intelligence") {
                    Task { await appState.runIntelligence() }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("Start Focus Session") {
                    Task {
                        await appState.behaviour.startFocusSession(
                            title: appState.behaviour.snapshot?.recommendations.first?.title
                        )
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(appState.behaviour.activeFocusSession != nil)

                Button("End Focus Session") {
                    Task { await appState.behaviour.endFocusSession() }
                }
                .disabled(appState.behaviour.activeFocusSession == nil)

                Button("Refresh Behaviour") {
                    Task { await appState.refreshBehaviour(triggerWarnings: true) }
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            Label(appState.menuBarTitle, systemImage: appState.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
                .frame(width: 560, height: 520)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            NavigationSplitView {
                SidebarView(selection: $appState.selectedSidebar)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            } detail: {
                detail
            }

            if appState.showOnboarding {
                OnboardingView()
                    .transition(.opacity)
                    .zIndex(10)
            }

            if let warning = appState.behaviour.activeWarning,
               warning.isActive,
               !appState.showOnboarding,
               appState.selectedSidebar != .behaviour {
                VStack {
                    DistractionToast(warning: warning)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .zIndex(20)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: warning.id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selectedSidebar {
        case .today:
            TodayView()
        case .timeline:
            ActivityTimelineView()
        case .apps:
            AppsView()
        case .websites:
            WebsitesView()
        case .intelligence:
            IntelligenceView()
        case .behaviour:
            BehaviourView()
        case .tags:
            TagsView()
        case .reports:
            ReportsView()
        case .settings:
            SettingsView()
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: $selection) {
            Section("Track") {
                ForEach(SidebarItem.allCases.filter { $0 != .settings }) { item in
                    Label(item.title, systemImage: item.symbolName)
                        .tag(item)
                }
            }
            Section {
                Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.symbolName)
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let snap = appState.recorder.currentSnapshot, appState.recorder.isRunning {
                    Text(snap.appName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .navigationTitle("Lumen")
    }

    private var statusColor: Color {
        if let warning = appState.behaviour.activeWarning, warning.isActive {
            return warning.severity == .critical ? .red : .orange
        }
        if !appState.permissions.hasAccessibility { return .orange }
        if !appState.recorder.isRunning { return .secondary }
        if appState.recorder.isCurrentlyIdle { return .yellow }
        return .green
    }

    private var statusText: String {
        if let warning = appState.behaviour.activeWarning, warning.isActive {
            return warning.severity == .critical ? "Distracted" : "Warning"
        }
        if !appState.permissions.hasAccessibility { return "Needs Accessibility" }
        if !appState.recorder.isRunning { return "Paused" }
        if appState.recorder.isCurrentlyIdle { return "Idle" }
        return "Recording"
    }
}

struct DistractionToast: View {
    @Environment(AppState.self) private var appState
    let warning: BehaviourWarning

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: warning.severity == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(warning.severity == .critical ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .font(.headline)
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Start Focus") {
                Task {
                    await appState.behaviour.startFocusSession(
                        title: appState.behaviour.snapshot?.recommendations.first?.title
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.behaviour.activeFocusSession != nil)
            Button("Snooze") {
                Task { await appState.behaviour.snoozeWarning(warning) }
            }
            .buttonStyle(.bordered)
            Button("Dismiss") {
                Task { await appState.behaviour.dismissWarning(warning) }
            }
            .buttonStyle(.bordered)
            Button {
                appState.selectedSidebar = .behaviour
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((warning.severity == .critical ? Color.red : Color.orange).opacity(0.35), lineWidth: 1)
        }
        .padding(.horizontal, 24)
    }
}
