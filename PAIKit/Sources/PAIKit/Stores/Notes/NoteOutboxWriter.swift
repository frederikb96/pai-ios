import Dispatch
import Foundation

/// Writes pending edits to the note outbox, either at once or a moment later.
///
/// Typing changes the draft on every keystroke, and writing the whole record (the draft plus the
/// version it was typed over) each time costs a file create and rename on the main actor. So a
/// keystroke only hands the latest record over (``saveSoon(_:)``) and one write per note follows
/// after a short quiet period, encoded and written on a queue of its own.
///
/// 🚨 Every other write has finished by the time its call returns (``save(_:)``,
/// ``saveInBackground(_:)``, ``remove(noteId:)``) and is what the store calls before a request
/// leaves and whenever a draft ends. All of them run in order on the queue, and an immediate write
/// drops the note's deferred one, so a deferred write can never land after a newer record or
/// resurrect a removed one: it either finished before, and is replaced, or never runs.
final class NoteOutboxWriter: @unchecked Sendable {
    private let storage: NoteOutboxStorage
    private let delay: DispatchTimeInterval
    private let queue = DispatchQueue(label: "notes.outbox-writer", qos: .utility)
    private let lock = NSLock()
    private var deferred: [String: NotePendingEdit] = [:]
    private var scheduled = false

    init(storage: NoteOutboxStorage, delay: Duration) {
        self.storage = storage
        let (seconds, attoseconds) = delay.components
        self.delay = .nanoseconds(Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
    }

    /// Keeps `edit` as the note's next record and writes it after the quiet period, together with
    /// whatever other notes changed meanwhile.
    func saveSoon(_ edit: NotePendingEdit) {
        lock.withLock {
            deferred[edit.noteId] = edit
            guard !scheduled else { return }
            scheduled = true
            queue.asyncAfter(deadline: .now() + delay) { [self] in writeDeferredOnQueue() }
        }
    }

    func save(_ edit: NotePendingEdit) {
        dropDeferred(noteId: edit.noteId)
        queue.sync { storage.saveEdit(edit) }
    }

    /// ``save(_:)`` for a caller on the main actor: encoding a large note and writing it is real
    /// work, and the record is on disk when this returns all the same.
    func saveInBackground(_ edit: NotePendingEdit) async {
        dropDeferred(noteId: edit.noteId)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                storage.saveEdit(edit)
                done.resume()
            }
        }
    }

    func remove(noteId: String) {
        dropDeferred(noteId: noteId)
        queue.sync { storage.removeEdit(noteId: noteId) }
    }

    /// Writes every deferred record now. For a caller that is about to lose the process.
    func writeDeferred() {
        queue.sync { writeDeferredOnQueue() }
    }

    private func dropDeferred(noteId: String) {
        lock.withLock { deferred[noteId] = nil }
    }

    /// The disk is only touched from the queue, in order, so the lock a keystroke's ``saveSoon(_:)``
    /// takes is never held across a write and a record taken here cannot land after a newer one.
    private func writeDeferredOnQueue() {
        let pending = lock.withLock {
            let pending = deferred
            deferred = [:]
            scheduled = false
            return pending
        }
        for edit in pending.values { storage.saveEdit(edit) }
    }
}
