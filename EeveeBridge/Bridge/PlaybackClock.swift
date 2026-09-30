import Foundation

/// Now Playing elapsed time is an anchor, not necessarily a continuously advancing sample.
/// All mutable state belongs to the bridge's serial state queue; time is monotone.
struct PlaybackClock {
    private var anchorPosition: TimeInterval = 0
    private var anchorUptime: TimeInterval = 0
    private(set) var rate: Double = 0
    var isPlaying: Bool { rate > 0.001 }
    private var lastRaw: TimeInterval?
    private(set) var lastAnchorCorrection: TimeInterval?
    private(set) var maxAnchorCorrection: TimeInterval = 0
    private(set) var diagnostic = "En attente"

    mutating func reset(elapsed: TimeInterval?, rate: Double?, now: TimeInterval) {
        lastRaw = validPosition(elapsed)
        anchorPosition = lastRaw ?? 0
        anchorUptime = now
        // Missing metadata does not mean pause. With no known rate yet, remain conservative.
        self.rate = validRate(rate) ?? self.rate
        lastAnchorCorrection = nil
        maxAnchorCorrection = 0
        diagnostic = rate == nil ? "Nouveau morceau · vitesse précédente conservée"
                                 : "Ancrage nouveau morceau"
    }

    func position(at now: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let value = max(0, anchorPosition + max(0, now - anchorUptime) * rate)
        return duration.isFinite && duration > 0 ? min(duration, value) : value
    }

    /// Returns true for a fresh position or a known rate change (including an explicit pause).
    @discardableResult
    mutating func consume(elapsed: TimeInterval?, rate sampleRate: Double?, now: TimeInterval,
                          duration: TimeInterval) -> Bool {
        let raw = validPosition(elapsed)
        let rawChanged = raw.map { value in lastRaw.map { abs(value - $0) > 0.001 } ?? true } ?? false
        let nextRate = validRate(sampleRate) ?? rate
        let rateChanged = abs(rate - nextRate) > 0.001
        let estimated = position(at: now, duration: duration)
        guard rawChanged || rateChanged else {
            diagnostic = validRate(sampleRate) == nil
                ? "Vitesse absente · dernière vitesse conservée"
                : (raw == nil ? "Position absente · horloge locale"
                              : "Ancre inchangée · progression locale conservée")
            return false
        }
        // A repeated raw anchor cannot distinguish playback from a seek back to that exact value.
        // Only a changed raw value reanchors; never count repeated ticks as evidence of a seek.
        if let raw, rawChanged {
            lastAnchorCorrection = raw - estimated
            maxAnchorCorrection = max(maxAnchorCorrection, abs(raw - estimated))
            lastRaw = raw
        }
        anchorPosition = rawChanged ? raw! : estimated
        anchorUptime = now
        rate = nextRate
        diagnostic = rawChanged ? "Nouvelle position reçue · recalage unique"
                                : "Vitesse / pause · position locale conservée"
        return true
    }

    // Compatibility for the original frozen-anchor regression tests.
    mutating func reset(elapsed: TimeInterval?, isPlaying: Bool, now: TimeInterval) {
        reset(elapsed: elapsed, rate: isPlaying ? 1 : 0, now: now)
    }
    @discardableResult
    mutating func consume(elapsed: TimeInterval?, isPlaying: Bool, now: TimeInterval,
                          duration: TimeInterval) -> Bool {
        consume(elapsed: elapsed, rate: isPlaying ? 1 : 0, now: now, duration: duration)
    }

    private func validPosition(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    private func validRate(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value <= 0.001 ? 0 : value
    }
}
