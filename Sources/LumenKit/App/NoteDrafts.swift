import Foundation
import Observation

/// Drafts outlive the timeline view. Saves are ordered per session, and a
/// completion for one session cannot discard another session's unsaved text.
@MainActor
@Observable
final class NoteDrafts {
    private struct Draft {
        var text: String
        var baseline: String
    }

    private var drafts: [UUID: Draft] = [:]
    @ObservationIgnored private var pending: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]

    func text(for id: UUID, stored: String) -> String {
        drafts[id]?.text ?? stored
    }

    func edit(_ text: String, for id: UUID, stored: String) {
        let baseline = drafts[id]?.baseline ?? stored
        drafts[id] = Draft(text: text, baseline: baseline)
    }

    func hasUnsavedChanges(for id: UUID) -> Bool {
        guard let draft = drafts[id] else { return false }
        return draft.text != draft.baseline
    }

    func reconcile(with segments: [ActivitySegment]) {
        for segment in segments {
            guard let draft = drafts[segment.id], pending[segment.id] == nil,
                draft.text == draft.baseline, draft.text == segment.notes
            else { continue }
            drafts.removeValue(forKey: segment.id)
        }
    }

    @discardableResult
    func save(
        for id: UUID?,
        using persist: @escaping @MainActor (String, UUID) async -> Bool
    ) -> Task<Void, Never>? {
        guard let id, let draft = drafts[id] else { return nil }
        let previous = pending[id]?.task
        // A revert to the original value must still be written if an older
        // save is in flight and might be about to change that original value.
        guard draft.text != draft.baseline || previous != nil else {
            return nil
        }
        let requestID = UUID()
        let text = draft.text
        let task = Task {
            await previous?.value
            let saved = await persist(text, id)
            if saved, var current = drafts[id] {
                // Keep the acknowledged text until analytics catches up;
                // otherwise the editor would briefly reload its stale value.
                current.baseline = text
                drafts[id] = current
            }
            if pending[id]?.id == requestID {
                pending.removeValue(forKey: id)
            }
        }
        pending[id] = (requestID, task)
        return task
    }
}
