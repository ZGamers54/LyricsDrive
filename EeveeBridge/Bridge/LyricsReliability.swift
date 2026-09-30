import Foundation
import CryptoKit

struct BridgeLyricLine: Codable, Hashable {
    let time: TimeInterval
    let text: String
}

struct LyricsLookup: Codable, Hashable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval

    /// Include album and duration: remixes/live versions must never share a cache entry.
    var cacheKey: String {
        let fields = [title, artist, album].map {
            $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let data = try! JSONEncoder().encode(fields + [String(duration.rounded())])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Called on the bridge's serial state queue. Errors never replace a successful cache entry.
final class LyricsCache {
    private struct Entry: Codable {
        let schema: Int
        let lookup: LyricsLookup
        let lines: [BridgeLyricLine]
    }
    private let directory: URL
    private let limit: Int
    private var memory: [String: [BridgeLyricLine]] = [:]

    init(directory: URL, limit: Int = 250) {
        self.directory = directory
        self.limit = max(1, limit)
        // Cached lyrics remain readable after the first unlock while Spotify plays locked.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: directory.path)
        #endif
        var resourceURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    func load(_ lookup: LyricsLookup) -> [BridgeLyricLine]? {
        let key = lookup.cacheKey
        if let lines = memory[key] { return lines }
        let path = directory.appendingPathComponent(key + ".json")
        guard let data = try? Data(contentsOf: path),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.schema == 1, entry.lookup.cacheKey == key, valid(entry.lines) else { return nil }
        if memory.count >= limit { memory.removeAll(keepingCapacity: true) }
        memory[key] = entry.lines
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
        return entry.lines
    }

    @discardableResult
    func save(_ lines: [BridgeLyricLine], for lookup: LyricsLookup) -> Bool {
        guard valid(lines) else { return false }
        if memory.count >= limit { memory.removeAll(keepingCapacity: true) }
        memory[lookup.cacheKey] = lines
        let entry = Entry(schema: 1, lookup: lookup, lines: lines)
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        let path = directory.appendingPathComponent(lookup.cacheKey + ".json")
        do {
            try data.write(to: path, options: .atomic)
            #if os(iOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: path.path)
            #endif
            trim()
            return true
        } catch { return false }
    }

    private func valid(_ lines: [BridgeLyricLine]) -> Bool {
        !lines.isEmpty && lines.count <= 5_000 && lines.allSatisfy {
            $0.time.isFinite && $0.time >= 0 && $0.text.utf8.count <= 16_384
        } && zip(lines, lines.dropFirst()).allSatisfy { $0.0.time <= $0.1.time }
    }

    private func trim() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let entries = files.filter { $0.pathExtension == "json" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }
        for path in entries.dropFirst(limit) { try? FileManager.default.removeItem(at: path) }
    }
}

enum LRCParser {
    static func parse(_ raw: String) -> [BridgeLyricLine] {
        guard let timestamps = try? NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#),
              let offsets = try? NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#) else { return [] }
        let whole = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        var offset = 0.0
        if let match = offsets.firstMatch(in: raw, range: whole),
           let range = Range(match.range(at: 1), in: raw),
           let millis = Double(raw[range]) { offset = millis / 1000 }
        var output: [BridgeLyricLine] = []
        for row in raw.split(whereSeparator: \.isNewline) {
            let line = String(row)
            let matches = timestamps.matches(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line))
            guard let last = matches.last, let textStart = Range(last.range, in: line)?.upperBound else { continue }
            let text = String(line[textStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                guard let minRange = Range(match.range(at: 1), in: line),
                      let secRange = Range(match.range(at: 2), in: line),
                      let minutes = Double(line[minRange]), let seconds = Double(line[secRange]),
                      seconds < 60 else { continue }
                var fraction = 0.0
                if let range = Range(match.range(at: 3), in: line),
                   let number = Double(line[range]) { fraction = number / pow(10, Double(line[range].count)) }
                // Empty timed lines mark instrumental gaps; don't keep the last sung phrase on screen.
                output.append(BridgeLyricLine(time: max(0, minutes * 60 + seconds + fraction + offset),
                                              text: text.isEmpty ? "♪" : text))
            }
        }
        return output.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }
}

struct LyricsRetryPolicy {
    static func delay(attempt: Int, retryAfter: String?, now: Date, jitter: Double) -> TimeInterval {
        let backoff = min(60.0, 2.0 * pow(2.0, Double(min(max(0, attempt), 5))))
        var serverDelay = 0.0
        if let retryAfter {
            if let seconds = Double(retryAfter), seconds.isFinite { serverDelay = max(0, seconds) }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: retryAfter) { serverDelay = max(0, date.timeIntervalSince(now)) }
            }
        }
        // Never retry before Retry-After; callers cancel this work when the track changes.
        return max(backoff, serverDelay) + min(1, max(0, jitter))
    }

    static func isTransient(http: Int?, error: Error?) -> Bool {
        if let error {
            return (error as? URLError)?.code != .cancelled
        }
        return [408, 425, 429, 500, 502, 503, 504].contains(http ?? -1)
    }
}

struct LRCLIBResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
}

enum LyricsFetchResult {
    case lyrics([BridgeLyricLine])
    case retry(TimeInterval)
    case unavailable(String)
}

/// Pure transport; scheduling and persistent cache belong to the bridge queue.
final class LyricsFetcher {
    private let session: URLSession
    private let jitter: () -> Double

    init(session: URLSession = .shared, jitter: @escaping () -> Double = { Double.random(in: 0...1) }) {
        self.session = session
        self.jitter = jitter
    }

    @discardableResult
    func fetch(_ lookup: LyricsLookup, attempt: Int,
               completion: @escaping (LyricsFetchResult, String) -> Void) -> URLSessionDataTask? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: lookup.title),
            URLQueryItem(name: "artist_name", value: lookup.artist)
        ]
        if !lookup.album.isEmpty { components.queryItems?.append(URLQueryItem(name: "album_name", value: lookup.album)) }
        if lookup.duration > 0 {
            components.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(lookup.duration.rounded()))))
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("LyricsDrive/0.10 (+https://github.com/ZGamers54/LyricsDrive)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { [jitter] data, response, error in
            let http = response as? HTTPURLResponse
            let code = http?.statusCode
            let diagnostic = error.map { "Réseau : " + $0.localizedDescription }
                ?? "HTTP \(code.map(String.init) ?? "absent") · \(data?.count ?? 0) octets"
            if LyricsRetryPolicy.isTransient(http: code, error: error) {
                let delay = LyricsRetryPolicy.delay(attempt: attempt,
                    retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), now: Date(), jitter: jitter())
                completion(.retry(delay), diagnostic)
                return
            }
            guard let code else { completion(.unavailable("Paroles temporairement indisponibles"), diagnostic); return }
            guard (200..<300).contains(code), let data,
                  let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data) else {
                // Technical HTTP codes remain in diagnostics, never in the lyrics card.
                completion(.unavailable(code == 404 ? "Paroles introuvables" : "Paroles temporairement indisponibles"), diagnostic)
                return
            }
            let lines = decoded.syncedLyrics.map(LRCParser.parse) ?? []
            if !lines.isEmpty {
                completion(.lyrics(lines), diagnostic + " · \(lines.count) lignes")
            } else if decoded.instrumental == true {
                completion(.lyrics([BridgeLyricLine(time: 0, text: "♪")]), diagnostic + " · instrumental")
            } else {
                completion(.unavailable("Paroles synchronisées indisponibles"), diagnostic)
            }
        }
        task.resume()
        return task
    }
}
