import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let warning = appState.behaviour.activeWarning, warning.isActive {
            Text(warning.title)
            Text(warning.message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Button("Start Focus Session") {
                Task {
                    await appState.behaviour.startFocusSession(
                        title: appState.behaviour.snapshot?.recommendations.first?.title
                    )
                }
            }
            .disabled(appState.behaviour.activeFocusSession != nil)
            Button("Snooze") {
                Task { await appState.behaviour.snoozeWarning(warning) }
            }
            Button("Dismiss") {
                Task { await appState.behaviour.dismissWarning(warning) }
            }
            Divider()
        }

        if let snap = appState.recorder.currentSnapshot, appState.recorder.isRunning, !appState.recorder.isCurrentlyIdle {
            Text(snap.appName)
            if let url = snap.urlString, let host = CategoryClassifier.domain(from: url) {
                Text(host)
                    .foregroundStyle(.secondary)
            } else if !snap.windowTitle.isEmpty {
                Text(snap.windowTitle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        } else if appState.recorder.isCurrentlyIdle {
            Text("Idle")
        } else {
            Text("Lumen")
        }

        if let top = appState.behaviour.snapshot?.recommendations.first {
            Text("Next: \(top.title)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }

        if let focus = appState.behaviour.activeFocusSession {
            Divider()
            Text(focus.title)
            Text("Focus · \(DurationFormat.clock(appState.behaviour.focusRemainingSeconds)) remaining")
                .foregroundStyle(.secondary)
            Button("End Focus Session") {
                Task { await appState.behaviour.endFocusSession() }
            }
        }

        Divider()

        Button("Open Dashboard") {
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }

        Button(appState.recorder.isRunning ? "Pause Tracking" : "Resume Tracking") {
            if appState.recorder.isRunning {
                appState.stopRecording()
            } else {
                appState.startRecordingIfPossible()
            }
        }

        if appState.behaviour.activeFocusSession == nil {
            Button("Start Focus Session") {
                Task {
                    await appState.behaviour.startFocusSession(
                        title: appState.behaviour.snapshot?.recommendations.first?.title
                    )
                }
            }
        }

        if !appState.permissions.hasAccessibility {
            Button("Grant Accessibility…") {
                appState.permissions.requestAccessibility()
            }
        }

        Divider()

        Button("Generate Today’s Report") {
            appState.selectDay(.now)
            openWindow(id: "dashboard")
            appState.selectedSidebar = .reports
            NSApp.activate(ignoringOtherApps: true)
            Task { _ = await appState.generateReport(for: .now) }
        }

        Button("Run Intelligence") {
            openWindow(id: "dashboard")
            appState.selectedSidebar = .intelligence
            NSApp.activate(ignoringOtherApps: true)
            Task { await appState.runIntelligence() }
        }

        Button("Behaviour Engine") {
            openWindow(id: "dashboard")
            appState.selectedSidebar = .behaviour
            NSApp.activate(ignoringOtherApps: true)
            Task { await appState.refreshBehaviour(triggerWarnings: true) }
        }

        Divider()

        Button("Quit Lumen") {
            Task {
                await appState.recorder.stopAndClose()
                NSApp.terminate(nil)
            }
        }
        .keyboardShortcut("q")
    }
}
