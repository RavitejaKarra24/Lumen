import SwiftUI

struct BackupSettingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var backups = appState.backups

        Section("Google Drive Backup") {
            Text(
                "Lumen saves a compressed copy of your data into your Google Drive folder, and Google Drive for desktop uploads it to your account whenever you’re online. Live data stays on this Mac."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if backups.driveEmail == nil {
                if backups.driveAccounts.isEmpty {
                    Text(
                        "Google Drive for desktop isn’t signed in on this Mac. Install it from google.com/drive/download and sign in, or choose any folder below."
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    ForEach(backups.driveAccounts) { account in
                        Button {
                            Task { await backups.useGoogleDrive(account) }
                        } label: {
                            Label("Back up to Google Drive (\(account.email))", systemImage: "icloud.and.arrow.up")
                        }
                        .disabled(backups.isBusy || backups.restorePending)
                    }
                }
            }

            if let folder = backups.folderURL {
                LabeledContent("Saving to") {
                    if let email = backups.driveEmail {
                        Text("Google Drive · \(email) › \(BackupService.folderName)")
                            .font(.caption)
                    } else {
                        Text(folder.appendingPathComponent(BackupService.folderName).path(percentEncoded: false))
                            .font(.caption)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }

            Toggle("Back up automatically while online", isOn: $backups.automaticEnabled)
                .disabled(backups.folderURL == nil || backups.restorePending)

            Picker("How often", selection: $backups.frequency) {
                ForEach(BackupFrequency.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!backups.automaticEnabled || backups.folderURL == nil)

            if backups.folderURL != nil {
                LabeledContent("Status") { status(backups) }
            }

            Text(
                "Keeps the 6 newest backups plus one per day for the last 14 days. Missed backups run on the next launch, after wake, or as soon as the connection returns. Backups include activity, tags, reports, goals, and captured content; preferences are stored separately."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(
                "ZIP backups are not encrypted and contain private browsing history and captured content. Open Google Drive for desktop to see upload progress."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if backups.restorePending {
                Label("Restore ready. Quit and reopen Lumen to apply it.", systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
            if let error = backups.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            HStack {
                Button("Choose Folder…") { backups.chooseFolder() }
                Button("Back Up Now") { Task { await backups.backUpNow() } }
                    .disabled(backups.folderURL == nil)
                Button("Show Backups") { backups.revealFolder() }
                    .disabled(backups.folderURL == nil)
            }
            .disabled(backups.isBusy || backups.restorePending)

            Button("Restore…") { backups.chooseRestore() }
                .disabled(backups.isBusy || backups.restorePending)
        }
        .onAppear { backups.refreshDriveAccounts() }
    }

    @ViewBuilder
    private func status(_ backups: BackupController) -> some View {
        if backups.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Backing up…")
            }
        } else if backups.isWaitingForNetwork {
            Label("Waiting for an internet connection", systemImage: "wifi.slash")
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                if let last = backups.lastBackupAt {
                    Text("Last saved \(last.formatted(.dateTime.month().day().hour().minute()))")
                } else {
                    Text("No backup yet")
                }
                if let next = backups.nextBackupAt, next > .now {
                    Text("Next \(next.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                } else if !backups.automaticEnabled {
                    Text("Automatic backups off").foregroundStyle(.secondary)
                }
            }
        }
    }
}
