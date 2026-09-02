import Foundation
import IOKit
import IOKit.hid
import IOKit.hidsystem
import os

/// Remaps Caps Lock to F19 at the IOKit HID layer.
///
/// This has to happen below the event-tap layer. macOS resolves the caps-lock state
/// and its LED inside IOHIDSystem *before* events reach a `CGEventTap`, so a tap can
/// swallow the event but cannot stop the lock state from toggling, and it still eats
/// the built-in caps-lock press delay. Remapping the HID usage sidesteps both: the key
/// never reaches the caps-lock logic at all, it arrives as a plain F19.
///
/// `UserKeyMapping` is a single system-wide list, so this takes care to own exactly one
/// entry in it. Whatever else is in the list when we start is carried through untouched
/// and put back on exit.
enum HIDRemapper {
    private static let log = Logger(subsystem: Hyper.subsystem, category: "hid")

    private static let capsLockUsage: UInt64 = 0x7000_00039
    /// F19 — see `Keys.hyperTrigger` for why it is not F18.
    private static let triggerUsage: UInt64 = 0x7000_0006E
    /// F18 — what `tapAction` synthesizes, and what Caps Lock is *temporarily* mapped
    /// to during a recording window. See `beginRecordingWindow`.
    private static let tapKeyUsage: UInt64 = 0x7000_0006D

    /// Everything that reads or writes `UserKeyMapping` runs here, in order.
    ///
    /// The list is a single system-wide property and every write is a whole-list replace,
    /// so two overlapping writers do not merge — the loser's entries simply vanish. The
    /// overlap is real: a keyboard attaching schedules a reapply while quit is restoring
    /// the baseline, and the reapply that lands last leaves Caps Lock remapped to a key
    /// belonging to a process that no longer exists.
    private static let queue = DispatchQueue(label: "\(Hyper.subsystem).hid")
    private static var notifyPort: IONotificationPortRef?
    private static var matchIterator: io_iterator_t = 0
    private static var terminateIterator: io_iterator_t = 0

    /// Queue-confined. `dispatchPrecondition` in every accessor is what keeps that true
    /// as the file changes.
    private static var reapplyWorkItem: DispatchWorkItem?

    /// Set the instant `restore()` is entered, so every later `apply()` is a no-op.
    ///
    /// Behind a lock rather than on `queue`, because the ordering it exists to guarantee
    /// is the one thing the queue cannot give it: if this were set from inside a queued
    /// block, a reapply already sitting ahead of it in the queue would still run, put our
    /// mapping back, and be the last write before the process exits.
    private static let shuttingDown = OSAllocatedUnfairLock(initialState: false)
    private static var isShuttingDown: Bool { shuttingDown.withLock { $0 } }

    /// A copy of the baseline that anything may read, published by `captureBaseline`.
    ///
    /// `nil` means no baseline was ever captured — the state in which writing the list
    /// would be destructive. This exists purely so `restore()`'s timeout path has
    /// something to write that it does not have to read off `queue` from another thread.
    private static let publishedBaseline = OSAllocatedUnfairLock<[Mapping]?>(initialState: nil)

    /// Raw keyboard elements used to answer whether the physical Hyper key is still
    /// held. `CGEventSource.keyState` cannot answer this after a `UserKeyMapping`:
    /// on real hardware it reports remapped F19 as up roughly 400ms into a perfectly
    /// valid hold, even though the F19 key-up event has not happened yet. Polling the
    /// device elements stays below that mapping and therefore sees Caps Lock itself.
    /// Main-thread-only; the event tap and device notifications both live there.
    private static var physicalStateManager: IOHIDManager?
    private static var physicalTriggerElements: [(IOHIDDevice, IOHIDElement)]?
    /// When discovery last ran. An empty result is never cached — a keyboard that has
    /// not finished enumerating yet would otherwise pin "raw HID unavailable" for the
    /// rest of the session, and the hold watchdog would fall back to its 10s guess on
    /// every hold forever after. Rediscovery is rate-limited instead, because the
    /// watchdog asks this several times a second while the key is held.
    private static var lastElementDiscovery: CFAbsoluteTime = 0
    private static let elementDiscoveryInterval: CFAbsoluteTime = 1

    /// Mappings that existed before we touched anything. Captured once, restored on exit.
    private static var foreignMappings: [Mapping] = []
    private static var baselineCaptured = false

    private struct Mapping: Sendable {
        let src: UInt64
        let dst: UInt64
        var json: String {
            "{\"HIDKeyboardModifierMappingSrc\":\(src),\"HIDKeyboardModifierMappingDst\":\(dst)}"
        }
    }

