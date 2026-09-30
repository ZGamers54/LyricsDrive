import Foundation

struct SharedLyricLine: Codable, Hashable {
    let time: TimeInterval
    let text: String
}

struct SharedLyricsPayload: Codable, Hashable {
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let progressAtAnchor: TimeInterval
    let anchorDate: Date
    let isPlaying: Bool
    let lines: [SharedLyricLine]
    let fallbackMessage: String?

    func projectedPosition(at date: Date) -> TimeInterval {
        let elapsed = isPlaying ? max(0, date.timeIntervalSince(anchorDate)) : 0
        return min(duration, max(0, progressAtAnchor + elapsed))
    }

    func lineIndex(at date: Date) -> Int? {
        lineIndex(atPosition: projectedPosition(at: date))
    }

    func lineIndex(atPosition position: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        var answer: Int?

        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}

enum LyricsDriveWidgetConstants {
    static let kind = "LyricsDriveCarPlay"
    static let appGroupID = "group.com.zgamers54.LyricsDrive"
    static let payloadKey = "lyricsdrive.widget.payload.v1"
}

enum SharedLyricsStore {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: LyricsDriveWidgetConstants.appGroupID) ?? .standard
    }

    static func save(_ payload: SharedLyricsPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: LyricsDriveWidgetConstants.payloadKey)
    }

    static func load() -> SharedLyricsPayload? {
        guard let data = defaults.data(forKey: LyricsDriveWidgetConstants.payloadKey) else { return nil }
        return try? JSONDecoder().decode(SharedLyricsPayload.self, from: data)
    }

    static func clear() {
        defaults.removeObject(forKey: LyricsDriveWidgetConstants.payloadKey)
    }
}
