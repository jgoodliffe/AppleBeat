import Foundation

/// Finds the kick drum in a stream of mono audio.
///
/// The audio goes through a steep 35–180 Hz band-pass, which keeps the kick's thump and punch and
/// drops most of the snare, the hats and the vocals. A kick is then a sudden rise in that band which is also about
/// as loud as the other recent kicks: that second test is what tells it from bass notes, which
/// rise just as suddenly but usually sit below the kick.
///
/// Music with no kick still gets a beat: after a few seconds without one, sudden rises in the
/// whole signal count instead, until a kick comes back.
struct BeatDetector {
    struct Beat {
        /// 0 (only just a beat) to 1 (a hard hit).
        let strength: Double
    }

    /// 0 (only the hardest kicks) to 1 (softer low hits count too).
    var sensitivity = 0.6

    /// Loudness of the last hop, 0...1, for the meter.
    private(set) var level = 0.0

    private var sampleRate = 0.0
    private var hop = 256
    private var hopDuration = 0.0058
    private var filled = 0
    private var lowSum = 0.0
    private var fullSum = 0.0

    private var highPass = Biquad()
    private var lowPassA = Biquad()
    private var lowPassB = Biquad()

    private var low = OnsetTracker()
    private var full = OnsetTracker()
    private var averageFull = 0.0
    private var kickLoudness = 0.0
    private var secondsSinceBeat = 10.0
    private var secondsSinceKick = 10.0

    private static let minimumGap = 0.19  // seconds between beats
    private static let fallbackAfter = 3.0  // seconds without a kick

    mutating func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, onBeat: (Beat) -> Void) {
        if sampleRate != self.sampleRate { configure(sampleRate) }

        for sample in samples {
            let x = Double(sample)
            let y = lowPassB.run(lowPassA.run(highPass.run(x)))
            lowSum += y * y
            fullSum += x * x
            filled += 1
            if filled == hop {
                if let beat = finishHop() { onBeat(beat) }
                filled = 0
                lowSum = 0
                fullSum = 0
            }
        }
    }

    private mutating func finishHop() -> Beat? {
        let fullRMS = (fullSum / Double(hop)).squareRoot()
        level = min(1, max(0, 1 + log10(max(fullRMS, 1e-6)) / 3))
        averageFull += (fullRMS - averageFull) * min(1, hopDuration / 1.5)
        secondsSinceBeat += hopDuration
        secondsSinceKick += hopDuration
        // Forget how loud the kicks were slowly, so a quieter passage is followed.
        kickLoudness *= exp(-hopDuration * log(2) / 8)

        // Anything 30 dB under the music itself is noise, not a kick.
        let lowFloor = max(1e-5, 0.03 * averageFull)
        let lowOnset = low.push(lowSum, floor: lowFloor * lowFloor * Double(hop),
                                margin: 0.3 - 0.2 * sensitivity)
        let fullOnset = full.push(fullSum, floor: 1e-6 * Double(hop),
                                  margin: 0.5 - 0.4 * sensitivity)

        if let onset = lowOnset, secondsSinceBeat >= Self.minimumGap {
            let loudness = (onset.energy / Double(hop * OnsetTracker.window)).squareRoot()
            if loudness >= (0.95 - 0.4 * sensitivity) * kickLoudness {
                // The reference is the loudest recent hit, so softer low notes that get through
                // don't drag it down to their own level.
                kickLoudness = max(kickLoudness, loudness)
                secondsSinceBeat = 0
                secondsSinceKick = 0
                return Beat(strength: min(1, 0.4 + onset.excess / 0.6))
            }
        }

        if let onset = fullOnset, secondsSinceKick > Self.fallbackAfter, secondsSinceBeat >= 0.25 {
            secondsSinceBeat = 0
            return Beat(strength: min(0.8, onset.excess / 0.7))
        }
        return nil
    }

    private mutating func configure(_ rate: Double) {
        sampleRate = rate
        hop = max(32, Int((rate * 0.0058).rounded()))
        hopDuration = Double(hop) / rate
        filled = 0
        lowSum = 0
        fullSum = 0
        highPass = .highPass(35, q: 0.707, rate: rate)
        // Two sections make a 4th-order Butterworth low-pass.
        lowPassA = .lowPass(180, q: 0.541, rate: rate)
        lowPassB = .lowPass(180, q: 1.307, rate: rate)
        low = OnsetTracker()
        full = OnsetTracker()
    }
}

/// Watches one band's energy and reports each sudden rise in it, once, at its peak.
private struct OnsetTracker {
    struct Onset {
        /// How far the rise stood above the threshold, in log10 amplitude units.
        let excess: Double
        /// The band's energy over the window at the peak.
        let energy: Double
    }

    /// Hops per energy window (~23 ms: long enough to cover a period of the lowest bass).
    static let window = 4

    private var energies = [Double](repeating: 0, count: 2 * window)
    private var history = [Double](repeating: 0, count: 256)  // ~1.5 s
    private var historyIndex = 0
    private var previous = 0.0
    private var beforePrevious = 0.0
    private var previousThreshold = 0.0
    private var previousEnergy = 0.0

    mutating func push(_ hopEnergy: Double, floor: Double, margin: Double) -> Onset? {
        energies.removeFirst()
        energies.append(hopEnergy)
        let before = energies[0..<Self.window].reduce(0, +)
        let now = energies[Self.window...].reduce(0, +)
        // How much louder this window is than the one before it, in log10 amplitude units.
        let padding = floor * Double(Self.window)
        let rise = max(0, 0.5 * log10((now + padding) / (before + padding)))

        let mean = history.reduce(0, +) / Double(history.count)
        history[historyIndex] = rise
        historyIndex = (historyIndex + 1) % history.count
        let threshold = mean * 1.6 + margin

        // The peak of a rise is known one hop late, which costs about 6 ms.
        var onset: Onset?
        if previous > previousThreshold, previous >= rise, previous > beforePrevious {
            onset = Onset(excess: previous - previousThreshold, energy: max(now, previousEnergy))
        }
        beforePrevious = previous
        previous = rise
        previousThreshold = threshold
        previousEnergy = now
        return onset
    }
}

private struct Biquad {
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func lowPass(_ frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = (1 - cos(w)) / 2 / a0
        filter.b1 = (1 - cos(w)) / a0
        filter.b2 = filter.b0
        filter.a1 = -2 * cos(w) / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    static func highPass(_ frequency: Double, q: Double, rate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / rate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = (1 + cos(w)) / 2 / a0
        filter.b1 = -(1 + cos(w)) / a0
        filter.b2 = filter.b0
        filter.a1 = -2 * cos(w) / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }
}
