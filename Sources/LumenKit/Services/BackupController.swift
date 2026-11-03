import AppKit
import Foundation
import Network
import Observation

enum BackupFrequency: String, CaseIterable, Identifiable, Sendable {
    case hourly
    case every3Hours
    case every6Hours
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hourly: "Every hour"
        case .every3Hours: "Every 3 hours"
        case .every6Hours: "Every 6 hours"
        case .daily: "Once a day"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .hourly: 3600
        case .every3Hours: 3 * 3600
        case .every6Hours: 6 * 3600
        case .daily: 86400
        }
    }
}

/// Reports whether the Mac has a usable network path. Backups land in a local
/// Drive for desktop folder, but automatic runs wait for a connection so each
/// copy can upload promptly instead of queueing stale snapshots offline.
final class NetworkStatusMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lumen.backup.network")

    func start(_ onChange: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { path in onChange(path.status == .satisfied) }
        monitor.start(queue: queue)
    }

    func cancel() { monitor.cancel() }
}

@MainActor
@Observable
final class BackupController {
    private(set) var folderURL: URL?
    private(set) var isBusy = false
    private(set) var lastBackupAt: Date?
    private(set) var lastError: String?
    private(set) var restorePending = false
    private(set) var driveAccounts: [GoogleDriveAccount] = []
    /// Assumed online until the monitor reports; tests set it directly.
    var isOnline = true

    var automaticEnabled: Bool {
        didSet { defaults.set(automaticEnabled, forKey: Keys.automatic) }
    }

    var frequency: BackupFrequency {
        didSet { defaults.set(frequency.rawValue, forKey: Keys.frequency) }
    }

    /// The Drive account when the backup folder is inside Google Drive.
    var driveEmail: String? { folderURL.flatMap(GoogleDriveLocator.email(containing:)) }

    var nextBackupAt: Date? {
        guard automaticEnabled, folderURL != nil, let lastBackupAt else { return nil }
        if frequency == .daily {
            return calendar.startOfDay(for: lastBackupAt).addingTimeInterval(86400)
        }
        return lastBackupAt.addingTimeInterval(frequency.interval)
    }

    var isWaitingForNetwork: Bool {
        automaticEnabled && folderURL != nil && !isOnline && Self.isDue(lastBackup: lastBackupAt, frequency: frequency)
    }

    private enum Keys {
        static let automatic = "backup.automatic"
        static let frequency = "backup.frequency"
        static let folderPath = "backup.folderPath"
        static let lastSuccess = "backup.lastSuccess"
        static let lastError = "backup.lastError"
    }

    /// Failed automatic attempts are retried after this long; manual retries
    /// and a returning network connection retry immediately.
    static let retryDelay: TimeInterval = 30 * 60

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: ActivityStore
    @ObservationIgnored private let service: BackupService
    @ObservationIgnored private let gate: BlockingWorkGate
    @ObservationIgnored private let calendar = Calendar.current
    @ObservationIgnored private let network = NetworkStatusMonitor()
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var lastAttemptAt: Date?

