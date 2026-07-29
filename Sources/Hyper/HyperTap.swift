import Cocoa
import os

/// The event tap: turns F18 (the remapped Caps Lock) into a real Hyper modifier,
/// and intercepts bound Hyper+key combinations to launch applications.
///
/// Two behaviours have to coexist:
///
///   * Keys listed in the config are swallowed and turned into a launch. The
///     downstream application never sees them, so nothing else can react.
///   * Every other key passes through with ⌘⌃⌥⇧ merged into its flags, and the
///     modifiers are additionally posted as real `flagsChanged` events. That is what
///     makes Hyper+K work in other applications, not just in this one.
///
/// The dangerous failure mode is a stuck modifier: if the F18 key-up is ever missed,
/// four modifiers stay latched and the machine becomes unusable. Every exit path —
/// tap timeout, disable, sleep, quit — funnels through `releaseHyper`/`resetState`.
final class HyperTap {
    static let shared = HyperTap()

    private let log = Logger(subsystem: Hyper.subsystem, category: "tap")

    /// Tags events we post ourselves so the tap ignores them instead of recursing.
    private let magic: Int64 = 0x4859_5045  // 'HYPE'
    private let hyperMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    /// Real keyboard events always carry this bit; synthesized ones should too.
    private let nonCoalesced = CGEventFlags(rawValue: 0x100)

    /// The order the four modifiers are pressed in — and, reversed, released in.
    ///
    /// Not arbitrary. Two of them must never be seen on their own by anything downstream:
    ///
    ///   * **Shift** — a lone shift press-and-release is precisely what Chinese input
    ///     methods (微信输入法, 搜狗, 系统拼音 …) watch for to toggle 中/英. Holding hyper
    ///     without typing anything — a bare tap, or hyper+a key we swallow — would
    ///     otherwise emit exactly that pattern and flip the user's input method.
    ///     So Shift goes down *after* another modifier and comes up *before* one:
    ///     every shift event carries company in its flags, and other events always sit
    ///     between its down and its up.
    ///   * **Command** — a moment where Command is the only modifier down makes some
    ///     apps flash their menu-bar hints. It goes down last and comes up first.
    ///
    /// That leaves Option outermost, held alone for the instant at each end. Nothing on
    /// macOS reads a lone Option press, which is why it draws that straw.
    private let modifierOrder: [CGKeyCode] = [Keys.option, Keys.control, Keys.shift, Keys.command]

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private(set) var isRunning = false

    // Live state, only touched on the main run loop (where the tap callback fires).
    private var hyperDown = false
    private var usedDuringHold = false
    private var hyperDownAt: CFAbsoluteTime = 0
    private var pressedModifiers = Set<CGKeyCode>()
    private var swallowedKeys = Set<CGKeyCode>()
    private var holdWatchdog: DispatchWorkItem?

    var config = Config()

    /// Modifiers the user is physically holding, tracked by transition rather than by
    /// reading flags: once we start overlaying the hyper mask, the flags on incoming
    /// events no longer tell us what is really down.
    private var realFlags: CGEventFlags {
        pressedModifiers.reduce(into: CGEventFlags()) { $0.insert(Keys.modifierFlags[$1] ?? []) }
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HyperTap>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log.error("CGEvent.tapCreate failed — accessibility permission is probably missing")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isRunning = true
        log.info("event tap started")
        return true
    }

    func stop() {
        resetState()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        log.info("event tap stopped")
    }

    /// Drops any latched hyper modifiers. Safe to call at any time.
    func resetState() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
        if hyperDown {
            hyperDown = false
            // State is already suspect here, so clear outright rather than trying to
            // restore: a dropped modifier is recoverable, a stuck one is not.
            postFlags(releaseSteps(base: []))
        }
        pressedModifiers.removeAll()
        swallowedKeys.removeAll()
        usedDuringHold = false
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback took too long, or on certain user
        // input. Not re-enabling here is the single most common reason tools like this
        // "randomly stop working".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.warning("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling")
            resetState()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        // Never reprocess the modifier events we synthesize.
        if event.getIntegerValueField(.eventSourceUserData) == magic {
            return Unmanaged.passUnretained(event)
        }

        guard config.enabled else { return Unmanaged.passUnretained(event) }

        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if config.debug {
            log.debug("saw \(String(describing: type), privacy: .public) keycode=\(key) hyperDown=\(self.hyperDown)")
        }

