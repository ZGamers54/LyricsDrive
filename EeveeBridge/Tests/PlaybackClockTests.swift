import Foundation

@main
struct PlaybackClockTests {
    static func close(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.0001, "Expected \(expected), received \(actual)")
    }
    static func main() {
        var clock = PlaybackClock()
        // Regression: real report had 7.53 frozen for 64.7 seconds and repeatedly rewound.
        clock.reset(elapsed: 7.53, isPlaying: true, now: 0)
        for tick in 1...129 {
            precondition(!clock.consume(elapsed: 7.53, isPlaying: true, now: Double(tick) / 2, duration: 320))
        }
        close(clock.position(at: 64.7, duration: 320), 72.23)
        precondition(clock.position(at: 64.7, duration: 320) > 12.46)
        // A changed raw value is a genuine new anchor, including forward/backward seeks and zero.
        precondition(clock.consume(elapsed: 25, isPlaying: true, now: 65, duration: 320))
        close(clock.position(at: 66, duration: 320), 26)
        precondition(!clock.consume(elapsed: 25, isPlaying: true, now: 67, duration: 320))
        close(clock.position(at: 68, duration: 320), 28)
        precondition(clock.consume(elapsed: 100, isPlaying: true, now: 68, duration: 320))
        close(clock.position(at: 69, duration: 320), 101)
        precondition(clock.consume(elapsed: 0, isPlaying: true, now: 70, duration: 320))
        close(clock.position(at: 71, duration: 320), 1)
        // Pause/resume with an unchanged raw anchor must not rewind.
        precondition(clock.consume(elapsed: 0, isPlaying: false, now: 75, duration: 320))
        close(clock.position(at: 100, duration: 320), 5)
        precondition(clock.consume(elapsed: 0, isPlaying: true, now: 100, duration: 320))
        close(clock.position(at: 110, duration: 320), 15)
        // Missing / invalid samples do not reset an established anchor.
        precondition(!clock.consume(elapsed: nil, isPlaying: true, now: 111, duration: 320))
        precondition(!clock.consume(elapsed: .nan, isPlaying: true, now: 112, duration: 320))
        close(clock.position(at: 120, duration: 0), 25)
        close(clock.position(at: 1000, duration: 320), 320)
        // New track clears the old raw anchor, including tracks with the same starting position.
        clock.reset(elapsed: 0, isPlaying: false, now: 1000)
        close(clock.position(at: 1050, duration: 180), 0)
        precondition(clock.consume(elapsed: 42, isPlaying: false, now: 1050, duration: 180))
        close(clock.position(at: 1100, duration: 180), 42)
        // Missing rate after locking is not an implicit pause; explicit zero still pauses.
        clock.reset(elapsed: 0.04, rate: 1, now: 2000)
        for second in 1...75 {
            precondition(!clock.consume(elapsed: 0.04, rate: nil, now: 2000 + Double(second), duration: 240))
        }
        close(clock.position(at: 2075.2, duration: 240), 75.24)
        precondition(clock.isPlaying)
        precondition(clock.consume(elapsed: nil, rate: 0, now: 2076, duration: 240))
        close(clock.position(at: 2100, duration: 240), 76.04)
        precondition(!clock.consume(elapsed: nil, rate: nil, now: 2101, duration: 240))
        close(clock.position(at: 2102, duration: 240), 76.04)
        // Rate changes preserve position, and frozen anchors extrapolate at the actual rate.
        precondition(clock.consume(elapsed: nil, rate: 1.5, now: 2102, duration: 240))
        close(clock.position(at: 2112, duration: 240), 91.04)
        precondition(!clock.consume(elapsed: .infinity, rate: .nan, now: 2112, duration: 240))
        close(clock.position(at: 2122, duration: 240), 106.04)
        precondition(clock.consume(elapsed: 80, rate: 0.5, now: 2122, duration: 240))
        close(clock.position(at: 2132, duration: 240), 85)
        close(clock.lastAnchorCorrection!, -26.04)
        // A long gap catches up from the anchor rather than incrementing once on wake.
        close(clock.position(at: 2300, duration: 240), 169)
        clock.reset(elapsed: 0, rate: nil, now: 2300)
        close(clock.position(at: 2310, duration: 180), 5)
        print("PASS: missing rate while locked, explicit pause, 0.5x/1.5x, invalid rate, gap, corrections")
        print("PASS: frozen 7.53s regression, seeks, zero, pause/resume, missing samples, duration, new track")
    }
}