    init(
        defaults: UserDefaults = .standard, store: ActivityStore = .shared, gate: BlockingWorkGate = .shared,
        destinationTimeout: TimeInterval = 180
    ) {
        self.defaults = defaults
        self.store = store
        self.gate = gate
        service = BackupService(gate: gate, destinationTimeout: destinationTimeout)
        automaticEnabled = defaults.bool(forKey: Keys.automatic)
        frequency = defaults.string(forKey: Keys.frequency).flatMap(BackupFrequency.init(rawValue:)) ?? .every3Hours
        lastBackupAt = defaults.object(forKey: Keys.lastSuccess) as? Date
        lastError = defaults.string(forKey: Keys.lastError)
        restorePending = FileManager.default.fileExists(
            atPath: BackupRestore.pendingDirectory(for: ActivityStore.defaultDirectory).path)
        // A plain path, never resolved at launch: touching a hung Drive mount
        // here would block the main thread before the UI appears.
        if let path = defaults.string(forKey: Keys.folderPath) {
            folderURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        refreshDriveAccounts()
    }

    func start() {
        guard timerTask == nil else { return }
        network.start { [weak self] online in
            Task { @MainActor in await self?.networkChanged(online: online) }
        }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.backUpIfDue()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    func refreshDriveAccounts() {
        driveAccounts = GoogleDriveLocator.accounts()
    }

    /// Hourly frequencies use elapsed time; daily uses the local calendar day,
    /// so a missed day is caught up on the next launch or after wake.
    static func isDue(
        lastBackup: Date?, frequency: BackupFrequency, now: Date = .now, calendar: Calendar = .current
    ) -> Bool {
        guard let lastBackup else { return true }
        // A clock moved backwards must not suspend backups until it catches up.
        if lastBackup > now { return true }
        if frequency == .daily { return !calendar.isDate(lastBackup, inSameDayAs: now) }
        return now.timeIntervalSince(lastBackup) >= frequency.interval
    }

    func networkChanged(online: Bool) async {
        let reconnected = online && !isOnline
        isOnline = online
        guard reconnected else { return }
        // A failure while offline says nothing about the destination now.
        lastAttemptAt = nil
        await backUpIfDue()
    }

    func backUpIfDue(now: Date = .now) async {
        guard automaticEnabled, folderURL != nil, isOnline, !isBusy, !restorePending,
            Self.isDue(lastBackup: lastBackupAt, frequency: frequency, now: now, calendar: calendar),
            lastAttemptAt.map({ now.timeIntervalSince($0) >= Self.retryDelay }) ?? true
        else { return }
        await backUpNow(now: now)
    }

    /// One-click setup for a detected Drive for desktop account. A Drive that
    /// is temporarily unresponsive is still saved; automatic retries cover it.
    func useGoogleDrive(_ account: GoogleDriveAccount) async {
        await applyFolder(account.myDrive, allowUnresponsive: true)
    }

    func chooseFolder() {
        guard !isBusy, !restorePending else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.message =
            "Select a folder in Google Drive for desktop. Lumen creates a Lumen Backups subfolder; your live data stays local."
        panel.prompt = "Use Backup Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL ?? driveAccounts.first?.myDrive
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await applyFolder(url, allowUnresponsive: false) }
    }

    private func applyFolder(_ url: URL, allowUnresponsive: Bool) async {
        do {
            try await setFolder(url, allowUnresponsive: allowUnresponsive)
            await backUpNow()
        } catch {
            recordError(error.localizedDescription)
        }
    }

    /// Validation runs through the gate: it stats the folder, which can hang
    /// inside a wedged cloud mount.
    func setFolder(_ url: URL, allowUnresponsive: Bool = false, validationTimeout: TimeInterval = 20) async throws {
        guard !isBusy, !restorePending else { throw BackupError.busy }
        isBusy = true
        defer { isBusy = false }
        do {
            try await gate.run(timeout: validationTimeout) {
                try BackupService.validateDestination(url, liveDirectory: ActivityStore.defaultDirectory)
            }
        } catch BackupError.destinationUnresponsive where allowUnresponsive {
            // Keep the choice; the first automatic attempt reports the outcome.
        }
        folderURL = url
        defaults.set(url.path, forKey: Keys.folderPath)
        lastBackupAt = nil
        defaults.removeObject(forKey: Keys.lastSuccess)
        lastAttemptAt = nil
        clearError()
        automaticEnabled = true
    }

    func backUpNow(now: Date = .now) async {
        guard !isBusy, !restorePending, let folderURL else { return }
        isBusy = true
        lastAttemptAt = now
        defer { isBusy = false }
        do {
            _ = try await service.createBackup(store: store, destination: folderURL, now: now)
            lastBackupAt = now
            defaults.set(now, forKey: Keys.lastSuccess)
            clearError()
        } catch {
            recordError(error.localizedDescription)
        }
    }

    func revealFolder() {
        guard let folderURL else { return }
        NSWorkspace.shared.open(folderURL.appendingPathComponent(BackupService.folderName))
    }

    func chooseRestore() {
        guard !isBusy, !restorePending else { return }
        let panel = NSOpenPanel()
        panel.title = "Restore Lumen Backup"
        panel.message = "Unzip a Lumen backup, then select its extracted Lumen folder."
        panel.prompt = "Select Backup"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Restore this backup on the next launch?"
        alert.informativeText =
            "After you quit and reopen Lumen, this backup will replace your activity data. Your current data will be preserved beside the live data folder as Lumen Before Restore. Preferences will stay as they are."
        alert.addButton(withTitle: "Prepare Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try BackupRestore.stage(from: source)
                }.value
                restorePending = true
                clearError()
            } catch {
                recordError(error.localizedDescription)
            }
        }
    }

    private func recordError(_ message: String) {
        lastError = message
        defaults.set(message, forKey: Keys.lastError)
    }

    private func clearError() {
        lastError = nil
        defaults.removeObject(forKey: Keys.lastError)
    }
}
