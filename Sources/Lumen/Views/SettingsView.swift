import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

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

                Text("Fetches page text and YouTube captions for longer browser sessions. Content stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Run intelligence now") {
                    Task { await appState.runIntelligence() }
                }
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
                    get: { appState.launchAtLogin },
                    set: { newValue in
                        appState.launchAtLogin = newValue
                        updateLoginItem(enabled: newValue)
                    }
                ))

                LabeledContent("Version") {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Data") {
                Text("Activity is stored locally as JSON in your Application Support/Lumen folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Reveal Data Folder") {
                        appState.revealDataFolder()
                    }
                    Button("Refresh Analytics") {
                        appState.refreshAnalytics()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Settings")
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func updateLoginItem(enabled: Bool) {
        #if DEBUG
        // Avoid polluting login items during iterative development.
        return
        #else
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            appState.statusMessage = "Login item failed: \(error.localizedDescription)"
        }
        #endif
    }
}
