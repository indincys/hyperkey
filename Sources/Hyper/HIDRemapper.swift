import Foundation
import IOKit
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

    private static let queue = DispatchQueue(label: "\(Hyper.subsystem).hid")
    private static var notifyPort: IONotificationPortRef?
    private static var matchIterator: io_iterator_t = 0
    private static var reapplyWorkItem: DispatchWorkItem?

    /// Mappings that existed before we touched anything. Captured once, restored on exit.
    private static var foreignMappings: [Mapping] = []
    private static var baselineCaptured = false

    private struct Mapping {
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
        captureBaseline()
        let entries = foreignMappings + [Mapping(src: capsLockUsage, dst: triggerUsage)]
        guard write(entries) else {
            log.error("hidutil --set failed")
            return false
        }
        let ok = isApplied()
        log.info("caps lock -> F19 mapping applied: \(ok, privacy: .public)")
        return ok
    }

    static func applyAsync() {
        queue.async { _ = apply() }
    }

    /// Puts `UserKeyMapping` back the way we found it — our entry gone, everyone
    /// else's entries intact.
    static func restore() {
        _ = write(foreignMappings)
        log.info("caps lock mapping removed, \(foreignMappings.count) foreign mapping(s) restored")
    }

    static func isApplied() -> Bool {
        currentMappings().contains { $0.src == capsLockUsage && $0.dst == triggerUsage }
    }

    /// Records what was already mapped, so we neither clobber it now nor delete it on exit.
    private static func captureBaseline() {
        guard !baselineCaptured else { return }
        baselineCaptured = true
        foreignMappings = currentMappings().filter { $0.src != capsLockUsage }
        if !foreignMappings.isEmpty {
            log.info("preserving \(foreignMappings.count) pre-existing key mapping(s)")
        }
    }

    /// Reapply when a keyboard is plugged in or the machine wakes. Debounced, because
    /// a single device attachment fires several matching notifications.
    static func scheduleReapply(delay: TimeInterval = 0.5) {
        DispatchQueue.main.async {
            reapplyWorkItem?.cancel()
            let item = DispatchWorkItem { applyAsync() }
            reapplyWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
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

        let matching = IOServiceMatching("IOHIDDevice")
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matching, callback, nil, &matchIterator
        )
        guard result == KERN_SUCCESS else {
            log.error("IOServiceAddMatchingNotification failed: \(result)")
            return
        }
        // The iterator must be drained once to arm the notification.
        var obj = IOIteratorNext(matchIterator)
        while obj != 0 {
            IOObjectRelease(obj)
            obj = IOIteratorNext(matchIterator)
        }
        log.info("watching for HID device attachment")
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