        switch type {
        case .flagsChanged:
            if Keys.modifierFlags[key] != nil {
                // A modifier key only emits flagsChanged on an actual transition, so
                // its previous state tells us the direction unambiguously.
                if pressedModifiers.contains(key) {
                    pressedModifiers.remove(key)
                } else {
                    pressedModifiers.insert(key)
                }
            }
            if hyperDown {
                event.flags = event.flags.union(hyperMask)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            if key == Keys.f18 {
                if type == .keyDown {
                    pressHyper()
                } else {
                    releaseHyper(allowTapAction: true)
                }
                return nil
            }

            if hyperDown {
                usedDuringHold = true
                if let target = config.bindings[key] {
                    if type == .keyDown {
                        if !swallowedKeys.contains(key) {
                            swallowedKeys.insert(key)
                            log.info("hyper+\(Keys.name(for: key), privacy: .public) -> \(target.description, privacy: .public)")
                            AppLauncher.shared.activate(target, toggle: config.toggleHideIfFrontmost)
                        }
                    } else {
                        swallowedKeys.remove(key)
                    }
                    return nil
                }
                event.flags = event.flags.union(hyperMask)
                return Unmanaged.passUnretained(event)
            }

            // Hyper was released between this key's down and up; swallow the orphan
            // key-up so the application never sees an unpaired release.
            if swallowedKeys.contains(key) {
                if type == .keyUp { swallowedKeys.remove(key) }
                return nil
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Hyper modifier synthesis

    private func pressHyper() {
        guard !hyperDown else { return }  // key repeat
        hyperDown = true
        usedDuringHold = false
        hyperDownAt = CFAbsoluteTimeGetCurrent()
        log.info("hyper down")
        armHoldWatchdog()

        // Added one at a time, the way hardware would — see `modifierOrder`.
        postFlags(pressSteps(base: realFlags))
    }

    /// Each modifier going down in turn, its flag joining the ones already held.
    private func pressSteps(base: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var flags = base
        return modifierOrder.map { key in
            flags.formUnion(Keys.modifierFlags[key] ?? [])
            return (key, flags)
        }
    }

    /// The same list unwound. `base` is what the user is physically holding: it is
    /// re-unioned at every step so a real Shift they have down survives our release.
    private func releaseSteps(base: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var flags = base.union(hyperMask)
        return modifierOrder.reversed().map { key in
            flags.subtract(Keys.modifierFlags[key] ?? [])
            flags.formUnion(base)
            return (key, flags)
        }
    }

    /// Guards the one failure the tap cannot see: a key-up that never arrives, because
    /// secure input started while the key was held. Four latched modifiers make the
    /// machine unusable, so it has to be caught.
    ///
    /// This is one shot, cancelled by the normal key-up, and it does not release
    /// blindly — it asks the HID layer whether F18 is genuinely still down and re-arms
    /// if so, meaning a deliberate long hold is never cut short.
    private func armHoldWatchdog() {
        holdWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hyperDown else { return }
            if CGEventSource.keyState(.combinedSessionState, key: Keys.f18) {
                self.armHoldWatchdog()
            } else {
                self.log.warning("hyper key-up was never delivered; releasing modifiers")
                self.releaseHyper(allowTapAction: false)
            }
        }
        holdWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: item)
    }

    private func releaseHyper(allowTapAction: Bool) {
        guard hyperDown else { return }
        hyperDown = false
        holdWatchdog?.cancel()
        holdWatchdog = nil

        postFlags(releaseSteps(base: realFlags))

        let heldMs = (CFAbsoluteTimeGetCurrent() - hyperDownAt) * 1000
        log.info("hyper up after \(Int(heldMs))ms, usedWithOtherKey=\(self.usedDuringHold)")
        if allowTapAction, !usedDuringHold, heldMs < Double(config.tapThresholdMs) {
            fireTapAction()
        }
    }

    private func postFlags(_ steps: [(CGKeyCode, CGEventFlags)]) {
        guard let eventSource else { return }
        if config.debug {
            let trace = steps.map { "\($0.0):\(String($0.1.rawValue, radix: 16))" }.joined(separator: " ")
            log.debug("posting flags \(trace, privacy: .public)")
        }
        for (key, flags) in steps {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true)
            else { continue }
            event.type = .flagsChanged
            event.flags = flags.union(nonCoalesced)
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cghidEventTap)
        }
    }

    private func fireTapAction() {
        guard case .key(let code, let flags) = config.tapAction, let eventSource else { return }
        // Deferred by one turn of the run loop so the modifier release above lands
        // first — otherwise the tap action arrives decorated with ⌘⌃⌥⇧.
        DispatchQueue.main.async { [magic = self.magic, nonCoalesced = self.nonCoalesced] in
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
                else { continue }
                event.flags = flags.union(nonCoalesced)
                event.setIntegerValueField(.eventSourceUserData, value: magic)
                event.post(tap: .cghidEventTap)
            }
        }
    }
}
