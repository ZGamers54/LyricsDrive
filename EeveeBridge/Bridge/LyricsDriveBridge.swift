import ActivityKit
import Foundation
import MediaPlayer
import Network
import UIKit
import WidgetKit

struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let currentLine: String
        let nextLine: String
        let progress: Double
        let isPlaying: Bool
    }

    let trackID: String
}

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

    func linePair(at position: TimeInterval) -> (String, String) {
        guard !lines.isEmpty else { return (status, "") }

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

        guard let index = answer else {
            return ("♪", lines.first?.text ?? "")
        }

        let current = lines[index].text
        let next = index + 1 < lines.count ? lines[index + 1].text : ""
        return (current, next)
    }
}

private struct LRCLIBResponse: Decodable {
    let trackName: String?
    let artistName: String?
    let duration: Double?
    let syncedLyrics: String?
}

private actor LyricsLiveActivityController {
    private var activity: Activity<LyricsActivityAttributes>?
    private var fingerprint = ""
    private var lastAttempt = Date.distantPast

    func ensureStarted(snapshot: BridgeSnapshot, appIsActive: Bool) async {
        guard appIsActive else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { return }
        guard Date().timeIntervalSince(lastAttempt) >= 2 else { return }
        lastAttempt = Date()

        let pair = snapshot.linePair(at: snapshot.progressAtAnchor)
        let state = LyricsActivityAttributes.ContentState(
            title: snapshot.title,
            artist: snapshot.artist,
            currentLine: pair.0,
            nextLine: pair.1,
            progress: snapshot.duration > 0 ? snapshot.progressAtAnchor / snapshot.duration : 0,
            isPlaying: snapshot.isPlaying
        )

        do {
            activity = try Activity.request(
                attributes: LyricsActivityAttributes(trackID: snapshot.trackID),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)),
                pushType: nil
            )
            fingerprint = ""
        } catch {
            activity = nil
        }
    }

    func restart(snapshot: BridgeSnapshot, appIsActive: Bool) async {
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
            self.activity = nil
        }
        fingerprint = ""
        lastAttempt = .distantPast
        await ensureStarted(snapshot: snapshot, appIsActive: appIsActive)
    }

    func update(snapshot: BridgeSnapshot, position: TimeInterval) async {
        guard let activity else { return }

        let pair = snapshot.linePair(at: position)
        let progress = snapshot.duration > 0 ? min(max(position / snapshot.duration, 0), 1) : 0
        let bucket = Int(progress * 100)
        let nextFingerprint = "\(snapshot.trackID)|\(pair.0)|\(pair.1)|\(snapshot.isPlaying)|\(bucket)"

        guard nextFingerprint != fingerprint else { return }
        fingerprint = nextFingerprint

        let state = LyricsActivityAttributes.ContentState(
            title: snapshot.title,
            artist: snapshot.artist,
            currentLine: pair.0,
            nextLine: pair.1,
            progress: progress,
            isPlaying: snapshot.isPlaying
        )

        await activity.update(
            ActivityContent(
                state: state,
                staleDate: Date().addingTimeInterval(15)
            )
        )
    }

    func stop() async {
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        fingerprint = ""
        lastAttempt = .distantPast
    }
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
    private let liveActivity = LyricsLiveActivityController()
    private var timer: DispatchSourceTimer?
    private var server: NWListener?
    private var snapshot: BridgeSnapshot?
    private var lastRawTrackID: String?
    private var lyricsGeneration = UUID()
    private var lastTransportState: Bool?
    private var clockPosition: TimeInterval = 0
    private var clockAnchorDate = Date()
    private var clockIsPlaying = false
    private var backwardSeekCandidate: (raw: TimeInterval, count: Int)?
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
        timer.schedule(deadline: .now() + 0.5, repeating: 0.50, leeway: .milliseconds(80))
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
            updateEmptyState()
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
            clockPosition = max(0, elapsed)
            clockAnchorDate = Date()
            clockIsPlaying = isPlaying
            backwardSeekCandidate = nil

            let generation = UUID()
            lyricsGeneration = generation

            let fresh = BridgeSnapshot(
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: clockPosition,
                anchorDate: clockAnchorDate,
                isPlaying: isPlaying,
                lines: [],
                status: "Recherche des paroles…"
            )
            snapshot = fresh
            reloadWidget()

            Task {
                let active = await MainActor.run { UIApplication.shared.applicationState == .active }
                await liveActivity.restart(snapshot: fresh, appIsActive: active)
                await liveActivity.update(snapshot: fresh, position: clockPosition)
            }

            fetchLyrics(title: title, artist: artist, duration: duration, trackID: trackID, generation: generation)
            return
        }

        guard var current = snapshot else { return }

        let now = Date()
        var estimated = clockPosition + (clockIsPlaying ? max(0, now.timeIntervalSince(clockAnchorDate)) : 0)
        estimated = min(max(estimated, 0), duration > 0 ? duration : estimated)

        let transportChanged = clockIsPlaying != isPlaying
        var reanchored = false

        if transportChanged {
            // MPNowPlayingInfoCenter occasionally reports 0/stale elapsed time during transitions.
            // Prefer the local monotonic clock unless the raw value is clearly plausible.
            let candidate = (elapsed > 0.5 || estimated < 2.0) && abs(elapsed - estimated) < 8.0
                ? elapsed
                : estimated
            clockPosition = max(0, candidate)
            clockAnchorDate = now
            clockIsPlaying = isPlaying
            backwardSeekCandidate = nil
            estimated = clockPosition
            reanchored = true
        } else {
            let delta = elapsed - estimated

            if elapsed <= 0.5 && estimated > 3.0 {
                // Ignore the common transient 0-second sample.
                backwardSeekCandidate = nil
            } else if delta > 3.0 {
                // Forward seeks are safe to accept immediately.
                clockPosition = elapsed
                clockAnchorDate = now
                estimated = elapsed
                backwardSeekCandidate = nil
                reanchored = true
            } else if delta < -3.0 {
                // A real backward seek produces several coherent low samples; a stale sample usually does not.
                if let candidate = backwardSeekCandidate,
                   abs(elapsed - candidate.raw) < 2.0 {
                    let nextCount = candidate.count + 1
                    backwardSeekCandidate = (elapsed, nextCount)
                    if nextCount >= 3 {
                        clockPosition = elapsed
                        clockAnchorDate = now
                        estimated = elapsed
                        backwardSeekCandidate = nil
                        reanchored = true
                    }
                } else {
                    backwardSeekCandidate = (elapsed, 1)
                }
            } else {
                backwardSeekCandidate = nil
            }
        }

        if reanchored || lastTransportState != isPlaying {
            current = BridgeSnapshot(
                trackID: current.trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: clockPosition,
                anchorDate: clockAnchorDate,
                isPlaying: isPlaying,
                lines: current.lines,
                status: current.lines.isEmpty ? current.status : "Paroles synchronisées"
            )
            snapshot = current
            lastTransportState = isPlaying
            reloadWidget()
        }

        if let latest = snapshot {
            Task {
                let active = await MainActor.run { UIApplication.shared.applicationState == .active }
                await liveActivity.ensureStarted(snapshot: latest, appIsActive: active)
                await liveActivity.update(snapshot: latest, position: estimated)
            }
        }
    }

    private func updateEmptyState() {
        guard snapshot != nil else { return }
        snapshot = nil
        lastRawTrackID = nil
        clockPosition = 0
        clockAnchorDate = Date()
        clockIsPlaying = false
        backwardSeekCandidate = nil
        reloadWidget()
        Task { await liveActivity.stop() }
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
        request.setValue("LyricsDrive-EeveeBridge/0.3", forHTTPHeaderField: "User-Agent")

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

        let now = Date()
        let stablePosition = clockPosition + (clockIsPlaying ? max(0, now.timeIntervalSince(clockAnchorDate)) : 0)
        let updated = BridgeSnapshot(
            trackID: current.trackID,
            title: current.title,
            artist: current.artist,
            album: current.album,
            duration: current.duration,
            progressAtAnchor: stablePosition,
            anchorDate: now,
            isPlaying: clockIsPlaying,
            lines: lines,
            status: status
        )
        snapshot = updated
        reloadWidget()

        clockPosition = stablePosition
        clockAnchorDate = now

        Task {
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            await liveActivity.ensureStarted(snapshot: updated, appIsActive: active)
            await liveActivity.update(snapshot: updated, position: stablePosition)
        }
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
