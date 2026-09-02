import Cocoa
import os

/// The event tap: turns F19 (the remapped Caps Lock) into a real Hyper modifier,
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
/// The dangerous failure mode is a stuck modifier: if the trigger key-up is ever missed,
/// four modifiers stay latched and the machine becomes unusable. Every exit path —
/// tap timeout, disable, sleep, quit — funnels through `releaseHyper`/`resetState`.
final class HyperTap {
    static let shared = HyperTap()

    private let log = Logger(subsystem: Hyper.subsystem, category: "tap")

    /// Tags events we post ourselves so the tap ignores them instead of recursing.
    /// Shared with the clipboard paster, which synthesizes ⌘V and ⌘C.
    private let magic: Int64 = Hyper.syntheticEventMarker
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

    /// Is the tap there *and* still enabled?
    ///
    /// This is deliberately the only state anything outside this file can ask about.
    /// The obvious weaker question — does a tap object exist — has a tempting name and
    /// the wrong answer: a tap disabled by the system is still an object, and every
    /// caller that branched on it concluded "running fine" about a tap delivering
    /// nothing. There is no second property to reach for by mistake.
    ///
    /// macOS disables a tap whose callback overran, and the disable notification can be
    /// missed (the callback is not invoked once the port is dead, and a disable that
    /// arrives while the app is busy is simply gone). A tap that exists but is disabled
    /// looks perfectly healthy to `isRunning` and delivers nothing at all — which is the
    /// "Hyper silently stopped working" report.
    var isHealthy: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Bounded backoff for rebuilding a tap that refuses to re-enable in place.
    private var tapRecoveryAttempts = 0
    private let tapRecoveryDelays: [TimeInterval] = [0.2, 0.5, 1.0]
    private var tapRebuildScheduled = false

    // Live state, only touched on the main run loop (where the tap callback fires).
    private var hyperDown = false
    /// Whether ⌘⌃⌥⇧ have actually been pressed for the current hold — see
    /// `armModifierInjection`. A short tap never gets this far.
    private var modifiersInjected = false
    private var usedDuringHold = false
    private var hyperDownAt: CFAbsoluteTime = 0
    private var swallowedKeys = Set<CGKeyCode>()
    /// Ordinary keys currently held, and when each went down. Kept so that a key which
    /// beat the hyper key to the wire can still be recognised — see `adoptRacingChord`.
    private var heldKeys: [CGKeyCode: CFAbsoluteTime] = [:]
    private var holdWatchdog: DispatchWorkItem?
    private var injectWorkItem: DispatchWorkItem?
    private var afterRelease: [() -> Void] = []

    var config = Config()

    /// What the user is physically holding, as flags — the base every synthesized
    /// sequence is built on top of.
    ///
    /// Copied from each real event's own flags rather than inferred by flipping the
    /// previous state. Flipping looks safe (a modifier only emits `flagsChanged` on a
    /// real transition) but it has no way back from one missed event, and events *are*
    /// missed: the tap gets disabled and re-enabled under load, `resetState` clears this
    /// while keys are still physically down, secure input swallows whole sequences. A
    /// single miss inverts that modifier permanently, and one stuck "down" here is
    /// silently unioned into everything we post from then on — the sequence goes out
    /// claiming a key is held that is not, and stays wrong until the user happens to
    /// press that modifier again.
    ///
    /// The flags on a real event are the system's own answer to the same question, so
    /// every event re-syncs us and nothing can accumulate. Storing flags rather than
    /// key codes matters too: left and right share one flag bit, so a key-code set has
    /// no honest answer for "right Shift released while left Shift is still down".
    private var realFlags: CGEventFlags = []

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        if tap != nil {
            if isHealthy { return true }
            // Re-enabling in place has already been tried by the time anything calls
            // start() again; a tap that is still disabled has to be thrown away.
            log.warning("existing event tap is disabled; rebuilding it")
            stop()
        }

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
        tapRecoveryAttempts = 0
        log.info("event tap started, enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        return true
    }

