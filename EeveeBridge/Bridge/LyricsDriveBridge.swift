import ActivityKit
import Foundation
import AVFAudio
import OSLog
import MediaPlayer
import Network
import UIKit
import WidgetKit

struct LyricsActivityAttributes: ActivityAttributes {
    typealias ContentState = LyricsLiveState
    // Stable session identity. The current track lives in ContentState and can change while locked.
    let trackID: String
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

    var playbackRate: Double? = nil
    var displayOffset: TimeInterval? = nil
    var effectiveRate: Double { isPlaying ? max(0, playbackRate ?? 1) : 0 }

    func linePair(at position: TimeInterval) -> (String, String) {
        guard !lines.isEmpty else { return (status, "") }
        guard let index = LyricsSchedule.currentIndex(in: lines, position: position,
            offset: displayOffset ?? 0, time: { $0.time }) else {
            return ("♪", lines.first?.text ?? "")
        }
        return (lines[index].text, index + 1 < lines.count ? lines[index + 1].text : "")
    }

}

private actor LyricsLiveActivityController {
    private struct Submission {
        let snapshot: BridgeSnapshot
        let position: TimeInterval
        let issuedUptime: TimeInterval
        let sequence: Int
        let refresh: Bool
    }

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsLiveState?
    private var lastAttempt = Date.distantPast
    private var lastForcedSubmission = Date.distantPast
    private var diagnostic = "Pas encore démarrée"
    private var lastSubmitted: Date?
    private var pending: Submission?
    private var processing = false
    private var latestSequence = 0
    private var epoch = 0
    private var foregroundUpdates = 0
    private var backgroundUpdates = 0
    private var payloadBytes = 0
    private var lastBackgroundSubmission: Date?
    private var lastUpdateDuration: TimeInterval = 0
    private var maxUpdateDuration: TimeInterval = 0
    private var expiredLeases = 0
    private var deniedLeases = 0
    private let logger = Logger(subsystem: "com.lyricsdrive.bridge", category: "activity")

    func report() -> String {
        let state = activity.map { String(describing: $0.activityState) } ?? "absente"
        return diagnostic
            + (lastSubmitted.map { " · dernier envoi " + ISO8601DateFormatter().string(from: $0) } ?? "")
            + "\nÉtat ActivityKit : " + state
            + "\nEnvois terminés : \(foregroundUpdates) premier plan · \(backgroundUpdates) arrière-plan"
            + "\nÉtat + attributs : \(payloadBytes) octets (limite 4 Ko)"
            + "\nDernier envoi arrière-plan : " + (lastBackgroundSubmission.map { ISO8601DateFormatter().string(from: $0) } ?? "jamais")
            + "\nDurée Activity.update : \(Int(lastUpdateDuration * 1000)) ms · maximum \(Int(maxUpdateDuration * 1000)) ms"
            + "\nTâches courtes expirées : \(expiredLeases) · non accordées : \(deniedLeases)"
            + "\nUn envoi terminé ne confirme pas le rendu par iOS."
    }

    /// Coalesce pending work while ActivityKit awaits; an older track can never overtake a newer one.
    func submit(snapshot: BridgeSnapshot, position: TimeInterval, issuedUptime: TimeInterval, sequence: Int, refresh: Bool) async {
        guard sequence > latestSequence else { return }
        latestSequence = sequence
        pending = Submission(snapshot: snapshot, position: position, issuedUptime: issuedUptime, sequence: sequence, refresh: refresh)
        guard !processing else { return }
        processing = true
        while let next = pending {
            pending = nil
            await send(next)
        }
        processing = false
    }

    private func send(_ submission: Submission) async {
        let submissionEpoch = epoch
        let appIsActive = await MainActor.run { UIApplication.shared.applicationState == .active }
        guard submissionEpoch == epoch else { return }
        // A newer snapshot arrived while querying app state.
        guard submission.sequence == latestSequence else { return }

        if let current = activity, current.activityState == .ended || current.activityState == .dismissed {
            activity = nil
            lastState = nil
        }
        if activity == nil {
            // Recover an activity if the bridge restarted; never create one activity per song.
            activity = Activity<LyricsActivityAttributes>.activities.first {
                $0.activityState == .active || $0.activityState == .stale
            }
            if activity != nil { lastState = nil }
        }

        let attributes = activity?.attributes ?? LyricsActivityAttributes(trackID: UUID().uuidString)
        let attributesBytes = (try? JSONEncoder().encode(attributes).count) ?? 100
        let snapshot = submission.snapshot
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - submission.issuedUptime) * snapshot.effectiveRate
        let position = min(snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude,
                           max(0, submission.position + elapsed))
        let pair = snapshot.linePair(at: position)
        let state = LyricsLiveState(
            trackID: snapshot.trackID, title: snapshot.title, artist: snapshot.artist,
            currentLine: pair.0, nextLine: pair.1,
            progress: snapshot.duration > 0 ? min(1, position / snapshot.duration) : 0,
            isPlaying: snapshot.isPlaying, anchorDate: Date(), positionAtAnchor: position,
            duration: snapshot.duration, playbackRate: snapshot.effectiveRate
        ).bounded(attributesBytes: attributesBytes)
        payloadBytes = ((try? JSONEncoder().encode(state).count) ?? 0) + attributesBytes
        guard payloadBytes <= 3_500 else {
            diagnostic = "État trop volumineux · envoi annulé"
            return
        }
        let forcedRefresh = submission.refresh && Date().timeIntervalSince(lastForcedSubmission) >= 2
        guard forcedRefresh || state.needsPublication(comparedTo: lastState, at: Date()) else { return }
        if forcedRefresh { lastForcedSubmission = Date() }
        let content = ActivityContent(state: state, staleDate: nil)

        if activity == nil {
            guard appIsActive else {
                diagnostic = "Démarrage en attente : ouvrir Spotify une fois"
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                diagnostic = "Activités en direct désactivées dans iOS"
                return
            }
            guard Date().timeIntervalSince(lastAttempt) >= 2 else { return }
            lastAttempt = Date()
            do {
                activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                lastState = state
                lastSubmitted = Date()
                diagnostic = "Créée · activité conservée entre les morceaux"
            } catch {
                diagnostic = "Échec création : \(error.localizedDescription)"
            }
            return
        }

        guard let activity else { return }
        let lease = await MainActor.run { ActivityUpdateLease() }
        // Background execution is supplied by Spotify's real audio playback, not by the widget.
        let startedAt = ProcessInfo.processInfo.systemUptime
        await activity.update(content)
        lastUpdateDuration = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        maxUpdateDuration = max(maxUpdateDuration, lastUpdateDuration)
        let leaseResult = await MainActor.run { () -> (Bool, Bool) in
            lease.finish()
            return (lease.granted, lease.expired)
        }
        if !leaseResult.0 { deniedLeases += 1 }
        if leaseResult.1 { expiredLeases += 1 }
        guard submissionEpoch == epoch else { return }
        lastState = state
        lastSubmitted = Date()
        if appIsActive { foregroundUpdates += 1 } else {
            backgroundUpdates += 1
            lastBackgroundSubmission = lastSubmitted
        }
        logger.debug("seq=\(submission.sequence) background=\(!appIsActive) update_ms=\(Int(lastUpdateDuration * 1000))")
        diagnostic = "Phrase et ancre transmises à ActivityKit"
    }

    func stop(sequence: Int) async {
        guard sequence > latestSequence else { return }
        latestSequence = sequence
        epoch += 1
        pending = nil
        let current = activity
        activity = nil
        lastState = nil
        lastAttempt = .distantPast
        diagnostic = "Arrêtée"
        lastSubmitted = nil
        if let current {
            let lease = await MainActor.run { ActivityUpdateLease() }
            await current.end(nil, dismissalPolicy: .immediate)
            await lease.finish()
        }
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
    private var lineTimer: DispatchSourceTimer?
    private var nextLineUptime: TimeInterval?
    private var pollInFlight = false
    private var forceNextPublication = false
    private var lastQueuedState: LyricsLiveState?
    private let logger = Logger(subsystem: "com.lyricsdrive.bridge", category: "sync")
    private var timingLog: [String] = []
    private var displayOffset: TimeInterval = {
        let millis = UserDefaults.standard.integer(forKey: "LyricsDrive.SyncOffsetMilliseconds")
        return Double(min(2_000, max(-2_000, millis))) / 1000
    }()
    private var audioInterrupted = false
    private var server: NWListener?
    private var snapshot: BridgeSnapshot?
    private var lastRawTrackID: String?
    private var lyricsGeneration = UUID()
    private var playbackClock = PlaybackClock()
    private var started = false
    private var changingMode = false
    private var demoStarted: Date?
    private var demoStartedUptime: TimeInterval?
    private var lastPoll: Date?
    private var rawElapsed: Double?
    private var rawRate: Double?
    private var rawChangedAt: Date?
    private var lyricsDiagnostic = "Pas de requête"
    private var serverDiagnostic = "Pas encore démarré"
    private var lastWidgetRequest: Date?
    private var lastWidgetAck: Date?
    private var widgetDiagnostic = "Aucune timeline confirmée"
    private var reloadRequested: Date?
    private var lastNowPlayingKeys = ""
    private var publicationSequence = 0
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var lyricsTask: URLSessionDataTask?
    private var lyricsRetry: DispatchWorkItem?
    private let lyricsFetcher = LyricsFetcher()
    private lazy var lyricsCache: LyricsCache = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return LyricsCache(directory: root.appendingPathComponent("LyricsDrive/Lyrics-v1", isDirectory: true))
    }()
    private var emptySince: Date?
    private var backgroundEnteredAt: Date?
    private var backgroundPolls = 0
    private var maxPollGap: TimeInterval = 0
    private var lastPollUptime: TimeInterval?
    private var lastBackgroundSample = "aucun"
    private var lastBackgroundKeys = ""
    private var lastBackgroundSampleAt: Date?
    private var lineTimerFirings = 0
    private var backgroundLineFirings = 0
    private var maxLineTimerDelay: TimeInterval = 0
    private var lastResynchronisation = "Démarrage"


    private init() {}

    func start() {
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
            self.startServer()
            self.startPolling()
            DispatchQueue.main.async {
                BridgeDiagnosticsUI.shared.install()
                self.observeLifecycle()
            }
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(25))
        timer.setEventHandler { [weak self] in
            self?.pollNowPlaying()
        }
        self.timer = timer
        timer.resume()
        let boundaryTimer = DispatchSource.makeTimerSource(queue: stateQueue)
        boundaryTimer.schedule(deadline: .distantFuture)
        boundaryTimer.setEventHandler { [weak self] in self?.lineTimerFired() }
        lineTimer = boundaryTimer
        boundaryTimer.resume()
        pollNowPlaying(force: true)
    }

    /// Discover transport/metadata changes without publishing on every tick.
    /// At most one main-thread read can be outstanding.
    private func pollNowPlaying(force: Bool = false) {
        forceNextPublication = forceNextPublication || force
        guard !pollInFlight else { return }
        pollInFlight = true
        DispatchQueue.main.async {
            let sampledAt = Date()
            let sampledUptime = ProcessInfo.processInfo.systemUptime
            let background = UIApplication.shared.applicationState != .active
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            self.stateQueue.async {
                self.pollInFlight = false
                let force = self.forceNextPublication
                self.forceNextPublication = false
                self.consume(nowPlayingInfo: info, sampledAt: sampledAt,
                             sampledUptime: sampledUptime, background: background, force: force)
            }
        }
    }

    private func consume(nowPlayingInfo info: [String: Any], sampledAt: Date,
                         sampledUptime: TimeInterval, background: Bool, force: Bool) {
        if let previous = lastPollUptime { maxPollGap = max(maxPollGap, max(0, sampledUptime - previous)) }
        lastPollUptime = sampledUptime
        lastPoll = sampledAt
        if background { backgroundPolls += 1 }
        // Preserve a background sample: live values may already change after unlocking.
        defer {
            if background {
                lastBackgroundSampleAt = sampledAt
                lastBackgroundKeys = lastNowPlayingKeys
                let p = demoStarted == nil
                    ? playbackClock.position(at: sampledUptime, duration: snapshot?.duration ?? 0)
                    : (snapshot?.progressAtAnchor ?? 0)
                let line = snapshot.flatMap {
                    LyricsSchedule.currentIndex(in: $0.lines, position: p,
                        offset: $0.displayOffset ?? 0, time: { $0.time })
                }
                lastBackgroundSample = "brute=\(rawElapsed.map { String(format: "%.2f", $0) } ?? "absente") s"
                    + " · vitesse brute=\(rawRate.map { String($0) } ?? "absente")"
                    + String(format: " · calcul=%.2f s · vitesse retenue=%.2f", p, playbackClock.rate)
                    + " · phrase=\(line.map { String($0 + 1) } ?? "intro") · interruption=\(audioInterrupted)"
            }
        }
        guard !changingMode else { return }
        if demoStarted != nil {
            updateDemo()
            return
        }
        let newRaw = numeric(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        if newRaw != rawElapsed { rawChangedAt = Date() }
        rawElapsed = newRaw
        rawRate = numeric(info[MPNowPlayingInfoPropertyPlaybackRate])
        lastNowPlayingKeys = info.keys.sorted().joined(separator: ", ")
        guard let title = info[MPMediaItemPropertyTitle] as? String, !title.isEmpty else {
            updateEmptyState()
            return
        }

        emptySince = nil
        let artist = (info[MPMediaItemPropertyArtist] as? String) ?? ""
        let album = (info[MPMediaItemPropertyAlbumTitle] as? String) ?? ""
        let duration = max(0, numeric(info[MPMediaItemPropertyPlaybackDuration]) ?? 0)
        let elapsed = numeric(info[MPNowPlayingInfoPropertyElapsedPlaybackTime])
        // Missing rate retains the clock's last valid rate; only explicit zero pauses.
        let rate: Double? = audioInterrupted ? 0 : rawRate

        let externalID = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
        let trackID = externalID?.isEmpty == false
            ? externalID!
            : "\(title)|\(artist)|\(Int(duration.rounded()))"

        if trackID != lastRawTrackID {
            lastRawTrackID = trackID
            playbackClock.reset(elapsed: elapsed, rate: rate, now: sampledUptime)
            let now = Date()
            let position = playbackClock.position(at: ProcessInfo.processInfo.systemUptime, duration: duration)

            cancelLyricsRequest()
            let generation = UUID()
            lyricsGeneration = generation

            let fresh = BridgeSnapshot(
                trackID: trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: position,
                anchorDate: now,
                isPlaying: playbackClock.isPlaying,
                lines: [],
                status: "♪", playbackRate: playbackClock.rate, displayOffset: displayOffset
            )
            snapshot = fresh
            reloadWidget()

            publish(snapshot: fresh, position: fresh.progressAtAnchor)
            scheduleNextLine()
            recordTiming("nouveau morceau · ancre=\(String(format: "%.2f", position)) · rate=\(playbackClock.rate)")
            let lookup = LyricsLookup(title: title, artist: artist, album: album, duration: duration)
            if let cached = lyricsCache.load(lookup) {
                lyricsDiagnostic = "Cache local · \(cached.count) lignes · aucune requête réseau"
                applyLyrics(cached, status: "Paroles synchronisées", generation: generation)
            } else {
                fetchLyrics(lookup: lookup, trackID: trackID, generation: generation)
            }
            return
        }

        guard var current = snapshot else { return }

        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let reanchored = playbackClock.consume(elapsed: elapsed, rate: rate, now: sampledUptime, duration: duration)
        let estimated = playbackClock.position(at: uptime, duration: duration)

        let metadataChanged = title != current.title || artist != current.artist
            || album != current.album || duration != current.duration
        let previousRate = current.effectiveRate
        if reanchored || metadataChanged || force {
            current = BridgeSnapshot(
                trackID: current.trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: estimated,
                anchorDate: now,
                isPlaying: playbackClock.isPlaying,
                lines: current.lines,
                status: current.lines.isEmpty ? current.status : "Paroles synchronisées",
                playbackRate: playbackClock.rate, displayOffset: displayOffset
            )
            snapshot = current
            if metadataChanged || force || previousRate != playbackClock.rate
                || abs(playbackClock.lastAnchorCorrection ?? 0) > 0.35 {
                reloadWidget()
            }
            scheduleNextLine()
            if reanchored {
                recordTiming(String(format: "nouvelle ancre · correction=%+.3f s · rate=%.2f",
                    playbackClock.lastAnchorCorrection ?? 0, playbackClock.rate))
            }
        }

        if let latest = snapshot {
            publish(snapshot: latest, position: estimated, force: force)
        }
    }

    @MainActor
    private func observeLifecycle() {
        let names: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.significantTimeChangeNotification,
            UIScene.willConnectNotification, UIScene.didActivateNotification, UIScene.didDisconnectNotification,
            AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ]
        for name in names {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: nil, queue: .main) { [weak self] event in
                guard let self else { return }
                let background = UIApplication.shared.applicationState != .active
                let reason = event.name.rawValue
                let interruption = event.name == AVAudioSession.interruptionNotification
                    ? (event.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue : nil
                self.stateQueue.async {
                    if background && self.backgroundEnteredAt == nil {
                        self.backgroundEnteredAt = Date()
                        self.backgroundPolls = 0
                        self.backgroundLineFirings = 0
                        self.maxPollGap = 0
                    } else if !background { self.backgroundEnteredAt = nil }
                    if let interruption,
                       let type = AVAudioSession.InterruptionType(rawValue: interruption) {
                        self.audioInterrupted = type == .began
                        if type == .began { self.pauseForAudioInterruption() }
                        // Spotify decides whether to resume; read its metadata without controlling audio.
                    }
                    self.lastResynchronisation = reason
                    self.recordTiming("resynchronisation · " + reason)
                    self.pollNowPlaying(force: true)
                    // Notifications can precede Spotify's own metadata update.
                    self.stateQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        self?.pollNowPlaying(force: true)
                    }
                }
            })
        }
    }

    private func pauseForAudioInterruption() {
        guard demoStarted == nil, let current = snapshot, current.trackID != "lyricsdrive-idle" else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        playbackClock.consume(elapsed: nil, rate: 0, now: uptime, duration: current.duration)
        let paused = BridgeSnapshot(trackID: current.trackID, title: current.title, artist: current.artist,
            album: current.album, duration: current.duration,
            progressAtAnchor: playbackClock.position(at: uptime, duration: current.duration),
            anchorDate: Date(), isPlaying: false, lines: current.lines, status: current.status,
            playbackRate: 0, displayOffset: displayOffset)
        snapshot = paused
        scheduleNextLine()
        publish(snapshot: paused, position: paused.progressAtAnchor)
        reloadWidget()
    }

    /// One one-shot timer for the next lyric boundary; re-plan on seek/rate/offset/track changes.
    private func scheduleNextLine() {
        lineTimer?.schedule(deadline: .distantFuture)
        nextLineUptime = nil
        guard !changingMode, let current = snapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let position = demoStartedUptime.map { min(30, max(0, now - $0)) }
            ?? playbackClock.position(at: now, duration: current.duration)
        guard let delay = LyricsSchedule.nextDelay(in: current.lines, position: position,
            rate: current.effectiveRate, offset: current.displayOffset ?? 0,
            duration: current.duration, time: { $0.time }) else { return }
        nextLineUptime = now + delay
        lineTimer?.schedule(deadline: .now() + max(0.002, delay), leeway: .milliseconds(5))
    }

    private func lineTimerFired() {
        guard let expected = nextLineUptime, !changingMode else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let lateness = max(0, now - expected)
        maxLineTimerDelay = max(maxLineTimerDelay, lateness)
        lineTimerFirings += 1
        if backgroundEnteredAt != nil { backgroundLineFirings += 1 }
        recordTiming(String(format: "échéance phrase · retard=%.1f ms", lateness * 1000))
        if demoStarted != nil { updateDemo(); return }
        if let current = snapshot {
            let position = playbackClock.position(at: now, duration: current.duration)
            publish(snapshot: current, position: position)
        }
        // Delayed delivery catches up immediately by binary search, skipping stale cues.
        scheduleNextLine()
    }

    private func recordTiming(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        timingLog.append(ISO8601DateFormatter().string(from: Date()) + " · " + message)
        if timingLog.count > 20 { timingLog.removeFirst(timingLog.count - 20) }
    }

    private func publish(snapshot: BridgeSnapshot, position: TimeInterval, force: Bool = false) {
        let issuedAt = Date()
        let pair = snapshot.linePair(at: position)
        let candidate = LyricsLiveState(trackID: snapshot.trackID, title: snapshot.title,
            artist: snapshot.artist, currentLine: pair.0, nextLine: pair.1,
            progress: snapshot.duration > 0 ? min(1, position / snapshot.duration) : 0,
            isPlaying: snapshot.isPlaying, anchorDate: issuedAt, positionAtAnchor: position,
            duration: snapshot.duration, playbackRate: snapshot.effectiveRate)
        guard force || candidate.needsPublication(comparedTo: lastQueuedState, at: issuedAt) else { return }
        lastQueuedState = candidate
        publicationSequence += 1
        let sequence = publicationSequence
        let issuedUptime = ProcessInfo.processInfo.systemUptime
        Task {
            await liveActivity.submit(snapshot: snapshot, position: position,
                                      issuedUptime: issuedUptime, sequence: sequence, refresh: force)
        }
    }

    func setSynchronizationOffset(milliseconds: Int) {
        stateQueue.async {
            let value = min(2_000, max(-2_000, milliseconds))
            self.displayOffset = Double(value) / 1000
            UserDefaults.standard.set(value, forKey: "LyricsDrive.SyncOffsetMilliseconds")
            guard var current = self.snapshot else { return }
            current.displayOffset = self.displayOffset
            self.snapshot = current
            self.recordTiming("décalage manuel · \(value) ms (+ = avance)")
            self.scheduleNextLine()
            let position = self.demoStartedUptime.map {
                min(30, max(0, ProcessInfo.processInfo.systemUptime - $0))
            } ?? self.playbackClock.position(at: ProcessInfo.processInfo.systemUptime, duration: current.duration)
            self.publish(snapshot: current, position: position, force: true)
            self.reloadWidget()
        }
    }

    private func updateEmptyState() {
        guard let previous = snapshot, previous.trackID != "lyricsdrive-idle" else { return }
        if emptySince == nil { emptySince = Date() }
        // Now Playing can briefly be empty between tracks. Keep the session alive.
        guard Date().timeIntervalSince(emptySince!) >= 2 else { return }
        cancelLyricsRequest()
        lyricsGeneration = UUID()
        lastRawTrackID = nil
        playbackClock = PlaybackClock()
        let idle = BridgeSnapshot(trackID: "lyricsdrive-idle", title: "LyricsDrive", artist: "", album: "",
            duration: 0, progressAtAnchor: 0, anchorDate: Date(), isPlaying: false,
            lines: [], status: "En attente de musique")
        snapshot = idle
        scheduleNextLine()
        reloadWidget()
        publish(snapshot: idle, position: 0)
    }

    private func cancelLyricsRequest() {
        lyricsRetry?.cancel()
        lyricsRetry = nil
        lyricsTask?.cancel()
        lyricsTask = nil
    }

    private func fetchLyrics(lookup: LyricsLookup, trackID: String, generation: UUID, attempt: Int = 0) {
        guard generation == lyricsGeneration, trackID == lastRawTrackID else { return }
        lyricsRetry = nil
        lyricsDiagnostic = attempt == 0 ? "Requête LRCLIB en cours" : "Tentative LRCLIB \(attempt + 1)"
        lyricsTask = lyricsFetcher.fetch(lookup, attempt: attempt) { result, diagnostic in
            self.stateQueue.async {
                guard generation == self.lyricsGeneration, trackID == self.lastRawTrackID else { return }
                self.lyricsTask = nil
                self.lyricsDiagnostic = diagnostic
                switch result {
                case .lyrics(let lines):
                    let persisted = self.lyricsCache.save(lines, for: lookup)
                    self.lyricsDiagnostic += persisted ? " · cache enregistré" : " · cache mémoire (écriture disque indisponible)"
                    self.applyLyrics(lines, status: "Paroles synchronisées", generation: generation)
                case .retry(let delay):
                    self.lyricsDiagnostic += " · nouvelle tentative dans \(String(format: "%.1f", delay)) s"
                    // Keep valid lyrics if a refresh fails; never store an error as lyrics.
                    if self.snapshot?.lines.isEmpty != false {
                        self.applyLyrics([], status: "♪", generation: generation)
                    }
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self, generation == self.lyricsGeneration, trackID == self.lastRawTrackID else { return }
                        self.fetchLyrics(lookup: lookup, trackID: trackID, generation: generation, attempt: attempt + 1)
                    }
                    self.lyricsRetry = retry
                    self.stateQueue.asyncAfter(deadline: .now() + delay, execute: retry)
                case .unavailable:
                    if self.snapshot?.lines.isEmpty != false {
                        self.applyLyrics([], status: "♪", generation: generation)
                    }
                }
            }
        }
    }

    private func applyLyrics(_ lines: [BridgeLyricLine], status: String, generation: UUID) {
        guard generation == lyricsGeneration, let current = snapshot else { return }

        let now = Date()
        let stablePosition = playbackClock.position(at: ProcessInfo.processInfo.systemUptime, duration: current.duration)
        let updated = BridgeSnapshot(
            trackID: current.trackID,
            title: current.title,
            artist: current.artist,
            album: current.album,
            duration: current.duration,
            progressAtAnchor: stablePosition,
            anchorDate: now,
            isPlaying: playbackClock.isPlaying,
            lines: lines,
            status: status, playbackRate: playbackClock.rate, displayOffset: displayOffset
        )
        snapshot = updated
        scheduleNextLine()
        reloadWidget()


        publish(snapshot: updated, position: stablePosition)
    }

    private func reloadWidget() {
        reloadRequested = Date()
        DispatchQueue.main.async {
            WidgetCenter.shared.reloadTimelines(ofKind: "LyricsDriveCarPlay")
        }
    }

    private func startServer() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 38475)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.serverDiagnostic = "Prêt sur 127.0.0.1:38475"
                case .failed(let error): self?.serverDiagnostic = "Échec : \(error.localizedDescription)"
                case .waiting(let error): self?.serverDiagnostic = "En attente : \(error.localizedDescription)"
                case .cancelled: self?.serverDiagnostic = "Arrêté"
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: stateQueue)
            server = listener
        } catch {
            serverDiagnostic = "Échec écoute : \(error.localizedDescription)"
            server = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: stateQueue)
        var buffer = Data()
        func receiveRequest() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                guard buffer.count <= 4096, error == nil else { connection.cancel(); return }
                guard let newline = buffer.firstIndex(of: 10) else {
                    if complete { connection.cancel() } else { receiveRequest() }
                    return
                }
                let request = String(decoding: buffer[..<newline], as: UTF8.self)
                let payload: Data
                if request == "STATE" {
                    self.lastWidgetRequest = Date()
                    payload = self.snapshot.flatMap { try? JSONEncoder.bridge.encode($0) } ?? Data("{}".utf8)
                } else if request.hasPrefix("ACK ") {
                    self.lastWidgetAck = Date()
                    self.widgetDiagnostic = String(request.dropFirst(4).prefix(200))
                    payload = Data("OK".utf8)
                } else {
                    connection.cancel(); return
                }
                connection.send(content: payload + Data([10]), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        receiveRequest()
        stateQueue.asyncAfter(deadline: .now() + 3) { connection.cancel() }
    }

    func setDemo(_ enabled: Bool) {
        stateQueue.async {
            guard !self.changingMode else { return }
            self.changingMode = true
            self.lineTimer?.schedule(deadline: .distantFuture)
            self.nextLineUptime = nil
            self.lastQueuedState = nil
            self.cancelLyricsRequest()
            self.lyricsGeneration = UUID()
            self.snapshot = nil
            self.lastRawTrackID = nil
            self.publicationSequence += 1
            let sequence = self.publicationSequence
            Task {
                await self.liveActivity.stop(sequence: sequence)
                self.stateQueue.async {
                    self.demoStarted = enabled ? Date() : nil
                    self.demoStartedUptime = enabled ? ProcessInfo.processInfo.systemUptime : nil
                    self.changingMode = false
                    if enabled {
                        self.lyricsDiagnostic = "Test local : aucune requête réseau"
                        self.updateDemo()
                    } else { self.pollNowPlaying(force: true) }
                    self.reloadWidget()
                }
            }
        }
    }

    private func updateDemo() {
        guard let start = demoStartedUptime else { return }
        let position = min(30, max(0, ProcessInfo.processInfo.systemUptime - start))
        let playing = position < 30
        let demo = BridgeSnapshot(
            trackID: "lyricsdrive-diagnostic-test", title: "TEST LOCAL · 30 s", artist: "LyricsDrive v0.11 diagnostic",
            album: "", duration: 30, progressAtAnchor: position, anchorDate: Date(), isPlaying: playing,
            lines: [
                BridgeLyricLine(time: 0, text: "1/6 · Test démarré"),
                BridgeLyricLine(time: 5, text: "2/6 · Cinq secondes"),
                BridgeLyricLine(time: 10, text: "3/6 · Dix secondes"),
                BridgeLyricLine(time: 15, text: "4/6 · Quinze secondes"),
                BridgeLyricLine(time: 20, text: "5/6 · Vingt secondes"),
                BridgeLyricLine(time: 30, text: "6/6 · Test terminé")
            ], status: "Test local", playbackRate: playing ? 1 : 0, displayOffset: 0
        )
        snapshot = demo
        scheduleNextLine()
        publish(snapshot: demo, position: position)
    }

    func diagnosticReport(completion: @escaping (String) -> Void) {
        stateQueue.async {
            let now = Date()
            func age(_ date: Date?) -> String {
                date.map { String(format: "il y a %.1f s", max(0, now.timeIntervalSince($0))) } ?? "jamais"
            }
            let current = self.snapshot
            let uptime = ProcessInfo.processInfo.systemUptime
            let position = self.demoStartedUptime.map { min(30, max(0, uptime - $0)) }
                ?? self.playbackClock.position(at: uptime, duration: current?.duration ?? 0)
            let pair = current?.linePair(at: position)
            let report = """
            LyricsDrive v0.11 · DIAGNOSTIC
            Date : \(ISO8601DateFormatter().string(from: now))
            Mode : \(self.demoStarted == nil ? "Spotify réel" : "TEST LOCAL (Revenir à Spotify pour arrêter)")

            RÉCEPTION SPOTIFY
            Dernier relevé : \(age(self.lastPoll))
            Titre : \(current?.title ?? "absent")
            Artiste : \(current?.artist ?? "absent")
            Position brute : \(self.rawElapsed.map { String(format: "%.2f s", $0) } ?? "clé absente")
            Valeur brute modifiée : \(age(self.rawChangedAt))
            Vitesse brute : \(self.rawRate.map { String($0) } ?? "clé absente (dernière vitesse conservée)")
            Position calculée : \(String(format: "%.2f s", position))
            Lecture : \(current?.isPlaying == true ? "oui" : "non")
            Vitesse retenue : \(String(format: "%.2f", self.playbackClock.rate))
            Horloge : \(self.playbackClock.diagnostic)
            Correction dernière ancre (seek compris) : \(self.playbackClock.lastAnchorCorrection.map { String(format: "%+.3f s", $0) } ?? "aucune")
            Correction maximale (seek compris) : \(String(format: "%.3f s", self.playbackClock.maxAnchorCorrection))

            PAROLES
            \(self.lyricsDiagnostic)
            Lignes : \(current?.lines.count ?? 0)
            Phrase calculée : \(pair?.0 ?? "aucune")
            Phrase suivante : \(pair?.1 ?? "aucune")
            Décalage affichage : \(Int(self.displayOffset * 1000)) ms (+ = paroles plus tôt)
            CarPlay Dashboard : Live Activity ActivityFamily.small
            Live Activity : phrase courante + suivante, envoyées par le processus audio Spotify
            Verrouillage : rendu piloté par iOS, à vérifier sur l’écran
            Relevés en arrière-plan : \(self.backgroundPolls)
            Plus grand intervalle entre relevés : \(String(format: "%.2f s", self.maxPollGap))
            Dernier relevé arrière-plan : \(age(self.lastBackgroundSampleAt))
            Échantillon arrière-plan conservé : \(self.lastBackgroundSample)
            Clés arrière-plan conservées : \(self.lastBackgroundKeys)
            Échéances phrases : \(self.lineTimerFirings) total · \(self.backgroundLineFirings) arrière-plan
            Retard maximal du minuteur : \(String(format: "%.1f ms", self.maxLineTimerDelay * 1000))
            Prochaine phrase dans : \(self.nextLineUptime.map { String(format: "%.3f s", max(0, $0 - uptime)) } ?? "aucune")
            Dernière resynchronisation : \(self.lastResynchronisation)
            Ces écarts mesurent l’horloge et le minuteur, pas le rendu ni le retard audio réel.

            WIDGET
            Serveur : \(self.serverDiagnostic)
            Rechargement demandé : \(age(self.reloadRequested))
            Requête reçue : \(age(self.lastWidgetRequest))
            Accusé de réception : \(age(self.lastWidgetAck))
            Résultat : \(self.widgetDiagnostic)
            Une timeline fournie ne confirme pas son rendu par iOS.

            CLÉS NOW PLAYING
            \(self.lastNowPlayingKeys)

            JOURNAL DE SYNCHRONISATION (20 derniers événements, sans titre ni paroles)
            \(self.timingLog.joined(separator: "\n"))
            """
            Task {
                let activity = await self.liveActivity.report()
                await MainActor.run {
                    let active = UIApplication.shared.applicationState == .active
                    completion(report + "\n\nACTIVITÉ EN DIRECT\n" + activity + "\nApp active : " + (active ? "oui" : "non"))
                }
            }
        }
    }

    private func numeric(_ value: Any?) -> Double? {
        let number: Double?
        if let n = value as? NSNumber { number = n.doubleValue }
        else if let d = value as? Double { number = d }
        else if let i = value as? Int { number = Double(i) }
        else { number = nil }
        return number?.isFinite == true ? number : nil
    }

}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}
