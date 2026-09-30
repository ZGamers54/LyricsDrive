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

private struct EeveeLyricsPayload {
    let trackID: String
    let title: String
    let artist: String
    let source: String
    let timeSynced: Bool
    let lines: [BridgeLyricLine]
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
    private var eeveeLyricsObserver: NSObjectProtocol?
    private var pendingEeveeLyrics: EeveeLyricsPayload?
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
            self.installEeveeLyricsObserver()
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
                status: "En attente des paroles EeveeSpotify…"
            )

            let hydrated: BridgeSnapshot
            if let payload = pendingEeveeLyrics, matches(payload: payload, snapshot: fresh) {
                hydrated = snapshotByApplying(payload: payload, to: fresh)
            } else {
                hydrated = fresh
            }

            snapshot = hydrated
            reloadWidget()

            Task {
                let active = await MainActor.run { UIApplication.shared.applicationState == .active }
                await liveActivity.restart(snapshot: hydrated, appIsActive: active)
                await liveActivity.update(snapshot: hydrated, position: clockPosition)
            }

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
                status: current.status
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

    private func installEeveeLyricsObserver() {
        eeveeLyricsObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("LyricsDrive.EeveeLyricsLoaded"),
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.stateQueue.async {
                self?.consumeEeveeLyrics(note)
            }
        }
    }

    private func consumeEeveeLyrics(_ note: Notification) {
        guard
            let info = note.userInfo,
            let trackID = info["trackId"] as? String,
            let title = info["title"] as? String,
            let artist = info["artist"] as? String,
            let source = info["source"] as? String,
            let timeSynced = info["timeSynced"] as? Bool
        else { return }

        let rawLines = info["lines"] as? [[String: Any]] ?? []
        let lines = rawLines.compactMap { row -> BridgeLyricLine? in
            guard
                let content = row["content"] as? String,
                !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            let offsetMs: Double
            if let n = row["offsetMs"] as? NSNumber {
                offsetMs = n.doubleValue
            } else if let i = row["offsetMs"] as? Int {
                offsetMs = Double(i)
            } else if let d = row["offsetMs"] as? Double {
                offsetMs = d
            } else {
                return nil
            }

            guard offsetMs >= 0 else { return nil }
            return BridgeLyricLine(time: offsetMs / 1000.0, text: content)
        }.sorted { $0.time < $1.time }

        let payload = EeveeLyricsPayload(
            trackID: trackID,
            title: title,
            artist: artist,
            source: source,
            timeSynced: timeSynced,
            lines: lines
        )
        pendingEeveeLyrics = payload

        guard let current = snapshot, matches(payload: payload, snapshot: current) else { return }

        let updated = snapshotByApplying(payload: payload, to: current)
        snapshot = updated
        reloadWidget()

        clockPosition = updated.progressAtAnchor
        clockAnchorDate = updated.anchorDate

        Task {
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            await liveActivity.ensureStarted(snapshot: updated, appIsActive: active)
            await liveActivity.update(snapshot: updated, position: updated.progressAtAnchor)
        }
    }

    private func matches(payload: EeveeLyricsPayload, snapshot: BridgeSnapshot) -> Bool {
        let currentID = normalizedSpotifyTrackID(snapshot.trackID)
        let incomingID = normalizedSpotifyTrackID(payload.trackID)

        if !incomingID.isEmpty, !currentID.isEmpty, incomingID == currentID {
            return true
        }

        let sameTitle = payload.title.compare(
            snapshot.title,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
        let sameArtist = payload.artist.compare(
            snapshot.artist,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame

        return sameTitle && sameArtist
    }

    private func normalizedSpotifyTrackID(_ raw: String) -> String {
        if raw.hasPrefix("spotify:track:") {
            return String(raw.dropFirst("spotify:track:".count))
        }

        if let range = raw.range(of: "/track/") {
            let tail = raw[range.upperBound...]
            return String(tail.split(separator: "?").first ?? Substring(tail))
        }

        if !raw.contains("|"), !raw.contains(" "), raw.count >= 16 {
            return raw
        }

        return ""
    }

    private func snapshotByApplying(
        payload: EeveeLyricsPayload,
        to current: BridgeSnapshot
    ) -> BridgeSnapshot {
        let now = Date()
        let stablePosition = min(
            current.duration > 0 ? current.duration : .greatestFiniteMagnitude,
            max(0, clockPosition + (clockIsPlaying ? max(0, now.timeIntervalSince(clockAnchorDate)) : 0))
        )

        let usableLines = payload.timeSynced ? payload.lines : []
        let status: String
        if !payload.timeSynced {
            status = "\(payload.source) — paroles non synchronisées"
        } else if usableLines.isEmpty {
            status = "\(payload.source) — aucune ligne synchronisée"
        } else {
            status = "\(payload.source) • EeveeSpotify"
        }

        return BridgeSnapshot(
            trackID: current.trackID,
            title: current.title,
            artist: current.artist,
            album: current.album,
            duration: current.duration,
            progressAtAnchor: stablePosition,
            anchorDate: now,
            isPlaying: clockIsPlaying,
            lines: usableLines,
            status: status
        )
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

}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
