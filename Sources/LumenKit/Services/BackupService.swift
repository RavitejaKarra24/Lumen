import Foundation

enum BackupError: LocalizedError {
    case invalidDestination
    case invalidBackup
    case busy
    case archiveFailed
    case destinationUnresponsive

    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            "Choose an existing backup folder outside Lumen’s live data folder."
        case .invalidBackup:
            "Choose the extracted Lumen data folder containing segments.json. The backup must contain regular files only."
        case .busy:
            "A backup or restore is already in progress."
        case .archiveFailed:
            "The backup archive could not be created or verified. Check available disk space and folder access."
        case .destinationUnresponsive:
            "Google Drive isn’t responding. Make sure Google Drive for desktop is running and signed in. Lumen will try again automatically."
        }
    }
}

/// Runs blocking file work against a cloud-synced folder on a dedicated thread.
/// A wedged File Provider (Google Drive, iCloud) can block a syscall
/// indefinitely; callers get `destinationUnresponsive` after the timeout
/// instead, and at most one abandoned call is ever left running.
final class BlockingWorkGate: @unchecked Sendable {
    static let shared = BlockingWorkGate()

    private let lock = NSLock()
    private var outstanding = false

    func run<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard enter() else { throw BackupError.destinationUnresponsive }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let thread = Thread {
                let result = Result { try work() }
                self.leave()
                once.resume(result)
            }
            thread.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(.failure(BackupError.destinationUnresponsive))
            }
        }
    }

    private func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !outstanding else { return false }
        outstanding = true
        return true
    }

    private func leave() {
        lock.lock()
        outstanding = false
        lock.unlock()
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// A Google Drive for desktop account signed in on this Mac.
struct GoogleDriveAccount: Identifiable, Hashable, Sendable {
    let email: String
    let myDrive: URL
    var id: String { email }
}

/// Finds Google Drive for desktop accounts from the names of their mount points
/// in ~/Library/CloudStorage. Only the parent directory is listed, so a hung
/// Drive mount can never block this.
enum GoogleDriveLocator {
    static let prefix = "GoogleDrive-"

    static var cloudStorage: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    }

    static func accounts(in cloudStorage: URL = cloudStorage) -> [GoogleDriveAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path)) ?? []
        return names.compactMap { name -> GoogleDriveAccount? in
            guard name.hasPrefix(prefix), name.count > prefix.count, name.contains("@") else { return nil }
            return GoogleDriveAccount(
                email: String(name.dropFirst(prefix.count)),
                myDrive: cloudStorage.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("My Drive", isDirectory: true))
        }.sorted { $0.email < $1.email }
    }

    /// The Drive account email when `url` lies inside a Drive mount.
    static func email(containing url: URL) -> String? {
        url.standardizedFileURL.pathComponents.first { $0.hasPrefix(prefix) && $0.contains("@") }
            .map { String($0.dropFirst(prefix.count)) }
    }
}