    /// Rebuilds the tap after a re-enable that did not take, with a bounded backoff.
    ///
    /// Rebuilding is deliberately not attempted from inside the tap callback: tearing
    /// down the mach port the callback is running on is a good way to crash, and the
    /// callback is on a deadline anyway. It is also bounded — a tap that cannot be
    /// re-enabled three times running is a permission or system problem, and hammering
    /// `tapCreate` forever would just burn CPU while the menu already says it is down.
    private func scheduleTapRebuild() {
        guard !tapRebuildScheduled else { return }
        guard tapRecoveryAttempts < tapRecoveryDelays.count else {
            log.error("""
                event tap could not be re-enabled after \(self.tapRecoveryDelays.count) \
                rebuild attempts; leaving it to the next permission or wake event
                """)
            return
        }
        let delay = tapRecoveryDelays[tapRecoveryAttempts]
        tapRecoveryAttempts += 1
        tapRebuildScheduled = true
        log.warning("event tap still disabled; rebuilding in \(delay)s (attempt \(self.tapRecoveryAttempts))")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.tapRebuildScheduled = false
            let attempt = self.tapRecoveryAttempts
            self.stop()
            _ = self.start()
            if self.isHealthy {
                // start() already zeroed the counter; say so where the log stream shows it.
                self.log.info("event tap rebuilt successfully on attempt \(attempt)")
            } else {
                self.tapRecoveryAttempts = attempt
                self.scheduleTapRebuild()
            }
        }
    }

    func stop() {
        // Synchronously: `stop()` is what `applicationWillTerminate` calls, and a peek
        // teardown left on the main queue there is never dequeued — the process exits
        // first, leaving the peeked application in front and the user's previous one
        // buried. Every other caller is on the main thread anyway.
        resetState(synchronously: true)
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        log.info("event tap stopped")
    }

    /// Drops any latched hyper modifiers. Safe to call at any time.
    ///
    /// `synchronously` controls only the peek teardown: normally it is hopped off the
    /// event-tap callback (see `dispatch`), but on the way out there is no later to hop
    /// to.
    func resetState(synchronously: Bool = false) {
        holdWatchdog?.cancel()
        holdWatchdog = nil
        injectWorkItem?.cancel()
        injectWorkItem = nil
        hyperDown = false
        if modifiersInjected {
            modifiersInjected = false
            // State is already suspect here, so clear outright rather than trying to
            // restore: a dropped modifier is recoverable, a stuck one is not.
            postFlags(releaseSteps(base: [], mask: hyperMask))
        }
        realFlags = []
        swallowedKeys.removeAll()
        heldKeys.removeAll()
        usedDuringHold = false
        // Off the callback like every other launcher call — see `dispatch`. Keeping all
        // three peek entry points on the same main-queue hop also preserves their order.
        if synchronously {
            AppLauncher.shared.endActivePeek()
        } else {
            DispatchQueue.main.async { AppLauncher.shared.endActivePeek() }
        }
        // Anything queued behind the hyper release still has to run: the modifiers are
        // gone either way, and dropping it would strand a paste the user asked for.
        drainAfterRelease()
    }

    // MARK: - Event handling

    /// Every field of a `flagsChanged` event that a downstream matcher could possibly be
    /// reading. Used to diff a real hardware chord against the one we synthesize: rather
    /// than guessing which field some other application keys off, the goal is that there
    /// be no difference left to key off.
    private func dump(_ event: CGEvent, key: CGKeyCode, synthetic: Bool) -> String {
        let fields: [(String, CGEventField)] = [
            ("kbdType", .keyboardEventKeyboardType),
            ("autorep", .keyboardEventAutorepeat),
            ("srcPID", .eventSourceUnixProcessID),
            ("srcState", .eventSourceStateID),
            ("srcUser", .eventSourceUserData),
            ("srcUID", .eventSourceUserID),
            ("srcGID", .eventSourceGroupID),
        ]
        let rest = fields
            .map { "\($0.0)=\(event.getIntegerValueField($0.1))" }
            .joined(separator: " ")
        return "flagsChanged keycode=\(key) flags=\(String(event.flags.rawValue, radix: 16)) "
            + "\(rest) synthetic=\(synthetic)"
    }

    // MARK: - Routing

    /// What the tap does with one event, before any state is touched.
    enum Route: Equatable {
        /// Hand it downstream unchanged.
        case passThrough
        /// Eat it and do nothing else.
        case swallowTrigger
        /// The hyper key itself, going down (`true`) or up (`false`).
        case trigger(down: Bool)
        /// An ordinary key during an active hold — the stateful path below.
        case process
    }

    /// The routing rule, pulled out of `handle` so it can be tested without a live tap.
    ///
    /// The order of the three questions is the point:
    ///
    ///   * **Synthetic first.** Our own posted events must never be reprocessed, whatever
    ///     else is true — that is how a modifier sequence would feed itself.
    ///   * **Trigger before `enabled`.** Pausing Hyper used to let the trigger key through
    ///     untouched, which is not "off": Caps Lock is still remapped at the HID layer
    ///     while paused (the mapping is only removed on quit), so every press went
    ///     downstream as a bare F19. Anything with an F19 shortcut — a recorder, an input
    ///     method — fired on it, and the user, who had just paused Hyper precisely to stop
    ///     Hyper interfering, got a different interference instead. Paused means the key
    ///     does nothing: swallowed, no modifiers injected, no tap action.
    ///   * **Everything else passes through while paused**, exactly as before.
    static func routeDecision(
        type: CGEventType, key: CGKeyCode, enabled: Bool, isSynthetic: Bool
    ) -> Route {
        if isSynthetic { return .passThrough }

        if key == Keys.hyperTrigger, type == .keyDown || type == .keyUp {
            return enabled ? .trigger(down: type == .keyDown) : .swallowTrigger
        }

        return enabled ? .process : .passThrough
    }

    /// Whether swallowing a paused trigger event must first unwind a hold that is
    /// already in progress.
    ///
    /// Pausing is a menu click, and it lands wherever the user's hands happen to be —
    /// including mid-hold, with ⌘⌃⌥⇧ latched. `AppDelegate` resets the tap state when the
    /// toggle flips, but the key is still physically down, and its key-up then arrives at
    /// a paused tap. Swallowing that key-up without unwinding leaves `hyperDown` true with
    /// no event left that can clear it: only the watchdog's unknown-state fallback
    /// eventually does, up to ten seconds later, and every keystroke in between is read as
    /// part of a chord. So the release runs first and the event is still eaten.
    ///
    /// `allowTapAction` is false on that path — the user asked for Hyper to stop doing
    /// things, and firing a tap action on the way out is exactly a thing.
    static func pausedTriggerNeedsRelease(type: CGEventType, hyperDown: Bool) -> Bool {
        type == .keyUp && hyperDown
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback took too long, or on certain user
        // input. Not re-enabling here is the single most common reason tools like this
        // "randomly stop working".
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.warning("tap disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabling")
            resetState()
            // Re-enabling can itself fail — the port may already be gone. Read the state
            // back rather than trusting the call, because the difference between the two
            // is a keyboard that silently stops responding to Hyper.
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    tapRecoveryAttempts = 0
                    log.info("tap re-enabled in place")
                } else {
                    scheduleTapRebuild()
                }
            } else {
                scheduleTapRebuild()
            }
            return nil
        }

        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let synthetic = event.getIntegerValueField(.eventSourceUserData) == magic

        // Traced at info level on purpose, even though this is the debug switch: os_log's
        // debug level is memory-only, so it is already gone by the time anyone reads the
        // log for a bug that just happened. Our own synthesized events are traced too —
        // "what actually went out on the wire" is exactly the question this answers.
        if config.debug {
            if type == .flagsChanged {
                log.info("\(self.dump(event, key: key, synthetic: synthetic), privacy: .public)")
            } else {
                log.info("""
                    saw \(String(describing: type), privacy: .public) keycode=\(key) \
                    flags=\(String(event.flags.rawValue, radix: 16), privacy: .public) \
                    synthetic=\(synthetic) hyperDown=\(self.hyperDown)
                    """)
            }
        }

        switch Self.routeDecision(
            type: type, key: key, enabled: config.enabled, isSynthetic: synthetic
        ) {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallowTrigger:
            if Self.pausedTriggerNeedsRelease(type: type, hyperDown: hyperDown) {
                log.info("paused mid-hold; unwinding the hold before swallowing the key-up")
                releaseHyper(allowTapAction: false)
            }
            log.info("paused: swallowed the hyper trigger \(type == .keyDown ? "down" : "up", privacy: .public)")
            return nil
        case .trigger(let down):
            if down { pressHyper() } else { releaseHyper(allowTapAction: true) }
            return nil
        case .process:
            break
        }

        switch type {
        case .flagsChanged:
            if let mask = Keys.modifierFlags[key] {
                if modifiersInjected {
                    // Our own four are in these flags as well, so the event cannot say
                    // what the user is really holding; toggle this one bit and wait.
                    // Wrong at worst for the rest of a hold — the first real modifier
                    // event after it re-syncs from the flags below.
                    realFlags.formSymmetricDifference(mask)
                } else {
                    realFlags = event.flags.intersection(hyperMask)
                }
            }
            if modifiersInjected {
                event.flags = event.flags.union(hyperMask)
            }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            // Ask the hardware, not the queue: the hyper key may be physically down
            // already even though its own event has not reached us yet. See
            // `adoptPendingHold` — this is the single most important line in the file
            // for how Caps Lock chords actually behave.
            if type == .keyDown, !hyperDown, triggerIsPhysicallyDown {
                adoptPendingHold(triggeredBy: key)
            }

            if type == .keyDown {
                heldKeys[key] = CFAbsoluteTimeGetCurrent()
            } else {
                heldKeys[key] = nil
            }

            if hyperDown {
                usedDuringHold = true
                if let target = config.bindings[key] {
                    if type == .keyDown {
                        if !swallowedKeys.contains(key) {
                            swallowedKeys.insert(key)
                            log.info("hyper+\(Keys.name(for: key), privacy: .public) -> \(target.description, privacy: .public)")
                            dispatch(target, key: key)
                        }
                        return nil
                    }
                    // A hold-to-peek chord ends when either half of the chord is
                    // released. Do this even for a racing chord whose key-down reached
                    // the application before the delayed Caps Lock event did; that
                    // path deliberately has no entry in `swallowedKeys`.
                    DispatchQueue.main.async { AppLauncher.shared.endPeek(for: key) }
                    // Only swallow a release whose press we swallowed. A key that went
                    // down before the hyper key did was already delivered, and eating
                    // its release would leave that application holding a key forever.
                    guard swallowedKeys.remove(key) != nil else {
                        return Unmanaged.passUnretained(event)
                    }
                    return nil
                }
                // A key joined the hold, so this is definitely not a tap: the
                // modifiers have to be down before the key reaches the application.
                if type == .keyDown { injectModifiers() }
                event.flags = event.flags.union(hyperMask)
                return Unmanaged.passUnretained(event)
            }

            // Hyper was released between this key's down and up; swallow the orphan
            // key-up so the application never sees an unpaired release.
            if swallowedKeys.contains(key) {
                if type == .keyUp { swallowedKeys.remove(key) }
                return nil
            }

            noticeCopyKeystroke(type: type, key: key, flags: event.flags)
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Binding dispatch

    private func dispatch(_ target: LaunchTarget, key: CGKeyCode) {
        switch target {
        case .action(let action):
            ClipboardManager.shared.perform(action)
        case .bundleID, .path:
            // Hopped off the tap callback deliberately. `beginPeek` ends any peek that is
            // already running, and that path makes accessibility calls into another
            // process (`AXHidden`, the Hide menu item) plus a `NSWorkspace` lookup. A
            // callback that overruns gets the whole tap switched off by the system, which
            // is the failure this is here to avoid; the queue keeps the order.
            let repeatPress = config.repeatPress
            DispatchQueue.main.async {
                if repeatPress == .peek {
                    AppLauncher.shared.beginPeek(target, key: key)
                } else {
                    AppLauncher.shared.activate(target, repeatPress: repeatPress)
                }
            }
        }
    }

    /// Runs `body` once the hyper key is no longer held.
    ///
    /// Anything that synthesizes a keystroke has to wait: at the moment a hyper
    /// binding fires, ⌘⌃⌥⇧ are latched, so a ⌘V posted right then arrives as ⌘⌃⌥⇧V
    /// and pastes nothing. The delay after the release lets the four `flagsChanged`
    /// events land in the target application first.
    func runAfterHyperRelease(_ body: @escaping () -> Void) {
        guard hyperDown else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: body)
            return
        }
        afterRelease.append(body)
    }

    private func drainAfterRelease() {
        guard !afterRelease.isEmpty else { return }
        let pending = afterRelease
        afterRelease.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            for body in pending { body() }
        }
    }

    /// The clipboard monitor's fast path. Seeing ⌘C or ⌘X here means the pasteboard is
    /// about to change, which is a far better signal than a poll — and it is only
    /// available because this process already taps every key on the machine.
    private func noticeCopyKeystroke(type: CGEventType, key: CGKeyCode, flags: CGEventFlags) {
        guard type == .keyDown, flags.contains(.maskCommand),
              key == Keys.cKey || key == Keys.xKey else { return }
        // Snapshot in the event callback, before the command reaches the application.
        // Looking up the frontmost process after the pasteboard changes is too late: a
        // fast app switch could then make an ignored app's copy look like another app.
        // Read the cache maintained by `didActivateApplicationNotification` rather than
        // asking NSWorkspace here: this runs on every ⌘C, inside the tap callback. The
        // fallback covers the one window where the cache has nothing — between launch and
        // the first application switch — which would otherwise file every copy the user
        // makes in their already-open editor as coming from an unknown application.
        let source = (AppLauncher.shared.cachedFrontmostApplication
            ?? NSWorkspace.shared.frontmostApplication)
            .map(ClipboardCaptureSource.init(application:)) ?? .unknown
        ClipboardManager.shared.copyKeystrokeObserved(source: source)
    }

    // MARK: - Hyper modifier synthesis

    private func pressHyper() {
        guard !hyperDown else { return }  // key repeat
        hyperDown = true
        usedDuringHold = false
        hyperDownAt = CFAbsoluteTimeGetCurrent()
        log.info("hyper down")
        pruneReleasedKeys()
        adoptRacingChord()
        armHoldWatchdog()
        armModifierInjection()
    }

    /// Whether the hyper key is held *right now*, according to the HID layer rather
    /// than according to which events have reached us.
    private var triggerIsPhysicallyDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: Keys.hyperTrigger)
    }

    /// Starts the hold early, on the first key that arrives while the hyper key is
    /// already physically down.
    ///
    /// **macOS delivers the Caps Lock key-down late — measured here at 100–150ms.** The
    /// remap to F19 takes the key out of the caps-lock *state* machinery, but the press
    /// still goes through the same debounce, so the event surfaces long after the finger
    /// landed. Anything that watches the keyboard ahead of this tap sees the press
    /// immediately; we are the ones running blind, for an eighth of a second.
    ///
    /// Everything odd about chords came from taking that delay at face value:
    ///
    ///   * A letter pressed inside the blind window arrives *before* the hyper key-down,
    ///     so it looked like an ordinary keystroke — passed through, typed, no launch.
    ///   * If the letter was also released in that window, the hold looked untouched from
    ///     start to finish, so the press was judged a bare tap and `tapAction` fired —
    ///     switching applications and opening the voice input at the same time.
    ///
    /// Polling the hardware settles it without heuristics or timing windows: if the key
    /// is down, it is down, whatever the queue has got round to telling us.
    private func adoptPendingHold(triggeredBy key: CGKeyCode) {
        log.info("""
            hyper key is physically down but its event has not arrived — \
            adopting \(Keys.name(for: key), privacy: .public) into the hold
            """)
        pressHyper()
    }

    /// Handles the chord where the other key beat the hyper key to the wire.
    ///
    /// Pressed as one gesture, the two key-downs can arrive in either order — measured
    /// here, the letter has landed a single millisecond first. At that moment the hyper
    /// key was not down yet, so the letter went downstream like any other keystroke and
    /// got typed. That part cannot be taken back.
    ///
    /// What can still be salvaged is the intent. A key already being held means this was
    /// never a bare tap, so `tapAction` must not fire — otherwise a chord meant to switch
    /// applications ends up opening the voice input instead. And if that key is bound,
    /// running its binding is what the user was asking for.
    ///
    /// The window is deliberately tight. Only a key pressed within a couple of frames of
    /// the hyper key can plausibly be part of the same gesture; anything older is someone
    /// mid-sentence who then reached for Caps Lock, and launching an application at them
    /// would be worse than doing nothing.
    private func adoptRacingChord() {
        guard !heldKeys.isEmpty else { return }
        usedDuringHold = true

        let now = CFAbsoluteTimeGetCurrent()
        for (key, downAt) in heldKeys where now - downAt < chordGrace {
            guard let target = config.bindings[key] else { continue }
            log.info("""
                hyper+\(Keys.name(for: key), privacy: .public) -> \
                \(target.description, privacy: .public) \
                (key arrived \(Int((now - downAt) * 1000))ms before the hyper key)
                """)
            dispatch(target, key: key)
        }
    }

    private let chordGrace: CFAbsoluteTime = 0.03

    /// Drops keys that are latched here but not actually held, according to the HID layer.
    ///
    /// **A key-up can go missing outright.** Measured here: a bound key swallowed during a
    /// hold, and then neither its key-up nor the trigger's ever reached the tap — the same
    /// loss `armHoldWatchdog` exists to catch. What the lost event leaves behind is worse
    /// than the event itself, because nothing on the release path clears these two sets:
    ///
    ///   * `heldKeys` keeps a key nobody is holding, so `adoptRacingChord` calls every
    ///     later press a chord. `usedDuringHold` is then true at every release and
    ///     `tapAction` never fires again — a hyper key whose holds work perfectly and
    ///     whose taps silently do nothing, for the rest of the session.
    ///   * `swallowedKeys` keeps it too, and that set eats the *next* press of that key:
    ///     the user types an ordinary letter and it vanishes.
    ///
    /// Neither heals on its own, and neither is visible to the user as anything but "it
    /// stopped working". So the question gets asked the way everything else in this file
    /// asks it — of the hardware, not of the queue. Anything the HID layer says is up gets
    /// dropped, whatever our own records claim.
    ///
    /// The cost is a key released microseconds ago, whose key-up is genuinely still in
    /// flight: dropping it from `swallowedKeys` lets that orphan through to the
    /// application. That needs the trigger to be pressed inside those few milliseconds,
    /// and it costs one unpaired key-up — against a tap action that stays dead until the
    /// app is restarted.
    private func pruneReleasedKeys() {
        for (key, _) in heldKeys where !CGEventSource.keyState(.combinedSessionState, key: key) {
            log.warning("""
                key-up for \(Keys.name(for: key), privacy: .public) was never delivered; \
                dropping it rather than counting it as held
                """)
            heldKeys[key] = nil
            swallowedKeys.remove(key)
        }
    }

    /// Why the four modifiers are **not** pressed here, at the moment the key goes down.
    ///
    /// At this instant we cannot yet know whether this is a hold or a tap, and the two
    /// want opposite things. A hold needs ⌘⌃⌥⇧ latched. A tap wants the machine left
    /// completely alone — it is going to turn into `tapAction` and nothing else.
    ///
    /// Pressing them eagerly and taking them back 100ms later is not free: downstream,
    /// a modifier press is a real event with real meaning. 微信输入法's voice panel
    /// treats one as "the user started typing" and closes itself — so a tap meant to
    /// *close* the panel closed it via the modifiers and then reopened it via the F18
    /// that followed, which reads as the panel restarting on every tap.
    ///
    /// So the decision is deferred to the last moment it can be: the modifiers go down
    /// when another key joins the hold, or when the press outlives the tap threshold,
    /// whichever happens first. A tap that stays under the threshold emits nothing at
    /// all — no modifiers to unwind, and no chance of a stray press being read as input.
    private func armModifierInjection() {
        injectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.injectModifiers() }
        injectWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(config.tapThresholdMs), execute: item
        )
    }

    private func injectModifiers() {
        guard hyperDown, !modifiersInjected else { return }
        modifiersInjected = true
        injectWorkItem?.cancel()
        injectWorkItem = nil
        // Added one at a time, the way hardware would — see `modifierOrder`.
        postFlags(pressSteps(base: realFlags, mask: hyperMask))
    }

    /// The keys behind a mask, in `modifierOrder`. Filtering rather than reordering is
    /// what keeps that comment's guarantees intact for a subset: drop Command from the
    /// mask and Shift does not inherit the last slot, it simply moves up behind whatever
    /// is still there, and dropping Shift removes the lone-shift hazard outright.
    private func modifierKeys(in mask: CGEventFlags) -> [CGKeyCode] {
        modifierOrder.filter { !(Keys.modifierFlags[$0] ?? []).intersection(mask).isEmpty }
    }

    /// Each modifier going down in turn, its flag joining the ones already held.
    private func pressSteps(base: CGEventFlags, mask: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var flags = base
        return modifierKeys(in: mask).map { key in
            flags.formUnion(Keys.modifierFlags[key] ?? [])
            return (key, flags)
        }
    }

    /// The same list unwound. `base` is what the user is physically holding: it is
    /// re-unioned at every step so a real Shift they have down survives our release.
    private func releaseSteps(base: CGEventFlags, mask: CGEventFlags) -> [(CGKeyCode, CGEventFlags)] {
        var flags = base.union(mask)
        return modifierKeys(in: mask).reversed().map { key in
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
    /// blindly — it asks the raw keyboard HID elements whether the physical Caps Lock is
    /// genuinely still down and re-arms if so. `CGEventSource.keyState(F19)` is not a
    /// substitute: after hidutil remaps Caps Lock it falsely turns `false` during a real
    /// long hold, which used to cut Hyper off at exactly 400ms.
    ///
    /// The interval is what bounds the damage, and latched modifiers are not the whole of
    /// it: for as long as this believes the key is down, every ordinary keystroke is read
    /// as part of a hyper chord. Measured here across a 5s window, four real ⌘W presses
    /// were each swallowed and turned into an application switch. So it polls at
    /// `holdWatchdogInterval` rather than waiting one long timeout — a `keyState` read a
    /// few times a second, and only while the key is held, is not worth optimising away.
    private func armHoldWatchdog() {
        holdWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hyperDown else { return }
            let physicalState = HIDRemapper.isPhysicalTriggerDown
            let heldFor = CFAbsoluteTimeGetCurrent() - self.hyperDownAt
            let peekActive = AppLauncher.shared.isPeekActive
            if self.config.debug {
                let state = physicalState.map { $0 ? "down" : "up" } ?? "unavailable"
                self.log.info("hold watchdog rawHID=\(state, privacy: .public) heldMs=\(Int(heldFor * 1000)) peek=\(peekActive)")
            }
            if !HyperHoldWatchdogPolicy.shouldRelease(
                physicalKeyDown: physicalState, heldFor: heldFor, peekActive: peekActive
            ) {
                // A keyboard that does not expose readable elements should not lose the
                // feature altogether. Keep the hold alive for a bounded interval; the
                // normal key-up still ends it immediately, while the hard limit prevents
                // inaccessible HID state from leaving four modifiers stuck forever.
                self.armHoldWatchdog()
            } else {
                self.log.warning("hyper key-up was never delivered; releasing modifiers")
                // The stream dropped an event, so assume it dropped more than one:
                // whatever else is latched from this hold is suspect too.
                self.pruneReleasedKeys()
                self.releaseHyper(allowTapAction: false)
            }
        }
        holdWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + holdWatchdogInterval, execute: item)
    }

    private let holdWatchdogInterval: TimeInterval = 0.4

    private func releaseHyper(allowTapAction: Bool) {
        guard hyperDown else { return }
        hyperDown = false
        holdWatchdog?.cancel()
        holdWatchdog = nil
        injectWorkItem?.cancel()
        injectWorkItem = nil

        if modifiersInjected {
            modifiersInjected = false
            postFlags(releaseSteps(base: realFlags, mask: hyperMask))
        }

        // Releasing Hyper also releases the chord, even if the letter is still down.
        // Its eventual key-up remains swallowed by the normal orphan-release path.
        DispatchQueue.main.async { AppLauncher.shared.endActivePeek() }

        let heldMs = (CFAbsoluteTimeGetCurrent() - hyperDownAt) * 1000
        log.info("hyper up after \(Int(heldMs))ms, usedWithOtherKey=\(self.usedDuringHold)")
        if allowTapAction, !usedDuringHold, heldMs < Double(config.tapThresholdMs) {
            fireTapAction()
        }
        drainAfterRelease()
    }

    private func postFlags(_ steps: [(CGKeyCode, CGEventFlags)]) {
        guard let eventSource else { return }
        if config.debug {
            let trace = steps.map { "\($0.0):\(String($0.1.rawValue, radix: 16))" }.joined(separator: " ")
            log.info("posting flags \(trace, privacy: .public)")
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

    /// Long enough for the modifier releases posted just before to land first —
    /// otherwise the tap action arrives decorated with ⌘⌃⌥⇧.
    private let tapActionDelayMs = 20

    private func fireTapAction() {
        switch config.tapAction {
        case .none: return
        case .key(let code, let flags): fireKeyTap(code: code, flags: flags)
        case .modifiers(let mask): fireModifierTap(mask: mask)
        }
    }

    private func fireKeyTap(code: CGKeyCode, flags: CGEventFlags) {
        guard let eventSource else { return }

        let post = { [magic, nonCoalesced, log, debug = config.debug] (down: Bool) in
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down)
            else { return }
            event.flags = flags.union(nonCoalesced)
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cghidEventTap)
            if debug { log.info("tap action \(down ? "down" : "up", privacy: .public) keycode=\(code)") }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(tapActionDelayMs)) {
            post(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.config.tapActionHoldMs)) {
                post(false)
            }
        }
    }

    /// A tap made of nothing but modifiers — for recorders that refuse to store a key
    /// code (see `TapAction.modifiers`). They go down in `modifierOrder`, stay down for
    /// the same `tapActionHoldMs` any other tap gets, and unwind.
    ///
    /// The mask is deliberately allowed to overlap the hyper mask. Nothing collides,
    /// because this only runs on a path where no hyper modifier was ever injected: a
    /// press that outlives `tapThresholdMs`, or one with another key in it, is not a tap
    /// and never reaches here. So ⌃⌥⌘ posted from here is the only clean ⌃⌥⌘ the system
    /// ever sees from us — a hyper hold always carries Shift on top.
    private func fireModifierTap(mask: CGEventFlags) {
        guard eventSource != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(tapActionDelayMs)) { [weak self] in
            guard let self else { return }
            // Whatever the user already holds is left alone: pressing a modifier that is
            // physically down would post a second key-down for it, and the matching
            // key-up would then read as a release of a key still being held. The flags
            // the receiver ends up with are the same either way — `base` puts them there.
            let emit = mask.subtracting(self.realFlags)
            guard !emit.isEmpty else {
                self.log.info("tap action modifiers already held; nothing to send")
                return
            }
            if self.config.debug {
                self.log.info("tap action modifiers \(String(emit.rawValue, radix: 16), privacy: .public)")
            }
            self.postFlags(self.pressSteps(base: self.realFlags, mask: emit))
            // `emit` is captured, not recomputed: a modifier the user presses during
            // these 70ms must not remove a key from the release, or ours stays down.
            // `base` is still read live, so their new modifier shows up in the flags.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(self.config.tapActionHoldMs)) {
                self.postFlags(self.releaseSteps(base: self.realFlags, mask: emit))
            }
        }
    }
}