    // MARK: - Apply / restore

    /// Applies the mapping. Returns whether it verifiably took effect.
    @discardableResult
    static func apply() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isShuttingDown else {
            log.info("apply skipped: the mapping is being restored for shutdown")
            return false
        }
        captureBaseline()
        let entries = foreignMappings + [Mapping(src: capsLockUsage, dst: currentDestination)]
        guard write(entries) else {
            log.error("hidutil --set failed")
            return false
        }
        let ok = isApplied()
        log.info("caps lock -> \(keyName(currentDestination), privacy: .public) mapping applied: \(ok, privacy: .public)")
        if ok { clearCapsLockLatch() }
        return ok
    }

    /// Turns the caps lock *latch* off if it happens to be on as we take the key over.
    ///
    /// The window this closes is small and entirely self-inflicted: between `restore()`
    /// on quit and `apply()` on the next launch, Caps Lock is a real Caps Lock again.
    /// An update installs itself exactly that way — quit, replace, relaunch — so any
    /// press landing in those few seconds latches caps on. And once we remap the key,
    /// nothing can turn it back off: the only key that toggles caps is now an F19.
    ///
    /// The user is left holding a keyboard stuck in capitals with no key that fixes it,
    /// and no reason to connect it to this app. So it is cleared here rather than left
    /// for them to discover.
    private static func clearCapsLockLatch() {
        var conn: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS
        else { return }
        defer { IOServiceClose(conn) }

        var latched = false
        IOHIDGetModifierLockState(conn, Int32(kIOHIDCapsLockState), &latched)
        guard latched else { return }
        IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), false)
        log.info("caps lock was latched on while unmapped; cleared it")
    }

    static func applyAsync() {
        queue.async { _ = apply() }
    }

    /// Puts `UserKeyMapping` back the way we found it — our entry gone, everyone
    /// else's entries intact.
    ///
    /// Synchronous on purpose: this is the last thing that runs before the process exits,
    /// and a `queue.async` would be thrown away with the process. It is also the one place
    /// that must not block forever, because a wedged `hidutil` would then hang the quit
    /// and leave Caps Lock remapped anyway — hence the bounded wait and the last-resort
    /// write on this thread.
    ///
    /// **One-way latch: exit paths only.** `shuttingDown` is never cleared, so from the
    /// moment this is entered every `apply()` and every `scheduleReapply()` for the rest
    /// of the process is a no-op. That is the point — a keyboard attaching a second after
    /// the user hits Quit must not put our mapping back on the way out. There is
    /// deliberately no way to reopen it: a caller that wanted the mapping back would have
    /// to be sure nothing had already restored the baseline, and nothing here can know
    /// that. Anything that needs Hyper live again relaunches the app.
    static func restore() {
        // Blocking on `queue` from `queue` would deadlock outright.
        dispatchPrecondition(condition: .notOnQueue(queue))

        // Before anything is queued: a reapply already waiting in line has to find the
        // door shut, not shut it behind them.
        shuttingDown.withLock { $0 = true }
        // Read once, here, from the lock-protected copy. The timeout path below runs on
        // this thread while `queue` may still be live, and `foreignMappings` belongs to
        // `queue` — so it is never touched from here.
        let snapshot = publishedBaseline.withLock { $0 }

        let finished = DispatchSemaphore(value: 0)
        queue.async {
            reapplyWorkItem?.cancel()
            reapplyWorkItem = nil
            restoreOnQueue()
            finished.signal()
        }

        guard finished.wait(timeout: .now() + 2) == .timedOut else { return }
        // The queued write may still be in flight, but the two writes have identical
        // content, and an unrestored Caps Lock is worse than a duplicate `hidutil` call.
        log.error("hid queue did not drain within 2s; restoring on the calling thread")
        writeBaseline(snapshot, source: "timeout fallback")
    }

    private static func restoreOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        writeBaseline(baselineCaptured ? foreignMappings : nil, source: "hid queue")
    }

    /// Never writes the list without having read it first. An absent baseline and an
    /// empty one look identical once written — and in the absent case the write would
    /// delete whatever mappings some *other* tool set, which we have no way to put back.
    private static func writeBaseline(_ mappings: [Mapping]?, source: String) {
        guard let mappings else {
            log.info("no baseline captured (\(source, privacy: .public)); leaving UserKeyMapping untouched")
            return
        }
        _ = write(mappings)
        log.info("caps lock mapping removed via \(source, privacy: .public), \(mappings.count) foreign mapping(s) restored")
    }

    static func isApplied() -> Bool {
        currentMappings().contains { $0.src == capsLockUsage && $0.dst == currentDestination }
    }

    // MARK: - Recording window

    /// Whether Caps Lock is, right now, temporarily behaving as F18.
    ///
    /// Written from the main thread when the window opens and closes, read on `queue` by
    /// `currentDestination` — the same cross-thread shape as `shuttingDown`, behind the
    /// same kind of lock. What an unsynchronised read costs here is the wrong key code
    /// written into `UserKeyMapping`, in either direction: Caps Lock left as F18 after
    /// the window closed, so every hyper hold fires whatever shortcut the user just
    /// recorded, or back to F19 while it is still open, so the recorder captures the
    /// trigger key the window exists to hide from it.
    private static let recordingWindow = OSAllocatedUnfairLock(initialState: false)
    static var isRecordingWindowOpen: Bool { recordingWindow.withLock { $0 } }

    /// Main-thread-only, like every other timer in this file.
    private static var recordingEnd: DispatchWorkItem?

    private static var currentDestination: UInt64 { isRecordingWindowOpen ? tapKeyUsage : triggerUsage }

    private static func keyName(_ usage: UInt64) -> String { usage == tapKeyUsage ? "F18" : "F19" }

    /// Turns Caps Lock into a plain F18 for a few seconds.
    ///
    /// This exists because of a genuine chicken-and-egg problem. The point of `tapAction`
    /// sending F18 is that no keyboard has that key, so nothing else can produce it — but
    /// that also means the user cannot *press* it to record it in the application they
    /// want to trigger. Pressing Caps Lock in a recorder captures F19, the trigger key,
    /// and then every hold fires that application's shortcut too.
    ///
    /// So for the length of this window the physical key really is F18: the recorder has
    /// nothing else to capture. The hyper key stops working for those seconds — F19 never
    /// arrives — which is exactly the point.
    static func beginRecordingWindow(seconds: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordingEnd?.cancel()
        recordingWindow.withLock { $0 = true }
        applyAsync()
        log.info("recording window open: caps lock is F18 for \(Int(seconds))s")

        let item = DispatchWorkItem { endRecordingWindow() }
        recordingEnd = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    static func endRecordingWindow() {
        dispatchPrecondition(condition: .onQueue(.main))
        // Tested and cleared in one critical section: the timer firing and the settings
        // window closing the recorder are two callers for the same close, and both
        // getting past a separate guard would post two redundant `apply()` runs.
        guard recordingWindow.withLock({ open -> Bool in
            guard open else { return false }
            open = false
            return true
        }) else { return }
        recordingEnd?.cancel()
        recordingEnd = nil
        applyAsync()
        log.info("recording window closed: caps lock is F19 again")
    }

    /// Records what was already mapped, so we neither clobber it now nor delete it on exit.
    private static func captureBaseline() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !baselineCaptured else { return }
        baselineCaptured = true
        foreignMappings = currentMappings().filter { $0.src != capsLockUsage }
        publishedBaseline.withLock { $0 = foreignMappings }
        if !foreignMappings.isEmpty {
            log.info("preserving \(foreignMappings.count) pre-existing key mapping(s)")
        }
    }

    /// Reapply when a keyboard is plugged in or the machine wakes. Debounced, because
    /// a single device attachment fires several matching notifications.
    static func scheduleReapply(delay: TimeInterval = 0.5) {
        // The element cache belongs to the main thread; the mapping work belongs to
        // `queue`. A device coming or going invalidates both.
        DispatchQueue.main.async { physicalTriggerElements = nil }
        queue.async {
            guard !isShuttingDown else { return }
            reapplyWorkItem?.cancel()
            let item = DispatchWorkItem { _ = apply() }
            reapplyWorkItem = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    // MARK: - Physical key state

    /// `true`/`false` when at least one keyboard exposes a readable Caps Lock or F19
    /// element; `nil` when raw HID state is unavailable and the caller must use its
    /// bounded safety fallback instead of pretending the key is up.
    static var isPhysicalTriggerDown: Bool? {
        dispatchPrecondition(condition: .onQueue(.main))
        var elements = physicalTriggerElements
        if elements == nil {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastElementDiscovery >= elementDiscoveryInterval else { return nil }
            lastElementDiscovery = now
            let discovered = discoverPhysicalTriggerElements()
            if discovered.isEmpty {
                log.error("no readable caps lock / F19 HID element; retrying in \(elementDiscoveryInterval)s")
            } else {
                physicalTriggerElements = discovered
            }
            elements = discovered
        }

        var readAny = false
        for (device, element) in elements ?? [] {
            guard let value = integerValue(device: device, element: element) else { continue }
            readAny = true
            if value != 0 { return true }
        }
        return readAny ? false : nil
    }

    private static func discoverPhysicalTriggerElements() -> [(IOHIDDevice, IOHIDElement)] {
        let manager: IOHIDManager
        if let existing = physicalStateManager {
            manager = existing
        } else {
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [
                kIOHIDDeviceUsagePageKey as String: 1,  // Generic Desktop
                kIOHIDDeviceUsageKey as String: 6,      // Keyboard
            ] as CFDictionary)
            guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
            else {
                log.error("cannot open raw HID keyboard state")
                return []
            }
            physicalStateManager = manager
        }

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        return devices.flatMap { device in
            let elements = IOHIDDeviceCopyMatchingElements(
                device,
                [kIOHIDElementUsagePageKey as String: 7] as CFDictionary, // Keyboard/Keypad
                IOOptionBits(kIOHIDOptionsTypeNone)
            ) as? [IOHIDElement] ?? []
            return elements.compactMap { element in
                // 0x39 is the physical Caps Lock usage before hidutil remaps it. 0x6e
                // covers a genuine F19 key should a keyboard actually have one.
                let usage = IOHIDElementGetUsage(element)
                return usage == 0x39 || usage == 0x6e ? (device, element) : nil
            }
        }
    }

    private static func integerValue(device: IOHIDDevice, element: IOHIDElement) -> CFIndex? {
        let pointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard IOHIDDeviceGetValue(device, element, pointer) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(pointer.pointee.takeUnretainedValue())
    }

    // MARK: - Device attachment

    static func startWatchingDevices() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let callback: IOServiceMatchingCallback = { _, iterator in
            var sawDevice = false
            var obj = IOIteratorNext(iterator)
            while obj != 0 {
                sawDevice = true
                IOObjectRelease(obj)
                obj = IOIteratorNext(iterator)
            }
            if sawDevice { HIDRemapper.scheduleReapply() }
        }

        // Detachment matters as much as attachment: unplugging the keyboard whose
        // elements are cached leaves `physicalTriggerElements` pointing at a device that
        // answers nothing, and the hold watchdog reads that as "state unavailable" for
        // every hold thereafter. `scheduleReapply` clears the cache as well as re-writing
        // the mapping, so both notifications route through it.
        armNotification(port, kIOFirstMatchNotification, callback, &matchIterator)
        armNotification(port, kIOTerminatedNotification, callback, &terminateIterator)
        log.info("watching for HID device attachment and removal")
    }

    private static func armNotification(
        _ port: IONotificationPortRef,
        _ type: String,
        _ callback: @escaping IOServiceMatchingCallback,
        _ iterator: inout io_iterator_t
    ) {
        let result = IOServiceAddMatchingNotification(
            port, type, IOServiceMatching("IOHIDDevice"), callback, nil, &iterator
        )
        guard result == KERN_SUCCESS else {
            log.error("IOServiceAddMatchingNotification(\(type, privacy: .public)) failed: \(result)")
            return
        }
        // The iterator must be drained once to arm the notification.
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
    }

    // MARK: - hidutil

    private static func write(_ mappings: [Mapping]) -> Bool {
        let json = "{\"UserKeyMapping\":[\(mappings.map(\.json).joined(separator: ","))]}"
        return runHIDUtil(["property", "--set", json]) != nil
    }

    private static func currentMappings() -> [Mapping] {
        guard let output = runHIDUtil(["property", "--get", "UserKeyMapping"]) else { return [] }
        // hidutil prints a CoreFoundation description: one brace-delimited dictionary
        // per mapping, values either decimal or hex depending on the OS build.
        return output.components(separatedBy: "}").compactMap { chunk in
            guard let src = field("HIDKeyboardModifierMappingSrc", in: chunk),
                  let dst = field("HIDKeyboardModifierMappingDst", in: chunk)
            else { return nil }
            return Mapping(src: src, dst: dst)
        }
    }

    private static func field(_ name: String, in text: String) -> UInt64? {
        guard let range = text.range(of: "\(name)\\s*=\\s*(0[xX][0-9a-fA-F]+|[0-9]+)",
                                     options: .regularExpression)
        else { return nil }
        let raw = text[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
        if raw.lowercased().hasPrefix("0x") { return UInt64(raw.dropFirst(2), radix: 16) }
        return UInt64(raw)
    }

    private static func runHIDUtil(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("cannot run hidutil: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