/// Compression runs off the main actor against a private local snapshot. Only
/// the finished, verified ZIP touches the destination, through a timeout gate,
/// and it is published with a rename so Drive never uploads a partial backup.
///
/// The destination holds one up-to-date backup with all data so far, replaced
/// in place on each run, plus the copy it replaced. The previous copy guards
/// against damaged or wiped local data overwriting the only good backup.
actor BackupService {
    static let folderName = "Lumen Backups"
    static let currentName = "Lumen Backup.zip"
    static let previousName = "Lumen Backup (previous).zip"
    /// Timestamped archives written by Lumen 0.6; removed once a current
    /// backup is in place, since it contains everything they did.
    static let legacyPattern = #"^Lumen-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[0-9A-Fa-f-]{36}\.zip$"#
    private var isBusy = false
    private let gate: BlockingWorkGate
    private let destinationTimeout: TimeInterval

    init(gate: BlockingWorkGate = .shared, destinationTimeout: TimeInterval = 180) {
        self.gate = gate
        self.destinationTimeout = destinationTimeout
    }

    static func validateDestination(_ destination: URL, liveDirectory: URL) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        let live = liveDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory),
            isDirectory.boolValue,
            target != live, !target.hasPrefix(live + "/"),
            // Never use a parent that would place the dedicated backup directory
            // over the live directory (also makes custom/test paths safe).
            destination.appendingPathComponent(folderName).resolvingSymlinksInPath().standardizedFileURL.path != live
        else { throw BackupError.invalidDestination }
    }

    func createBackup(
        store: ActivityStore, destination: URL, liveDirectory: URL = ActivityStore.defaultDirectory
    ) async throws -> URL {
        guard !isBusy else { throw BackupError.busy }
        isBusy = true
        defer { isBusy = false }
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("lumen-backup-\(UUID().uuidString)")
        try fm.createDirectory(
            at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("Lumen", isDirectory: true)
        try await store.copyBackupSnapshot(to: snapshot)
        let localArchive = temporary.appendingPathComponent("backup.zip")
        try Self.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--norsrc", snapshot.path, localArchive.path])
        try Self.run("/usr/bin/unzip", ["-tqq", localArchive.path])
        return try await gate.run(timeout: destinationTimeout) {
            try Self.publish(localArchive, to: destination, liveDirectory: liveDirectory)
        }
    }

    /// Everything that touches the destination folder. Blocking by design; only
    /// ever called through the gate.
    private static func publish(_ localArchive: URL, to destination: URL, liveDirectory: URL) throws -> URL {
        let fm = FileManager.default
        try validateDestination(destination, liveDirectory: liveDirectory)
        let folder = destination.appendingPathComponent(folderName, isDirectory: true)
        // Reject a redirected dedicated directory as well as a redirected parent.
        let live = liveDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved != live, !resolved.hasPrefix(live + "/") else { throw BackupError.invalidDestination }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = folder.appendingPathComponent(currentName)
        let previous = folder.appendingPathComponent(previousName)
        let partial = folder.appendingPathComponent(".\(currentName).partial")
        try? fm.removeItem(at: partial)
        defer { try? fm.removeItem(at: partial) }
        try fm.copyItem(at: localArchive, to: partial)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
        try run("/usr/bin/unzip", ["-tqq", partial.path])
        // Only a verified new copy displaces the old one, and the old one is
        // kept as the previous backup rather than deleted.
        if fm.fileExists(atPath: current.path) {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: current, to: previous)
        }
        try fm.moveItem(at: partial, to: current)
        try removeLegacyArchives(in: folder)
        return current
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Never log captured content or command output containing private paths.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackupError.archiveFailed }
    }

    private static func removeLegacyArchives(in folder: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        for entry in entries where entry.lastPathComponent.range(of: legacyPattern, options: .regularExpression) != nil {
            guard try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try fm.removeItem(at: entry)
        }
    }
}

/// Restores are applied before the store or any recording/analysis tasks start.
/// The old data is moved to a sibling folder, never discarded. Selecting an
/// extracted folder avoids executing archive paths supplied by an unknown ZIP.
enum BackupRestore {
    static func pendingDirectory(for live: URL) -> URL {
        live.deletingLastPathComponent().appendingPathComponent("Lumen Pending Restore", isDirectory: true)
    }

    static func stage(from source: URL, live: URL = ActivityStore.defaultDirectory) throws {
        let fm = FileManager.default
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let pending = pendingDirectory(for: live)
        guard root.path != live.resolvingSymlinksInPath().standardizedFileURL.path,
            !root.path.hasPrefix(pending.path + "/"), root.path != pending.path,
            !fm.fileExists(atPath: pending.path)
        else { throw BackupError.invalidBackup }
        try ActivityStore.validateBackup(at: root)
        let temporary = live.deletingLastPathComponent().appendingPathComponent(".lumen-restore-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: root, to: temporary)
        try ActivityStore.validateBackup(at: temporary)
        try fm.moveItem(at: temporary, to: pending)
    }

    @discardableResult
    static func applyIfPending(live: URL = ActivityStore.defaultDirectory) throws -> URL? {
        let fm = FileManager.default
        let pending = pendingDirectory(for: live)
        guard fm.fileExists(atPath: pending.path) else { return nil }
        try ActivityStore.validateBackup(at: pending)
        let preserved = live.deletingLastPathComponent().appendingPathComponent(
            "Lumen Before Restore \(ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString)"
        )
        let hadLive = fm.fileExists(atPath: live.path)
        if hadLive { try fm.moveItem(at: live, to: preserved) }
        do {
            try fm.moveItem(at: pending, to: live)
        } catch {
            if hadLive { try fm.moveItem(at: preserved, to: live) }
            throw error
        }
        return hadLive ? preserved : nil
    }
}
