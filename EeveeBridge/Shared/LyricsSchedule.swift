import Foundation

/// The host and extension use the same binary search and offset convention.
/// Positive offset shows lyrics earlier; a negative offset delays them.
enum LyricsSchedule {
    static func upperBound<Line>(in lines: [Line], at position: TimeInterval,
                                 time: (Line) -> TimeInterval) -> Int {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = low + (high - low) / 2
            if time(lines[mid]) <= position { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func currentIndex<Line>(in lines: [Line], position: TimeInterval, offset: TimeInterval,
                                   time: (Line) -> TimeInterval) -> Int? {
        let next = upperBound(in: lines, at: position + offset, time: time)
        return next == 0 ? nil : next - 1
    }

    /// Compute the next real boundary from the anchor, never from a tick counter.
    static func nextDelay<Line>(in lines: [Line], position: TimeInterval, rate: Double,
                                offset: TimeInterval, duration: TimeInterval,
                                time: (Line) -> TimeInterval) -> TimeInterval? {
        guard position.isFinite, rate.isFinite, rate > 0.001, offset.isFinite else { return nil }
        let next = upperBound(in: lines, at: position + offset, time: time)
        guard next < lines.count else { return nil }
        let boundary = time(lines[next]) - offset
        guard duration <= 0 || boundary <= duration else { return nil }
        let delay = (boundary - position) / rate
        return delay.isFinite && delay > 0 ? delay : nil
    }
}
