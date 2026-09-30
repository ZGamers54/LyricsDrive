import Foundation

@main
struct LyricsScheduleTests {
    static func close(_ actual: Double?, _ expected: Double) {
        guard let actual else { fatalError("Missing boundary") }
        precondition(abs(actual - expected) < 0.0001, "Expected \(expected), received \(actual)")
    }
    static func main() {
        let lines: [Double] = [0, 5, 10, 10, 15, 30]
        func index(_ p: Double, _ offset: Double = 0) -> Int? {
            LyricsSchedule.currentIndex(in: lines, position: p, offset: offset, time: { $0 })
        }
        func delay(_ p: Double, _ rate: Double = 1, _ offset: Double = 0, _ duration: Double = 30) -> Double? {
            LyricsSchedule.nextDelay(in: lines, position: p, rate: rate, offset: offset,
                                     duration: duration, time: { $0 })
        }
        precondition(index(-0.1) == nil && index(0) == 0 && index(5) == 1)
        precondition(index(10) == 3 && index(100) == 5) // Duplicate stamps choose the last cue.
        close(delay(0), 5)
        close(delay(4.7, 1, 0.2), 0.1)
        close(delay(5, 1.5), 5 / 1.5)
        close(delay(10), 5)
        close(delay(12, 0.5), 6)
        precondition(delay(15, 0) == nil && delay(30) == nil && delay(15, 1, 0, 25) == nil)
        precondition(delay(15, .nan) == nil)
        close(delay(15, 1, 0, 0), 15) // Unknown duration.
        precondition(index(0, -1) == nil) // A negative offset must delay even the first cue at zero.
        close(delay(0, 1, -1), 1)
        precondition(index(1, -1) == 0)
        close(delay(4, 1, 1), 5) // Positive offset already selected the cue at 5.
        let empty: [Double] = []
        precondition(LyricsSchedule.currentIndex(in: empty, position: 0, offset: 0, time: { $0 }) == nil)
        precondition(LyricsSchedule.nextDelay(in: empty, position: 0, rate: 1, offset: 0, duration: 0, time: { $0 }) == nil)
        // Simulate a delayed delivery, pause/seek and re-plan directly from the monotone clock.
        var clock = PlaybackClock()
        clock.reset(elapsed: 0, rate: 1, now: 0)
        close(delay(clock.position(at: 0, duration: 30)), 5)
        precondition(index(clock.position(at: 16, duration: 30)) == 4)
        close(delay(clock.position(at: 16, duration: 30)), 14)
        clock.consume(elapsed: 7, rate: 1, now: 17, duration: 30)
        close(delay(clock.position(at: 17, duration: 30)), 3)
        clock.consume(elapsed: 7, rate: 0, now: 18, duration: 30)
        precondition(delay(clock.position(at: 20, duration: 30), clock.rate) == nil)
        clock.consume(elapsed: 7, rate: 2, now: 20, duration: 30)
        close(delay(clock.position(at: 20, duration: 30), clock.rate), 1)
        precondition(index(clock.position(at: 21, duration: 30)) == 3)
        print("PASS: exact boundaries, duplicate stamps, offsets, speeds, pause, seek and delayed delivery")
    }
}
