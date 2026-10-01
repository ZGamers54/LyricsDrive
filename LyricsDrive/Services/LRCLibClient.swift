import Foundation

actor LRCLibClient {
    enum LyricsError: LocalizedError {
        case invalidURL
        case notFound
        case noSyncedLyrics
        case badResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "URL LRCLIB invalide."
            case .notFound: return "Paroles introuvables sur LRCLIB."
            case .noSyncedLyrics: return "Ce titre n'a pas de paroles synchronisées."
            case .badResponse: return "Réponse LRCLIB invalide."
            }
        }
    }

    private struct Response: Decodable {
        let trackName: String
        let artistName: String
        let duration: Double?
        let syncedLyrics: String?
    }

    func fetch(title: String, artist: String, duration: TimeInterval?) async throws -> LyricsTrack {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if let duration {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = query
        guard let url = components.url else { throw LyricsError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue("LyricsDrive/0.3 (personal CarPlay lyrics prototype)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsError.badResponse }
        if http.statusCode == 404 { throw LyricsError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw LyricsError.badResponse }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let lrc = decoded.syncedLyrics, !lrc.isEmpty else { throw LyricsError.noSyncedLyrics }
        let lines = Self.parseLRC(lrc)
        guard !lines.isEmpty else { throw LyricsError.noSyncedLyrics }
        return LyricsTrack(
            title: decoded.trackName,
            artist: decoded.artistName,
            duration: decoded.duration ?? duration ?? 0,
            lines: lines
        )
    }

    private static func parseLRC(_ raw: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { sub in
            let line = String(sub)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 5,
                  let minRange = Range(match.range(at: 1), in: line),
                  let secRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 4), in: line),
                  let minutes = Double(line[minRange]),
                  let seconds = Double(line[secRange]) else { return nil }

            var fraction = 0.0
            if match.range(at: 3).location != NSNotFound,
               let fracRange = Range(match.range(at: 3), in: line) {
                let digits = String(line[fracRange])
                if let value = Double(digits) {
                    fraction = value / pow(10.0, Double(digits.count))
                }
            }

            let text = String(line[textRange]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return LyricLine(time: minutes * 60 + seconds + fraction, text: text)
        }.sorted { $0.time < $1.time }
    }
}
