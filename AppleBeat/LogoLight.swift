import Foundation
import ObjectiveC

/// Drives the illuminated lid logo of a MacBook Pro with PROLED XDR Display.
///
/// There is no public API. `corebrightnessd` owns the LED and accepts a few keys from any
/// process through the private `BrightnessSystemClient` class. The logo has no "brightness"
/// key: it follows a display logical state (Blank = fade to dark, Unblank = fade to lit) with
/// a settable fade duration. A beat is a short fade up that is turned round into a longer
/// fade down.
///
/// Everything is resolved at runtime and `init?` fails cleanly if any piece is missing, so a
/// macOS update that changes these internals disables the light instead of crashing.
final class LogoLight {
    private enum State: Int { case blank = 1, unblank = 2 }

    private typealias SetFn = @convention(c) (AnyObject, Selector, AnyObject, NSString) -> Bool
    private typealias CopyFn = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias SetKeyboardFn = @convention(c) (AnyObject, Selector, AnyObject, NSString, UInt64) -> Bool

    private static let stateKey = "DisplayLogicalState" as NSString
    private static let fadeKey = "LEPWMFactorFadeDuration" as NSString
    private static let modeKey = "LEBacklightMode" as NSString
    private static let liveKey = "LEPWMState" as NSString

    /// A fade this long never visibly moves; used to change state without changing the light.
    private static let frozen = 1e9
    /// The daemon starts moving about one of its frames after a state write.
    private static let startLatency = 0.018
    /// The fade is a critically damped spring: p(s) = 1 - (1 + k·s)·exp(-k·s), s = t / duration.
    private static let springK = 6.51

    private let client: NSObject
    private let setSel = NSSelectorFromString("setProperty:forKey:")
    private let copySel = NSSelectorFromString("copyPropertyForKey:")
    private let setKeyboardSel = NSSelectorFromString("setProperty:withKey:keyboardID:")
    private let setFn: SetFn
    private let copyFn: CopyFn
    private let setKeyboardFn: SetKeyboardFn?
    private let keyboardIDs: [UInt64]

    private let queue = DispatchQueue(label: "applebeat.logo", qos: .userInteractive)
    private var state: State?
    private var pendingFall: DispatchWorkItem?

    init?() {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("BrightnessSystemClient") as? NSObject.Type,
              cls.instancesRespond(to: setSel), cls.instancesRespond(to: copySel) else { return nil }
        let client = cls.init()
        self.client = client
        setFn = unsafeBitCast(client.method(for: setSel), to: SetFn.self)
        copyFn = unsafeBitCast(client.method(for: copySel), to: CopyFn.self)

        // The keyboard backlight follows the same logical state. To keep it lit while the logo
        // fades, each keyboard is told on its own that the display is still on.
        var ids: [UInt64] = []
        if cls.instancesRespond(to: setKeyboardSel),
           let kbCls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
            let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
            if kbCls.instancesRespond(to: sel),
               let list = kbCls.init().perform(sel)?.takeRetainedValue() as? [NSNumber] {
                ids = list.map(\.uint64Value)
            }
        }
        keyboardIDs = ids
        setKeyboardFn = ids.isEmpty
            ? nil : unsafeBitCast(client.method(for: setKeyboardSel), to: SetKeyboardFn.self)

        // No live state means this Mac has no logo light.
        guard copy(Self.liveKey) is NSDictionary else { return nil }
    }

    /// False when the logo has been switched off in macOS (`LEBacklightMode` 0).
    var isSwitchedOn: Bool {
        (copy(Self.modeKey) as? NSNumber)?.intValue != 0
    }

    /// Turns the logo on in macOS. This is the system's own setting and it persists.
    func switchOn() {
        queue.async { self.set(2 as NSNumber, Self.modeKey) }
    }

    /// One beat: rise to `peak` (0...1) in about `attack` seconds, then fade out over `decay`.
    func pulse(peak: Double, attack: Double, decay: Double) {
        queue.async {
            self.pendingFall?.cancel()
            let from = self.factor() ?? 0
            let peak = min(max(peak, 0.05), 1)
            var wait = 0.0

            if peak > from + 0.02 {
                // A fade always runs to fully lit, so pick the duration that passes `peak`
                // after `attack`, and turn it round there.
                let share = min((peak - from) / max(1 - from, 0.001), 0.995)
                let duration = attack / Self.springTime(forProgress: share)
                if self.state != .blank {
                    // Writing the state it is already in is ignored; flip without moving first.
                    self.write(.blank, duration: Self.frozen)
                }
                self.write(.unblank, duration: duration)
                wait = attack + Self.startLatency
            }

            self.scheduleFall(after: wait, decay: decay, risingFrom: wait > 0 ? from : nil, retries: 40)
        }
    }

    private func scheduleFall(after wait: Double, decay: Double, risingFrom: Double?, retries: Int) {
        let fall = DispatchWorkItem {
            // A rise from fully dark waits in the daemon for the display's next frame (up to
            // half a second on a still screen). Turning round before it starts would lose the
            // beat, so wait for the logo to move first.
            if let from = risingFrom, from < 0.01, retries > 0, (self.factor() ?? 1) < 0.01 {
                self.scheduleFall(after: 0.01, decay: decay, risingFrom: from, retries: retries - 1)
                return
            }
            self.write(.blank, duration: decay)
        }
        pendingFall = fall
        queue.asyncAfter(deadline: .now() + wait, execute: fall)
    }

    /// Hands the logo back to macOS: fully lit, automatic fades.
    func restore(fade: Double = 0.6, wait: Bool = false) {
        let work = {
            self.pendingFall?.cancel()
            self.pendingFall = nil
            // The daemon changes the state itself at sleep and wake, so don't trust ours:
            // one of these two writes is a change, and neither moves the light.
            self.write(.blank, duration: Self.frozen)
            self.write(.unblank, duration: fade)
            self.set(0 as NSNumber, Self.fadeKey)
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: - Private

    private func write(_ new: State, duration: Double) {
        set(duration as NSNumber, Self.fadeKey)
        set(new.rawValue as NSNumber, Self.stateKey)
        state = new
        if new == .blank, let setKeyboardFn {
            for id in keyboardIDs {
                _ = setKeyboardFn(client, setKeyboardSel, State.unblank.rawValue as NSNumber, Self.stateKey, id)
            }
        }
    }

    /// The fade position, 0 (dark) to 1 (lit).
    private func factor() -> Double? {
        ((copy(Self.liveKey) as? NSDictionary)?["Factor"] as? NSNumber)?.doubleValue
    }

    @discardableResult
    private func set(_ value: AnyObject, _ key: NSString) -> Bool {
        setFn(client, setSel, value, key)
    }

    private func copy(_ key: NSString) -> AnyObject? {
        copyFn(client, copySel, key)?.takeRetainedValue()
    }

    /// The share of a fade's duration after which it has covered `progress` of its way.
    private static func springTime(forProgress progress: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            let p = 1 - (1 + springK * mid) * exp(-springK * mid)
            if p < progress { low = mid } else { high = mid }
        }
        return max((low + high) / 2, 0.05)
    }
}
