import Foundation

@main
struct LyricsLiveStateTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
    static func state(position: Double, at date: Date, playing: Bool = true, track: String = "spotify:track:one",
                      current: String = "First", next: String = "Next") -> LyricsLiveState {
        LyricsLiveState(trackID: track, title: "Title", artist: "Artist", currentLine: current,
            nextLine: next, progress: position / 180, isPlaying: playing, anchorDate: date,
            positionAtAnchor: position, duration: 180)
    }
    static func main() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = state(position: 10, at: start)
        let later = start.addingTimeInterval(90)
        check(!state(position: 100, at: later).needsPublication(comparedTo: first, at: later),
              "Unchanged lyric/clock shouldn't flood ActivityKit")
        check(state(position: 103, at: later).needsPublication(comparedTo: first, at: later),
              "Seek within the same lyric must update the anchor")
        check(state(position: 97, at: later).needsPublication(comparedTo: first, at: later),
              "Backward seek within the same lyric must update the anchor")
        check(state(position: 100, at: later, playing: false).needsPublication(comparedTo: first, at: later),
              "Pause wasn't published")
        check(state(position: 100, at: later, current: "New line").needsPublication(comparedTo: first, at: later),
              "A new lyric wasn't published")
        check(state(position: 100, at: later, track: "spotify:track:two").needsPublication(comparedTo: first, at: later),
              "A background track change must update the same activity")
        var faster = state(position: 100, at: later)
        faster.playbackRate = 1.5
        check(faster.needsPublication(comparedTo: first, at: later), "Rate change wasn't published")
        check(abs(faster.position(at: later.addingTimeInterval(10)) - 115) < 0.0001, "1.5x progress is wrong")
        var sameRate = state(position: 115, at: later.addingTimeInterval(10))
        sameRate.playbackRate = 1.5
        check(!sameRate.needsPublication(comparedTo: faster, at: later.addingTimeInterval(10)),
              "1.5x playback shouldn't flood updates")
        let legacyData = try JSONEncoder().encode(first)
        let legacy = try JSONDecoder().decode(LyricsLiveState.self, from: legacyData)
        check(legacy.effectiveRate == 1, "Legacy state must default to 1x")
        print("PASS: rate changes, 1.5x progression, legacy optional rate")
        print("PASS: 90 seconds of monotone playback, same-line forward/backward seek, pause, next track")

        let paused = state(position: 30, at: start, playing: false)
        check(paused.position(at: later) == 30, "Paused progress must remain frozen")
        check(first.position(at: start.addingTimeInterval(500)) == 180, "End of track must be clamped")
        let enormous = String(repeating: "漢字\\\"\n🧑🏽‍🚀", count: 1_000)
        let oversized = LyricsLiveState(trackID: enormous, title: enormous, artist: enormous,
            currentLine: enormous, nextLine: enormous, progress: 0.1, isPlaying: true,
            anchorDate: start, positionAtAnchor: 10, duration: 180)
        let bounded = oversized.bounded(attributesBytes: 100)
        let encoded = try JSONEncoder().encode(bounded)
        check(encoded.count + 100 <= 3_500, "ActivityKit payload exceeded the budget")
        check(!bounded.currentLine.isEmpty && !bounded.nextLine.isEmpty, "Budgeting lost all lyric content")
        let decoded = try JSONDecoder().decode(LyricsLiveState.self, from: encoded)
        check(decoded == bounded, "Host/widget shared state didn't round-trip")
        print("PASS: pause/end progress, Unicode and JSON escapes, 4 KB combined state budget")
    }
}
