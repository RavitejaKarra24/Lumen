import Foundation

@testable import LumenKit

func runBackupTests() async {
    await runTest("backup: pending edits reach a verified archive while later tracking stays local") {
        let root = TestSupport.makeStoreDirectory()
        let live = root.appendingPathComponent("live")
        let target = root.appendingPathComponent("drive")
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let store = ActivityStore(directory: live)
        let segment = TestSupport.segment(
            from: .now.addingTimeInterval(-60), to: .now, tags: ["backup"], notes: "pending edit")
        try await store.insert(segment)
        // No explicit flush: the consistent snapshot must drain the write queue.
        let archive = try await BackupService().createBackup(store: store, destination: target, liveDirectory: live)
        let extracted = root.appendingPathComponent("extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        checkEqual(process.terminationStatus, 0, "archive extracts")
        let snapshot = extracted.appendingPathComponent("Lumen")
        try ActivityStore.validateBackup(at: snapshot)
        let restored = try await ActivityStore(directory: snapshot).allSegments()
        checkEqual(restored.first?.notes, "pending edit", "unflushed note captured")
        checkEqual(restored.first?.tags, ["backup"], "tags captured")
        try await store.setNotes(id: segment.id, notes: "after snapshot")
        checkEqual(try await store.segment(id: segment.id)?.notes, "after snapshot", "live store keeps recording")
        checkEqual(
            try await ActivityStore(directory: snapshot).segment(id: segment.id)?.notes, "pending edit",
            "snapshot stays immutable")
        let entries = try fm.contentsOfDirectory(atPath: archive.deletingLastPathComponent().path)
        check(!entries.contains { $0.hasSuffix(".partial") }, "no partial files published")
    }

    await runTest("backup: one current file holds all data, the replaced copy is kept as previous") {
        let root = TestSupport.makeStoreDirectory()
        let target = root.appendingPathComponent("drive")
        let live = root.appendingPathComponent("live")
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = target.appendingPathComponent(BackupService.folderName)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = folder.appendingPathComponent(
            "Lumen-2026-11-03T18-19-45Z-DE7F17C9-8A71-4F89-85AD-235431ADDF75.zip")
        try Data("old".utf8).write(to: legacy)
        let unrelated = folder.appendingPathComponent("my-backup.zip")
        try Data("keep".utf8).write(to: unrelated)

        func notes(in archive: URL) throws -> [String] {
            let extracted = root.appendingPathComponent("x-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, extracted.path]
            try process.run()
            process.waitUntilExit()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try Data(contentsOf: extracted.appendingPathComponent("Lumen/segments.json"))
            return try decoder.decode([ActivitySegment].self, from: data).sorted { $0.startAt < $1.startAt }.map(\.notes)
        }

        let store = ActivityStore(directory: live)
        let service = BackupService()
        let base = Date.now.addingTimeInterval(-3600)
        try await store.insert(TestSupport.segment(from: base, to: base.addingTimeInterval(60), notes: "week 1"))
        let first = try await service.createBackup(store: store, destination: target, liveDirectory: live)
        checkEqual(first.lastPathComponent, BackupService.currentName, "stable file name")
        check(!fm.fileExists(atPath: legacy.path), "timestamped 0.6 archives cleaned up")
        check(fm.fileExists(atPath: unrelated.path), "unrelated files preserved")

        try await store.insert(
            TestSupport.segment(from: base.addingTimeInterval(120), to: base.addingTimeInterval(180), notes: "week 2"))
        _ = try await service.createBackup(store: store, destination: target, liveDirectory: live)
        try await store.insert(
            TestSupport.segment(from: base.addingTimeInterval(240), to: base.addingTimeInterval(300), notes: "week 3"))
        let latest = try await service.createBackup(store: store, destination: target, liveDirectory: live)

        let names = Set(try fm.contentsOfDirectory(atPath: folder.path))
        checkEqual(names, [BackupService.currentName, BackupService.previousName, "my-backup.zip"], "file count stays fixed")
        checkEqual(try notes(in: latest), ["week 1", "week 2", "week 3"], "current backup has all data so far")
        checkEqual(
            try notes(in: folder.appendingPathComponent(BackupService.previousName)), ["week 1", "week 2"],
            "previous backup is the copy it replaced")

        do {
            _ = try await service.createBackup(
                store: store, destination: target.appendingPathComponent("missing"), liveDirectory: live)
            check(false, "missing destination rejected")
        } catch {
            checkEqual(Set(try fm.contentsOfDirectory(atPath: folder.path)), names, "failure leaves existing copies")
        }
    }

    await runTest("backup: live data and symlink destinations are rejected") {
        let root = TestSupport.makeStoreDirectory()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        let link = root.deletingLastPathComponent().appendingPathComponent("lumen-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: nested)
        defer { try? fm.removeItem(at: link) }
        for destination in [root, nested, link] {
            do {
                try BackupService.validateDestination(destination, liveDirectory: root)
                check(false, "unsafe destination rejected")
            } catch { check(true, "unsafe destination rejected") }
        }
    }

    await runTest("backup: daily scheduling catches up without repeating a successful day") {
        let now = TestSupport.date(2026, 10, 28, 14)
        check(BackupController.isDue(lastBackup: nil, frequency: .daily, now: now), "first backup due")
        check(!BackupController.isDue(lastBackup: now.addingTimeInterval(-60), frequency: .daily, now: now), "same day skipped")
        check(
            BackupController.isDue(lastBackup: now.addingTimeInterval(-86400 * 3), frequency: .daily, now: now),
            "missed days caught up")
    }

    await runTest("backup: weekly waits seven days and survives a clock moved backwards") {
        let now = TestSupport.date(2026, 10, 28, 14)
        check(
            !BackupController.isDue(lastBackup: now.addingTimeInterval(-6 * 86400), frequency: .weekly, now: now),
            "weekly waits")
        check(
            BackupController.isDue(lastBackup: now.addingTimeInterval(-7 * 86400), frequency: .weekly, now: now),
            "weekly due")
        check(
            BackupController.isDue(lastBackup: now.addingTimeInterval(86400), frequency: .weekly, now: now),
            "future timestamp does not suspend backups")
    }

    await runTest("backup: removed hourly settings fall back to weekly") {
        let domain = "lumen-backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("every3Hours", forKey: "backup.frequency")
        let controller = BackupController(
            defaults: defaults, store: ActivityStore(directory: TestSupport.makeStoreDirectory()), gate: BlockingWorkGate())
        checkEqual(controller.frequency, .weekly, "3-hourly migrates to weekly")
    }

    await runTest("backup: a hung destination times out and never stacks blocked threads") {
        let gate = BlockingWorkGate()
        let started = Date.now
        do {
            _ = try await gate.run(timeout: 0.2) { Thread.sleep(forTimeInterval: 1.0) }
            check(false, "hung work times out")
        } catch BackupError.destinationUnresponsive {
            check(Date.now.timeIntervalSince(started) < 0.8, "timeout returns promptly")
        }
        do {
            _ = try await gate.run(timeout: 5) { 1 }
            check(false, "second call refused while first is stuck")
        } catch BackupError.destinationUnresponsive {
            check(true, "second call refused while first is stuck")
        }
        try await Task.sleep(for: .seconds(1.2))
        checkEqual(try await gate.run(timeout: 5) { 42 }, 42, "gate reopens once the stuck call finishes")
    }

    await runTest("backup: Google Drive accounts are found from mount point names only") {
        let root = TestSupport.makeStoreDirectory()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        for name in ["GoogleDrive-me@gmail.com", "GoogleDrive-work@school.edu", "OneDrive-Personal", "GoogleDrive-"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let accounts = GoogleDriveLocator.accounts(in: root)
        checkEqual(accounts.map(\.email), ["me@gmail.com", "work@school.edu"], "only Drive accounts listed")
        checkEqual(accounts.first?.myDrive.lastPathComponent, "My Drive", "targets My Drive")
        checkEqual(
            GoogleDriveLocator.email(containing: accounts[0].myDrive.appendingPathComponent("Backups")),
            "me@gmail.com", "account recognised from a nested folder")
        check(GoogleDriveLocator.email(containing: root) == nil, "plain folders have no account")
        check(GoogleDriveLocator.accounts(in: root.appendingPathComponent("missing")).isEmpty, "no CloudStorage, no accounts")
    }

    await runTest("backup: automatic runs wait for the network and start when it returns") {
        let root = TestSupport.makeStoreDirectory()
        let target = root.appendingPathComponent("drive")
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let domain = "lumen-backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? fm.removeItem(at: root)
        }
        let controller = BackupController(
            defaults: defaults, store: ActivityStore(directory: root.appendingPathComponent("live")),
            gate: BlockingWorkGate())
        try await controller.setFolder(target)
        await controller.networkChanged(online: false)
        check(controller.isWaitingForNetwork, "offline and due reports waiting")
        await controller.backUpIfDue()
        check(controller.lastBackupAt == nil, "no automatic backup offline")
        await controller.networkChanged(online: true)
        check(controller.lastBackupAt != nil, "reconnecting runs the due backup")
        check(!controller.isWaitingForNetwork, "no longer waiting")
        checkEqual(controller.frequency, .weekly, "defaults to weekly")
    }

    await runTest("backup: folder choice and success persist, errors keep the last successful date") {
        let root = TestSupport.makeStoreDirectory()
        let target = root.appendingPathComponent("drive")
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let domain = "lumen-backup-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? fm.removeItem(at: root)
        }
        let store = ActivityStore(directory: root.appendingPathComponent("live"))
        let controller = BackupController(defaults: defaults, store: store, gate: BlockingWorkGate())
        try await controller.setFolder(target)
        check(controller.automaticEnabled, "choosing a folder enables automatic backups")
        let now = Date.now
        await controller.backUpIfDue(now: now)
        checkEqual(controller.lastBackupAt, now, "success timestamp recorded")
        controller.frequency = .daily
        let reloaded = BackupController(defaults: defaults, store: store, gate: BlockingWorkGate())
        checkEqual(
            reloaded.folderURL?.resolvingSymlinksInPath().path, target.resolvingSymlinksInPath().path,
            "folder choice survives relaunch")
        checkEqual(reloaded.frequency, .daily, "frequency survives relaunch")
        checkEqual(reloaded.lastBackupAt, now, "success survives relaunch")
        await controller.backUpIfDue(now: now.addingTimeInterval(120))
        checkEqual(
            try fm.contentsOfDirectory(atPath: target.appendingPathComponent(BackupService.folderName).path).count, 1,
            "no duplicate automatic backup")
        try fm.moveItem(at: target, to: root.appendingPathComponent("offline"))
        await controller.backUpNow(now: now.addingTimeInterval(300))
        check(controller.lastError != nil, "unavailable destination surfaced")
        checkEqual(controller.lastBackupAt, now, "failure does not advance success")
        check(defaults.string(forKey: "backup.lastError") != nil, "error persists for next launch")
        try fm.moveItem(at: root.appendingPathComponent("offline"), to: target)
        await controller.backUpNow(now: now.addingTimeInterval(600))
        check(controller.lastError == nil, "successful retry clears error")
    }

    await runTest("restore: validated snapshot replaces data only at startup and preserves original") {
        let root = TestSupport.makeStoreDirectory()
        let live = root.appendingPathComponent("Lumen")
        let snapshot = root.appendingPathComponent("snapshot")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let store = ActivityStore(directory: live)
        let segment = TestSupport.segment(from: .now.addingTimeInterval(-60), to: .now, notes: "backup")
        try await store.insert(segment)
        try await store.copyBackupSnapshot(to: snapshot)
        try await store.setNotes(id: segment.id, notes: "current")
        try await store.flush()
        try BackupRestore.stage(from: snapshot, live: live)
        checkEqual(
            try await ActivityStore(directory: live).segment(id: segment.id)?.notes, "current",
            "staging leaves live data intact")
        let preserved = try BackupRestore.applyIfPending(live: live)
        checkEqual(
            try await ActivityStore(directory: live).segment(id: segment.id)?.notes, "backup", "snapshot becomes live")
        if let preserved {
            checkEqual(
                try await ActivityStore(directory: preserved).segment(id: segment.id)?.notes, "current",
                "original recoverable")
        } else {
            check(false, "original folder preserved")
        }
        check(!fm.fileExists(atPath: BackupRestore.pendingDirectory(for: live).path), "pending restore consumed")
        check(try BackupRestore.applyIfPending(live: live) == nil, "restore only applies once")
    }

    await runTest("restore: malformed or newer data cannot replace live data") {
        let root = TestSupport.makeStoreDirectory()
        let live = root.appendingPathComponent("Lumen")
        let snapshot = root.appendingPathComponent("snapshot")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let store = ActivityStore(directory: live)
        try await store.copyBackupSnapshot(to: snapshot)
        try Data("broken".utf8).write(to: snapshot.appendingPathComponent("segments.json"))
        do {
            try BackupRestore.stage(from: snapshot, live: live)
            check(false, "corrupt backup rejected")
        } catch { check(true, "corrupt backup rejected") }
        check(!fm.fileExists(atPath: BackupRestore.pendingDirectory(for: live).path), "invalid restore never staged")
        try Data("[]".utf8).write(to: snapshot.appendingPathComponent("segments.json"))
        try Data(#"{"schemaVersion":999,"writtenAt":"2026-10-28T00:00:00Z"}"#.utf8).write(
            to: snapshot.appendingPathComponent("store-meta.json"))
        do {
            try BackupRestore.stage(from: snapshot, live: live)
            check(false, "newer schema rejected")
        } catch { check(true, "newer schema rejected") }
        check(fm.fileExists(atPath: live.path), "live store untouched")
    }
}
