import Foundation

/// Finds beats in a stream of mono audio.
///
/// The audio is cut into ~12 ms hops. For each hop the loudness of the bass (below ~150 Hz,
/// where kick drums live) and of the whole signal is taken in decibel-like units, so the
/// volume setting doesn't matter. A beat is a sudden rise in those that stands out from the
/// last second and a half of the music.
struct BeatDetector {
    struct Beat {
        /// 0 (only just a beat) to 1 (a hard hit).
        let strength: Double
    }

    /// 0 (only the hardest hits) to 1 (every little accent).
    var sensitivity = 0.6

    /// Loudness of the last hop, 0...1, for the meter.
    private(set) var level = 0.0

    private var sampleRate = 0.0
    private var hop = 512
    private var filled = 0
    private var bassSum = 0.0
    private var fullSum = 0.0

    // Low-pass biquad.
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var z1 = 0.0, z2 = 0.0

    private var bassEnvelope = [Double](repeating: -6, count: 3)
    private var fullEnvelope = [Double](repeating: -6, count: 3)
    private var history = [Double](repeating: 0, count: 128)
    private var historyIndex = 0
    private var previous = 0.0
    private var beforePrevious = 0.0
    private var previousThreshold = 0.0
    private var hopsSinceBeat = 1_000

    private static let silence = 1e-3  // about -60 dBFS
    private static let minimumGap = 0.19  // seconds between beats

    mutating func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, onBeat: (Beat) -> Void) {
        if sampleRate != self.sampleRate { configure(sampleRate) }

        for sample in samples {
            let x = Double(sample)
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            bassSum += y * y
            fullSum += x * x
            filled += 1
            if filled == hop {
                if let beat = finishHop() { onBeat(beat) }
                filled = 0
                bassSum = 0
                fullSum = 0
            }
        }
    }

    private mutating func finishHop() -> Beat? {
        let bass = (bassSum / Double(hop)).squareRoot()
        let full = (fullSum / Double(hop)).squareRoot()
        level = min(1, max(0, 1 + log10(max(full, 1e-6)) / 3))

        // Onset strength: how much louder this hop is than two hops ago, in log units.
        let bassLog = log10(max(bass, 1e-6))
        let fullLog = log10(max(full, 1e-6))
        var onset = 0.0
        if full > Self.silence {
            onset = max(0, bassLog - bassEnvelope[0]) + 0.5 * max(0, fullLog - fullEnvelope[0])
        }
        bassEnvelope.removeFirst()
        bassEnvelope.append(bassLog)
        fullEnvelope.removeFirst()
        fullEnvelope.append(fullLog)

        let mean = history.reduce(0, +) / Double(history.count)
        history[historyIndex] = onset
        historyIndex = (historyIndex + 1) % history.count

        // A beat is a local peak of the onset strength above an adaptive threshold. The peak
        // is known one hop late, which costs about 12 ms.
        let threshold = mean * 1.6 + (0.5 - 0.42 * sensitivity)
        hopsSinceBeat += 1
        var beat: Beat?
        let gap = Double(hopsSinceBeat * hop) / sampleRate
        if previous > previousThreshold, previous >= onset, previous > beforePrevious, gap >= Self.minimumGap {
            beat = Beat(strength: min(1, (previous - previousThreshold) / 0.7))
            hopsSinceBeat = 0
        }
        beforePrevious = previous
        previous = onset
        previousThreshold = threshold
        return beat
    }

    private mutating func configure(_ rate: Double) {
        sampleRate = rate
        hop = max(64, Int((rate * 0.0116).rounded()))
        filled = 0
        bassSum = 0
        fullSum = 0
        z1 = 0
        z2 = 0

        // RBJ low-pass, 150 Hz, Q 0.707.
        let w = 2 * Double.pi * 150 / rate
        let alpha = sin(w) / (2 * 0.707)
        let a0 = 1 + alpha
        b0 = (1 - cos(w)) / 2 / a0
        b1 = (1 - cos(w)) / a0
        b2 = b0
        a1 = -2 * cos(w) / a0
        a2 = (1 - alpha) / a0
    }
}
