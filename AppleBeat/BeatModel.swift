import AppKit
import Combine
import Foundation

/// Ties the audio tap, the beat detector and the logo light together, and holds the settings.
final class BeatModel: ObservableObject {
    @Published var enabled: Bool { didSet { save(enabled, "enabled"); applyEnabled() } }
    @Published var sensitivity: Double { didSet { save(sensitivity, "sensitivity"); pushSettings() } }
    @Published var brightness: Double { didSet { save(brightness, "brightness"); pushSettings() } }
    @Published var fade: Double { didSet { save(fade, "fade"); pushSettings() } }

    /// True for a moment after each beat; drives the menu bar icon.
    @Published private(set) var beatLit = false
    @Published private(set) var level = 0.0
    @Published private(set) var problem: String?
    @Published private(set) var logoSwitchedOff = false

    let hasLogo: Bool

    private let logo = LogoLight()
    private let tap = SystemAudioTap()
    private var idleTimer: Timer?
    private var lastBeat = Date.distantPast
    private var logoIsOurs = false
    private var displayAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []

    // Touched only on the audio queue.
    private var detector = BeatDetector()
    private var hopsSinceLevel = 0

    // Read on the audio queue, written on the main queue.
    private let lock = NSLock()
    private var settings = (sensitivity: 0.6, brightness: 1.0, fade: 0.35, active: false)

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["enabled": true, "sensitivity": 0.6, "brightness": 1.0, "fade": 0.35])
        enabled = defaults.bool(forKey: "enabled")
        sensitivity = defaults.double(forKey: "sensitivity")
        brightness = defaults.double(forKey: "brightness")
        fade = defaults.double(forKey: "fade")
        hasLogo = logo != nil

        // A previous run that didn't quit cleanly may have left the logo dark.
        logo?.restore(fade: 0.3)
        logoSwitchedOff = !(logo?.isSwitchedOn ?? true)

        tap.onSamples = { [weak self] samples, rate in
            self?.analyse(samples, rate)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displayAsleep = true
            self?.pushSettings()
            self?.releaseLogo()
        })
        observers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.displayAsleep = false
            self?.pushSettings()
        })

        // Give the logo back on Ctrl-C or `kill` too.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }

        pushSettings()
        applyEnabled()
    }

    func shutdown() {
        tap.stop()
        logo?.restore(fade: 0.3, wait: true)
    }

    func switchLogoOn() {
        logo?.switchOn()
        logoSwitchedOff = false
    }

    // MARK: - Private

    private func applyEnabled() {
        pushSettings()
        if enabled {
            do {
                try tap.start()
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            if idleTimer == nil {
                idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    self?.checkIdle()
                }
            }
        } else {
            tap.stop()
            idleTimer?.invalidate()
            idleTimer = nil
            level = 0
            releaseLogo()
        }
    }

    private func pushSettings() {
        lock.lock()
        settings = (sensitivity, brightness, fade, enabled && !displayAsleep)
        lock.unlock()
    }

    /// Audio queue.
    private func analyse(_ samples: UnsafeBufferPointer<Float>, _ rate: Double) {
        lock.lock()
        let current = settings
        lock.unlock()
        guard current.active else { return }

        detector.sensitivity = current.sensitivity
        detector.process(samples, sampleRate: rate) { beat in
            // Straight to the logo from here; the main queue only gets the picture of it.
            logo?.pulse(
                peak: current.brightness * (0.55 + 0.45 * beat.strength),
                attack: 0.045,
                decay: current.fade)
            DispatchQueue.main.async { self.showBeat() }
        }

        hopsSinceLevel += 1
        if hopsSinceLevel >= 4 {
            hopsSinceLevel = 0
            let level = detector.level
            DispatchQueue.main.async { self.level = level }
        }
    }

    private func showBeat() {
        guard enabled else { return }
        lastBeat = Date()
        logoIsOurs = true
        // Redrawing the menu bar icon also gives the display a new frame, which the daemon
        // waits for before it lights the logo from fully dark.
        beatLit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            self?.beatLit = false
        }
    }

    /// When the music stops, the logo goes back to its normal glow.
    private func checkIdle() {
        if logoIsOurs, Date().timeIntervalSince(lastBeat) > 2 {
            releaseLogo()
        }
    }

    private func releaseLogo() {
        logoIsOurs = false
        logo?.restore(fade: 0.8)
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
