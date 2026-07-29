import Foundation

/// The batch-paste queue: collect several things in one pass, then dispense them one
/// per keystroke in the order they were collected.
///
/// Collecting is explicit (its own hyper binding) rather than a mode that reinterprets
/// ⌘C. That means ⌘C and ⌘V keep working exactly as they always have, there is no
/// state the user has to remember being in, and nothing can end up in the queue by
/// accident.
///
/// Holds record identifiers, not payloads, so a queued entry stays in step with the
/// store — deleting it from the history removes it from the queue too.
final class PasteQueue {
    private(set) var ids: [UUID] = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// Position of the next entry to be dispensed, 1-based, for display.
    var position: Int { ids.isEmpty ? 0 : 1 }

    func enqueue(_ id: UUID) {
        // Re-collecting the same entry moves it to the end rather than queueing it
        // twice; queueing the same thing twice is almost always a slip.
        ids.removeAll { $0 == id }
        ids.append(id)
    }

    func enqueue(contentsOf newIDs: [UUID]) {
        for id in newIDs { enqueue(id) }
    }

    func dequeue() -> UUID? {
        ids.isEmpty ? nil : ids.removeFirst()
    }

    func peek() -> UUID? { ids.first }

    func remove(_ id: UUID) {
        ids.removeAll { $0 == id }
    }

    func clear() {
        ids.removeAll()
    }

    /// Drops entries whose records are gone, so a queue can never dispense a hole.
    func prune(against live: Set<UUID>) {
        ids.removeAll { !live.contains($0) }
    }
}
