import Foundation

@testable import LumenKit

@MainActor
func runNoteDraftTests() async {
    await runTest("notes: saving another session cannot erase a failed draft") {
        let drafts = NoteDrafts()
        let first = UUID()
        let second = UUID()
        drafts.edit("first edit", for: first, stored: "")
        await drafts.save(for: first) { _, _ in false }?.value
        drafts.edit("second edit", for: second, stored: "")
        await drafts.save(for: second) { _, _ in true }?.value
        checkEqual(drafts.text(for: first, stored: ""), "first edit", "failed text survives")
        check(drafts.hasUnsavedChanges(for: first), "failed edit can be retried")
        check(!drafts.hasUnsavedChanges(for: second), "successful edit acknowledged")
    }

    await runTest("notes: successive failed edits keep the latest text") {
        let drafts = NoteDrafts()
        let id = UUID()
        drafts.edit("first", for: id, stored: "")
        await drafts.save(for: id) { _, _ in false }?.value
        drafts.edit("latest", for: id, stored: "")
        await drafts.save(for: id) { _, _ in false }?.value
        checkEqual(drafts.text(for: id, stored: ""), "latest", "latest failure is retained")
    }

    await runTest("notes: saves are ordered and an in-flight revert is persisted") {
        let drafts = NoteDrafts()
        let id = UUID()
        var writes: [String] = []
        drafts.edit("new", for: id, stored: "original")
        let first = drafts.save(for: id) { text, _ in
            await Task.yield()
            writes.append(text)
            return true
        }
        drafts.edit("original", for: id, stored: "original")
        let second = drafts.save(for: id) { text, _ in
            writes.append(text)
            return true
        }
        await first?.value
        await second?.value
        checkEqual(writes, ["new", "original"], "revert follows the older write")
        checkEqual(drafts.text(for: id, stored: "original"), "original", "reverted text shown")
    }

    await runTest("notes: older completion does not replace a newer unsaved edit") {
        let drafts = NoteDrafts()
        let id = UUID()
        drafts.edit("submitted", for: id, stored: "")
        let save = drafts.save(for: id) { _, _ in true }
        drafts.edit("still typing", for: id, stored: "")
        await save?.value
        checkEqual(drafts.text(for: id, stored: "submitted"), "still typing", "new draft preserved")
        check(drafts.hasUnsavedChanges(for: id), "new text still needs saving")
    }

    await runTest("notes: successful text survives stale analytics until reconciliation") {
        let drafts = NoteDrafts()
        var segment = TestSupport.segment(from: .now.addingTimeInterval(-30), to: .now, notes: "old")
        drafts.edit("saved", for: segment.id, stored: segment.notes)
        await drafts.save(for: segment.id) { _, _ in true }?.value
        drafts.reconcile(with: [segment])
        checkEqual(drafts.text(for: segment.id, stored: segment.notes), "saved", "stale refresh cannot undo save")
        segment.notes = "saved"
        drafts.reconcile(with: [segment])
        checkEqual(
            drafts.text(for: segment.id, stored: "external update"), "external update",
            "synced draft releases cached text")
    }
}
