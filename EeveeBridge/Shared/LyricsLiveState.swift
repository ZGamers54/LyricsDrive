import Foundation

/// Kept identical in the host bridge and widget extension through the shared source.
struct LyricsLiveState: Codable, Hashable {
    var trackID: String
    var title: String
    var artist: String
    var currentLine: String
    var nextLine: String
    let progress: Double
    let isPlaying: Bool
    let anchorDate: Date
    let positionAtAnchor: Double
    let duration: Double
    var playbackRate: Double? = nil

    var effectiveRate: Double { isPlaying ? max(0, playbackRate ?? 1) : 0 }

    func position(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(anchorDate)) * effectiveRate
        let value = max(0, positionAtAnchor + elapsed)
        return duration > 0 ? min(duration, value) : value
    }

    /// A seek inside the same lyric must publish a new clock anchor too.
    func needsPublication(comparedTo previous: Self?, at date: Date) -> Bool {
        guard let previous else { return true }
        if trackID != previous.trackID || title != previous.title || artist != previous.artist
            || currentLine != previous.currentLine || nextLine != previous.nextLine
            || isPlaying != previous.isPlaying || effectiveRate != previous.effectiveRate || duration != previous.duration {
            return true
        }
        return abs(position(at: date) - previous.position(at: date)) > 0.35
    }

    /// ActivityKit limits static + dynamic data to 4 KB. Leave room for its envelope.
    func bounded(attributesBytes: Int) -> Self {
        var result = self
        result.trackID = String(trackID.prefix(256))
        result.title = String(title.prefix(180))
        result.artist = String(artist.prefix(120))
        result.currentLine = String(currentLine.prefix(700))
        result.nextLine = String(nextLine.prefix(500))
        let encoder = JSONEncoder()
        while let encoded = try? encoder.encode(result), encoded.count + attributesBytes > 3_500 {
            if result.nextLine.count > 40 {
                result.nextLine = String(result.nextLine.prefix(result.nextLine.count / 2))
            } else if result.currentLine.count > 80 {
                result.currentLine = String(result.currentLine.prefix(result.currentLine.count / 2))
            } else if result.title.count > 30 {
                result.title = String(result.title.prefix(result.title.count / 2))
            } else if result.artist.count > 30 {
                result.artist = String(result.artist.prefix(result.artist.count / 2))
            } else if result.trackID.count > 64 {
                result.trackID = String(result.trackID.prefix(64))
            } else { break }
        }
        return result
    }
}
