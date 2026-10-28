import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var appState = appState

        Form {
            Section("Tracking") {
                HStack {
                    Circle()
                        .fill(appState.recorder.isRunning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(appState.recorder.isRunning ? "Recording" : "Paused")
                    Spacer()
                    Button(appState.recorder.isRunning ? "Pause" : "Resume") {
                        if appState.recorder.isRunning {
                            appState.stopRecording()
                        } else {
                            appState.startRecordingIfPossible()
                        }
                    }
                }

                LabeledContent("Idle threshold") {
                    HStack {
                        Slider(value: $appState.idleThresholdMinutes, in: 1...15, step: 1)
                        Text("\(Int(appState.idleThresholdMinutes))m")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                }

                Text("After this many minutes without keyboard or mouse input, time is counted as idle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle("Distraction warnings", isOn: Binding(
                    get: { appState.behaviour.warningsEnabled },
                    set: { appState.behaviour.warningsEnabled = $0 }
                ))
                Toggle("System notifications", isOn: Binding(
                    get: { appState.behaviour.notificationsEnabled },
                    set: { appState.behaviour.notificationsEnabled = $0 }
                ))
                LabeledContent("Warn after distraction") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { appState.behaviour.distractionWarningMinutes },
                                set: { appState.behaviour.distractionWarningMinutes = $0 }
                            ),
                            in: 3...45,
                            step: 1
                        )
                        Text("\(Int(appState.behaviour.distractionWarningMinutes))m")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                }
                LabeledContent("Focus session length") {
                    Picker("Focus session length", selection: Binding(
                        get: { appState.behaviour.defaultFocusMinutes },
                        set: { appState.behaviour.defaultFocusMinutes = $0 }
                    )) {
                        Text("25 minutes").tag(25.0)
                        Text("45 minutes").tag(45.0)
                        Text("60 minutes").tag(60.0)
                        Text("90 minutes").tag(90.0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                LabeledContent("Snooze length") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { appState.behaviour.snoozeMinutes },
                                set: { appState.behaviour.snoozeMinutes = $0 }
                            ),
                            in: 5...60,
                            step: 5
                        )
                        Text("\(Int(appState.behaviour.snoozeMinutes))m")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                }
                Text("Warnings fire for long distraction sessions, broken goals, and late-day deep-work lag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Intelligence") {
                Toggle("Auto-capture page content & transcripts", isOn: Binding(
                    get: { appState.intelligence.autoCaptureEnabled },
                    set: { appState.intelligence.autoCaptureEnabled = $0 }
                ))

                LabeledContent("Min session for capture") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { appState.intelligence.minimumCaptureDuration },
                                set: { appState.intelligence.minimumCaptureDuration = $0 }
                            ),
                            in: 15...300,
                            step: 15
                        )
                        Text("\(Int(appState.intelligence.minimumCaptureDuration))s")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                }

                Text("When enabled, Lumen makes network requests to the sites you visit (and YouTube) to fetch page text and captions for longer browser sessions. Only titles, URLs, and the fetched text are stored, and everything stays on this Mac. With it off, the Intelligence page runs local analysis only until you choose Fetch content there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Run intelligence now") {
                    Task { await appState.runIntelligence() }
                }

                MutedTopicsRow()
            }

            Section("Permissions") {
                HStack {
                    Label(
                        appState.permissions.hasAccessibility ? "Accessibility granted" : "Accessibility missing",
                        systemImage: appState.permissions.hasAccessibility
                            ? "checkmark.shield.fill"
                            : "exclamationmark.shield.fill"
                    )
                    .foregroundStyle(appState.permissions.hasAccessibility ? .green : .orange)
                    Spacer()
                    if appState.permissions.hasAccessibility {
                        Button("Refresh") { appState.permissions.refresh() }
                    } else {
                        Button("Grant…") { appState.permissions.requestAccessibility() }
                            .buttonStyle(.borderedProminent)
                    }
                }

                Text("Needed to read window titles and browser URLs. All data stays on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.loginItem.isEnabled },
                    set: { newValue in
                        appState.loginItem.setEnabled(newValue)
                        if let error = appState.loginItem.lastError {
                            appState.setStatus(error)
                        }
                    }
                ))
                .disabled(!appState.loginItem.canManage)
                Text(appState.loginItem.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.loginItem.needsApproval {
                    Button("Open Login Items Settings") {
                        appState.loginItem.openApprovalSettings()
                    }
                }

                Toggle("Show current app in the menu bar", isOn: $appState.showMenuBarTitle)
                Text("Off by default — the title changes on every app switch, which shifts everything else in your menu bar. A running focus session always shows its countdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Version") {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                Text("Activity is stored locally as JSON in your Application Support/Lumen folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Keep raw activity for") {
                    Picker("Keep raw activity for", selection: $appState.retentionDays) {
                        Text("Forever").tag(0)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
                Text("Older sessions are deleted to keep the app fast. Generated reports are always kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Reveal Data Folder") {
                        appState.revealDataFolder()
                    }
                    Button("Refresh Analytics") {
                        appState.refreshAnalytics()
                    }
                    Button("Export CSV…") {
                        appState.exportReportToDownloads(format: .csv)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
        .onAppear {
            // Reconcile with the actual login-item service, in case it changed
            // outside the app since the last visit.
            appState.loginItem.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { appState.loginItem.refresh() }
        }
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Undo/reset controls for the insight mute and dismissal state.
private struct MutedTopicsRow: View {
    @Environment(AppState.self) private var appState
    @State private var mutedCount = 0
    @State private var hasDismissed = false

    var body: some View {
        HStack {
            if mutedCount > 0 {
                Button("Reset \(mutedCount) muted topic\(mutedCount == 1 ? "" : "s")") {
                    Task {
                        await appState.resetMutedTopics()
                        await refresh()
                    }
                }
            }
            if hasDismissed {
                Button("Restore dismissed insights") {
                    Task {
                        await appState.resetDismissedInsights()
                        await refresh()
                    }
                }
            }
        }
        // Attach to an unconditional container: the counts begin at zero, so
        // a task inside the conditional controls would never get to load them.
        .task { await refresh() }
        .onChange(of: appState.insights) { _, _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        do {
            // This read also ensures persisted mute state has been loaded.
            let dismissed = try await appState.store.dismissedInsightCount()
            mutedCount = await appState.store.mutedTopics.count
            hasDismissed = dismissed > 0
        } catch {
            appState.setStatus(error.localizedDescription)
        }
    }
}
