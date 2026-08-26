import Foundation
import os

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
///
/// The identifiers are mirrored to `queue.json` next to the history. Collecting a dozen
/// paragraphs and then losing them to a restart — or to a crash, or to the app being
/// quit by mistake — is work the user cannot get back by any other means, and the file
/// is a few hundred bytes. Mutation is main-thread only, like `ClipStore`; the write is
/// debounced onto a background queue.
final class PasteQueue {
    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.queue")

    private(set) var ids: [UUID] = []

    /// Injectable so tests can point at a temporary file instead of the real queue.
    private let storeURL: URL

    private let io = DispatchQueue(label: "com.indincys.hyper.pastequeue", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?
    private var restored = false

    init(storeURL: URL = ClipStore.directory.appendingPathComponent("queue.json")) {
        self.storeURL = storeURL
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// Position of the next entry to be dispensed, 1-based, for display.
    var position: Int { ids.isEmpty ? 0 : 1 }

    /// Where an entry sits in the dispensing order, 1-based, or nil when it is not
    /// queued. The panel's queue tab numbers its rows with this.
    func position(of id: UUID) -> Int? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        return index + 1
    }

    func enqueue(_ id: UUID) {
        // Re-collecting the same entry moves it to the end rather than queueing it
        // twice; queueing the same thing twice is almost always a slip.
        ids.removeAll { $0 == id }
        ids.append(id)
        scheduleFlush()
    }

    func enqueue(contentsOf newIDs: [UUID]) {
        for id in newIDs { enqueue(id) }
    }

    func dequeue() -> UUID? {
        guard !ids.isEmpty else { return nil }
        let id = ids.removeFirst()
        scheduleFlush()
        return id
    }

    func peek() -> UUID? { ids.first }

    func remove(_ id: UUID) {
        let before = ids.count
        ids.removeAll { $0 == id }
        if ids.count != before { scheduleFlush() }
    }

    /// Swaps an entry with its neighbour towards the front. Collecting rarely happens in
    /// the order things have to come out in, and reordering by hand is cheaper than
    /// emptying the queue and starting again.
    ///
    /// Silent at the ends rather than an error: the menu item stays enabled, and the
    /// answer to "上移" on the first entry is simply that nothing moves.
    func moveUp(_ id: UUID) {
        guard let index = ids.firstIndex(of: id), index > 0 else { return }
        ids.swapAt(index, index - 1)
        scheduleFlush()
    }

    func moveDown(_ id: UUID) {
        guard let index = ids.firstIndex(of: id), index < ids.count - 1 else { return }
        ids.swapAt(index, index + 1)
        scheduleFlush()
    }

    func clear() {
        guard !ids.isEmpty else { return }
        ids.removeAll()
        scheduleFlush()
    }

    /// Drops entries whose records are gone, so a queue can never dispense a hole.
    func prune(against live: Set<UUID>) {
        let before = ids.count
        ids.removeAll { !live.contains($0) }
        guard ids.count != before else { return }
        log.info("queue pruned: \(before - self.ids.count) entries no longer in the history")
        scheduleFlush()
    }

    // MARK: - Persistence

    /// Reads the queue back off disk. Synchronous on purpose: the file holds at most a
    /// few dozen UUIDs, and the menu bar wants the right depth on the first draw rather
    /// than a zero that corrects itself a moment later.
    func restore() {
        guard !restored else { return }
        restored = true
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode([UUID].self, from: data) else {
            // A queue is a convenience, not a record of anything; a file that will not
            // decode is worth one log line and nothing more. It gets overwritten by the
            // next change.
            log.error("queue file is unreadable; starting with an empty queue")
            return
        }
        ids = decoded
        log.info("paste queue restored: \(self.ids.count) entries")
    }

    /// Debounced: dequeueing five entries in a row produces one write, not five.
    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let snapshot = ids
        let url = storeURL
        let item = DispatchWorkItem { [log] in
            PasteQueue.write(snapshot, to: url, log: log)
        }
        flushWorkItem = item
        io.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Writes immediately. Called on quit, where a debounced write would be cancelled by
    /// the process going away — which is precisely the case this file exists for.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        PasteQueue.write(ids, to: storeURL, log: log)
    }

    private static func write(_ ids: [UUID], to url: URL, log: Logger) {
        do {
            // The store normally creates this directory first, but the queue must not
            // depend on that ordering to be able to save anything.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(ids).write(to: url, options: .atomic)
        } catch {
            log.error("queue write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
