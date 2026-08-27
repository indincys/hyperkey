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
    /// A dequeue is a two-phase operation. Preparing reserves the current head without
    /// changing `ids`; only a successful paste delivery may commit it. The nonce keeps
    /// a stale completion from removing an entry reserved by a later attempt.
    struct DequeueTicket: Equatable {
        fileprivate let id: UUID
        fileprivate let nonce: UUID
    }

    enum DequeueCommitFailure: Equatable {
        case invalidated(expectedID: UUID, currentHead: UUID?)
        case persistenceFailed(id: UUID)
    }

    enum DequeueCommitResult: Equatable {
        case committed(UUID)
        case failed(DequeueCommitFailure)
    }

    private let log = Logger(subsystem: Hyper.subsystem, category: "clipboard.queue")

    private(set) var ids: [UUID] = []

    /// Injectable so tests can point at a temporary file instead of the real queue.
    private let storeURL: URL

    private let io = DispatchQueue(label: "com.indincys.hyper.pastequeue", qos: .utility)
    private var flushWorkItem: DispatchWorkItem?
    private var restored = false
    private var preparedDequeue: DequeueTicket?

    init(storeURL: URL = ClipStore.directory.appendingPathComponent("queue.json")) {
        self.storeURL = storeURL
    }

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    /// Position of the next entry to be dispensed, 1-based, for display.
    var position: Int { ids.isEmpty ? 0 : 1 }

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
        guard let ticket = prepareDequeue() else { return nil }
        guard case .committed(let id) = commitDequeue(ticket) else { return nil }
        return id
    }

    func peek() -> UUID? { ids.first }

    /// Reserves, but deliberately does not remove, the head entry.
    func prepareDequeue() -> DequeueTicket? {
        guard preparedDequeue == nil, let id = ids.first else { return nil }
        let ticket = DequeueTicket(id: id, nonce: UUID())
        preparedDequeue = ticket
        return ticket
    }

    /// Removes exactly the head represented by `ticket`. A successful return is also a
    /// durability boundary: the new queue is on disk before this method reports that the
    /// item was consumed. A stale activation completion can therefore neither remove the
    /// wrong item nor claim success after the user reordered the queue.
    @discardableResult
    func commitDequeue(_ ticket: DequeueTicket) -> DequeueCommitResult {
        guard preparedDequeue == ticket, ids.first == ticket.id else {
            if preparedDequeue == ticket { preparedDequeue = nil }
            return .failed(
                .invalidated(expectedID: ticket.id, currentHead: ids.first)
            )
        }

        let remaining = Array(ids.dropFirst())
        flushWorkItem?.cancel()
        flushWorkItem = nil
        if restored {
            var persisted = false
            // Every queued write runs on `io`. Waiting behind any write that was already
            // executing and then writing the committed snapshot last prevents an older,
            // debounced enqueue from resurrecting the consumed head after a process kill.
            io.sync {
                persisted = PasteQueue.write(remaining, to: storeURL, log: log)
            }
            guard persisted else {
                preparedDequeue = nil
                scheduleFlush()
                return .failed(.persistenceFailed(id: ticket.id))
            }
        }

        preparedDequeue = nil
        ids = remaining
        return .committed(ticket.id)
    }

    /// Releases the reservation after any preparation/activation/event failure. No
    /// persistence is scheduled because the durable queue never changed.
    func rollbackDequeue(_ ticket: DequeueTicket) {
        guard preparedDequeue == ticket else { return }
        preparedDequeue = nil
    }

    func remove(_ id: UUID) {
        let before = ids.count
        ids.removeAll { $0 == id }
        if preparedDequeue?.id == id { preparedDequeue = nil }
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
        preparedDequeue = nil
        scheduleFlush()
    }

    /// Drops entries whose records are gone, so a queue can never dispense a hole.
    func prune(against live: Set<UUID>) {
        let before = ids.count
        ids.removeAll { !live.contains($0) }
        if let preparedDequeue, !live.contains(preparedDequeue.id) {
            self.preparedDequeue = nil
        }
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
    ///
    /// Nothing is written before `restore()` has run. `restore` only happens when the
    /// clipboard feature starts, so with the feature switched off `ids` is an empty array
    /// that was never read from disk — and writing it out would destroy a queue the user
    /// collected during their last session.
    private func scheduleFlush() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard restored else { return }
        let snapshot = ids
        let url = storeURL
        let item = DispatchWorkItem { [log] in
            _ = PasteQueue.write(snapshot, to: url, log: log)
        }
        flushWorkItem = item
        io.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// Writes immediately. Called on quit, where a debounced write would be cancelled by
    /// the process going away — which is precisely the case this file exists for.
    ///
    /// Guarded like `scheduleFlush`: quitting with the clipboard feature switched off
    /// reaches this through `applicationWillTerminate`, and an unrestored queue would
    /// write `[]` over whatever the user had collected.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        guard restored else {
            log.info("queue flush skipped: nothing was restored, so there is nothing to save")
            return
        }
        let snapshot = ids
        io.sync {
            _ = PasteQueue.write(snapshot, to: storeURL, log: log)
        }
    }

    @discardableResult
    private static func write(_ ids: [UUID], to url: URL, log: Logger) -> Bool {
        do {
            // The store normally creates this directory first, but the queue must not
            // depend on that ordering to be able to save anything.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(ids).write(to: url, options: .atomic)
            return true
        } catch {
            log.error("queue write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
