import Foundation
import MediaPlayer
import Network
import WidgetKit

private struct BridgeLyricLine: Codable, Hashable {
    let time: TimeInterval
    let text: String
}

private struct BridgeSnapshot: Codable, Hashable {
    let trackID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let progressAtAnchor: TimeInterval
    let anchorDate: Date
    let isPlaying: Bool
    let lines: [BridgeLyricLine]
    let status: String
}

private struct LRCLIBResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
}

@_cdecl("zxPluginsInjectGenericEntry")
public func zxPluginsInjectGenericEntry() {
    LyricsDriveBridge.shared.start()
}

@_cdecl("LyricsDriveBridgeStart")
public func LyricsDriveBridgeStart() {
    LyricsDriveBridge.shared.start()
}

final class LyricsDriveBridge {
    static let shared = LyricsDriveBridge()

    private let stateQueue = DispatchQueue(label: "lyricsdrive.bridge.state")
    private var timer: DispatchSourceTimer?
    private var server: NWListener?
    private var snapshot: BridgeSnapshot?
    private var lastRawTrackID: String?
    private var lyricsGeneration = UUID()
    private var lastTransportState: Bool?
    private var lastAnchorProgress: TimeInterval = 0
    private var lastAnchorDate = Date.distantPast
    private var started = false

    private init() {}

    func start() {
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
            self.startServer()
            self.startPolling()
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.75, leeway: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            self?.pollNowPlaying()
        }
        self.timer = timer
        timer.resume()
    }

    private func pollNowPlaying() {
        DispatchQueue.main.async {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            self.stateQueue.async {
                self.consume(nowPlayingInfo: info)
            }
        }
    }

    private func consume(nowPlayingInfo info: [String: Any]) {
        guard let title = info[MPMediaItemPropertyTitle] as? String, !title.isEmpty else {
            updateEmptyState("En attente d’une lecture Spotify…")
            return
        }

        let artist = (info[MPMediaItemPropertyArtist] as? String) ?? ""
        let album = (info[MPMediaItemPropertyAlbumTitle] as? String) ?? ""
        let duration = numeric(info[MPMediaItemPropertyPlaybackDuration]) ?? 0
        let elapsed = numeric(info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) ?? 0
        let rate = numeric(info[MPNowPlayingInfoPropertyPlaybackRate]) ?? 0
        let isPlaying = rate > 0.001

        let externalID = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
        let trackID = externalID?.isEmpty == false
            ? externalID!
            : "\(title)|\(artist)|\(Int(duration.rounded()))"

        if trackID != lastRawTrackID {
            lastRawTrackID = trackID
            lastTransportState = isPlaying
            lastAnchorProgress = elapsed
            lastAnchorDate = Date()

            let generation = UUID()
            lyricsGeneration = generation

            snapshot = BridgeSnapshot(
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: elapsed,
                anchorDate: Date(),
                isPlaying: isPlaying,
                lines: [],
                status: "Recherche des paroles…"
            )
            reloadWidget()
            fetchLyrics(title: title, artist: artist, duration: duration, trackID: trackID, generation: generation)
            return
        }

        guard var current = snapshot else { return }

        let expected: TimeInterval
        if current.isPlaying {
            expected = current.progressAtAnchor + max(0, Date().timeIntervalSince(current.anchorDate))
        } else {
            expected = current.progressAtAnchor
        }

        let transportChanged = lastTransportState != isPlaying
        let drift = abs(expected - elapsed)

        if transportChanged || drift > 2.5 {
            current = BridgeSnapshot(
                trackID: current.trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: elapsed,
                anchorDate: Date(),
                isPlaying: isPlaying,
                lines: current.lines,
                status: current.lines.isEmpty ? current.status : "Paroles synchronisées"
            )
            snapshot = current
            lastTransportState = isPlaying
            lastAnchorProgress = elapsed
            lastAnchorDate = Date()
            reloadWidget()
        }
    }

    private func updateEmptyState(_ message: String) {
        guard snapshot != nil else { return }
        snapshot = nil
        lastRawTrackID = nil
        reloadWidget()
    }

    private func fetchLyrics(
        title: String,
        artist: String,
        duration: TimeInterval,
        trackID: String,
        generation: UUID
    ) {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }
        components.queryItems = query
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("LyricsDrive-EeveeBridge/0.1", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            self.stateQueue.async {
                guard generation == self.lyricsGeneration, trackID == self.lastRawTrackID else { return }

                if let data,
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
                   let raw = decoded.syncedLyrics,
                   !raw.isEmpty {
                    let lines = Self.parseLRC(raw)
                    if !lines.isEmpty {
                        self.applyLyrics(lines, status: "Paroles synchronisées", generation: generation)
                        return
                    }
                }

                let status = error == nil ? "Paroles synchronisées introuvables" : "LRCLIB indisponible"
                self.applyLyrics([], status: status, generation: generation)
            }
        }.resume()
    }

    private func applyLyrics(_ lines: [BridgeLyricLine], status: String, generation: UUID) {
        guard generation == lyricsGeneration, let current = snapshot else { return }
        snapshot = BridgeSnapshot(
            trackID: current.trackID,
            title: current.title,
            artist: current.artist,
            album: current.album,
            duration: current.duration,
            progressAtAnchor: current.progressAtAnchor,
            anchorDate: current.anchorDate,
            isPlaying: current.isPlaying,
            lines: lines,
            status: status
        )
        reloadWidget()
    }

    private func reloadWidget() {
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadTimelines(ofKind: "LyricsDriveCarPlay")
        }
    }

    private func startServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: 38475)
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { _ in }
            listener.start(queue: stateQueue)
            server = listener
        } catch {
            server = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: stateQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] _, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let payload: Data
            if let snapshot = self.snapshot,
               let encoded = try? JSONEncoder.bridge.encode(snapshot) {
                payload = encoded
            } else {
                payload = Data("{}".utf8)
            }

            connection.send(content: payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func numeric(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    private static func parseLRC(_ raw: String) -> [BridgeLyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]\s*(.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return raw.split(separator: "\n", omittingEmptySubsequences: false).compactMap { sub in
            let line = String(sub)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges >= 5,
                  let minRange = Range(match.range(at: 1), in: line),
                  let secRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 4), in: line),
                  let minutes = Double(line[minRange]),
                  let seconds = Double(line[secRange]) else {
                return nil
            }

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
            return BridgeLyricLine(time: minutes * 60 + seconds + fraction, text: text)
        }.sorted { $0.time < $1.time }
    }
}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
