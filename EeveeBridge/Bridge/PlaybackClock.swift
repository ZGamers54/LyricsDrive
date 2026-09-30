import Foundation

/// Now Playing elapsed time is an anchor, not necessarily a continuously advancing sample.
/// All mutable clock state is owned by the bridge's serial state queue.
struct PlaybackClock {
    private var anchorPosition: TimeInterval = 0
    private var anchorUptime: TimeInterval = 0
    private(set) var isPlaying = false
    private var lastRaw: TimeInterval?
    private(set) var diagnostic = "En attente"

    mutating func reset(elapsed: TimeInterval?, isPlaying: Bool, now: TimeInterval) {
        lastRaw = valid(elapsed)
        anchorPosition = lastRaw ?? 0
        anchorUptime = now
        self.isPlaying = isPlaying
        diagnostic = "Ancrage nouveau morceau"
    }

    func position(at now: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let value = max(0, anchorPosition + (isPlaying ? max(0, now - anchorUptime) : 0))
        return duration.isFinite && duration > 0 ? min(duration, value) : value
    }

    /// Returns true only when an actual new anchor or transport transition was received.
    @discardableResult
    mutating func consume(elapsed: TimeInterval?, isPlaying: Bool, now: TimeInterval,
                          duration: TimeInterval) -> Bool {
        let raw = valid(elapsed)
        let rawChanged = raw.map { value in lastRaw.map { abs(value - $0) > 0.001 } ?? true } ?? false
        let transportChanged = self.isPlaying != isPlaying
        let estimated = position(at: now, duration: duration)
        guard rawChanged || transportChanged else {
            diagnostic = raw == nil ? "Position absente · horloge locale" : "Ancre inchangée · progression locale conservée"
            return false
        }
        // Re-reading an identical value, even hundreds of times, is not evidence of a backward seek.
        anchorPosition = rawChanged ? raw! : estimated
        if let raw, rawChanged { lastRaw = raw }
        anchorUptime = now
        self.isPlaying = isPlaying
        diagnostic = rawChanged ? "Nouvelle position reçue · recalage unique" : "Lecture / pause · position locale conservée"
        return true
    }

    private func valid(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
