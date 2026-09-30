import ActivityKit
import Foundation
import MediaPlayer
import Network
import UIKit
import WidgetKit

private enum LyricsTiming {
    static let displayLead: TimeInterval = 0.45
}

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

    func linePair(at position: TimeInterval) -> (String, String) {
        guard !lines.isEmpty else { return (status, "") }

        let displayPosition = max(0, position + LyricsTiming.displayLead)
        var low = 0
        var high = lines.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= displayPosition {
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

private actor LyricsLiveActivityController {
    private struct Submission {
        let snapshot: BridgeSnapshot
        let position: TimeInterval
        let issuedAt: Date
        let sequence: Int
    }

    private var activity: Activity<LyricsActivityAttributes>?
    private var lastState: LyricsLiveState?
    private var lastAttempt = Date.distantPast
    private var diagnostic = "Pas encore démarrée"
    private var lastSubmitted: Date?
    private var pending: Submission?
    private var processing = false
    private var latestSequence = 0
    private var epoch = 0
    private var foregroundUpdates = 0
    private var backgroundUpdates = 0
    private var payloadBytes = 0

    func report() -> String {
        let state = activity.map { String(describing: $0.activityState) } ?? "absente"
        return diagnostic
            + (lastSubmitted.map { " · dernier envoi " + ISO8601DateFormatter().string(from: $0) } ?? "")
            + "\nÉtat ActivityKit : " + state
            + "\nEnvois terminés : \(foregroundUpdates) premier plan · \(backgroundUpdates) arrière-plan"
            + "\nÉtat + attributs : \(payloadBytes) octets (limite 4 Ko)"
            + "\nUn envoi terminé ne confirme pas le rendu par iOS."
    }

    /// Coalesce pending work while ActivityKit awaits; an older track can never overtake a newer one.
    func submit(snapshot: BridgeSnapshot, position: TimeInterval, issuedAt: Date, sequence: Int) async {
        guard sequence > latestSequence else { return }
        latestSequence = sequence
        pending = Submission(snapshot: snapshot, position: position, issuedAt: issuedAt, sequence: sequence)
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
        let elapsed = snapshot.isPlaying ? max(0, Date().timeIntervalSince(submission.issuedAt)) : 0
        let position = min(snapshot.duration > 0 ? snapshot.duration : .greatestFiniteMagnitude,
                           max(0, submission.position + elapsed))
        let pair = snapshot.linePair(at: position)
        let state = LyricsLiveState(
            trackID: snapshot.trackID, title: snapshot.title, artist: snapshot.artist,
            currentLine: pair.0, nextLine: pair.1,
            progress: snapshot.duration > 0 ? min(1, position / snapshot.duration) : 0,
            isPlaying: snapshot.isPlaying, anchorDate: Date(), positionAtAnchor: position,
            duration: snapshot.duration
        ).bounded(attributesBytes: attributesBytes)
        payloadBytes = ((try? JSONEncoder().encode(state).count) ?? 0) + attributesBytes
        guard payloadBytes <= 3_500 else {
            diagnostic = "État trop volumineux · envoi annulé"
            return
        }
        guard state.needsPublication(comparedTo: lastState, at: Date()) else { return }
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
        await activity.update(content)
        await lease.finish()
        guard submissionEpoch == epoch else { return }
        lastState = state
        lastSubmitted = Date()
        if appIsActive { foregroundUpdates += 1 } else { backgroundUpdates += 1 }
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
    private var server: NWListener?
    private var snapshot: BridgeSnapshot?
    private var lastRawTrackID: String?
    private var lyricsGeneration = UUID()
    private var playbackClock = PlaybackClock()
    private var started = false
    private var changingMode = false
    private var demoStarted: Date?
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
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
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
        let receivedAt = Date()
        if let lastPoll { maxPollGap = max(maxPollGap, receivedAt.timeIntervalSince(lastPoll)) }
        lastPoll = receivedAt
        if backgroundEnteredAt != nil { backgroundPolls += 1 }
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
        let rate = numeric(info[MPNowPlayingInfoPropertyPlaybackRate]) ?? 0
        let isPlaying = rate > 0.001

        let externalID = info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String
        let trackID = externalID?.isEmpty == false
            ? externalID!
            : "\(title)|\(artist)|\(Int(duration.rounded()))"

        if trackID != lastRawTrackID {
            lastRawTrackID = trackID
            playbackClock.reset(elapsed: elapsed, isPlaying: isPlaying, now: ProcessInfo.processInfo.systemUptime)
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
                isPlaying: isPlaying,
                lines: [],
                status: "Recherche des paroles…"
            )
            snapshot = fresh
            reloadWidget()

            publish(snapshot: fresh, position: fresh.progressAtAnchor)
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
        let reanchored = playbackClock.consume(elapsed: elapsed, isPlaying: isPlaying, now: uptime, duration: duration)
        let estimated = playbackClock.position(at: uptime, duration: duration)

        if reanchored {
            current = BridgeSnapshot(
                trackID: current.trackID,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                progressAtAnchor: estimated,
                anchorDate: now,
                isPlaying: isPlaying,
                lines: current.lines,
                status: current.lines.isEmpty ? current.status : "Paroles synchronisées"
            )
            snapshot = current
            reloadWidget()
        }

        if let latest = snapshot {
            publish(snapshot: latest, position: estimated)
        }
    }

    @MainActor
    private func observeLifecycle() {
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification] {
            lifecycleObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let self else { return }
                let background = UIApplication.shared.applicationState != .active
                self.stateQueue.async {
                    if background && self.backgroundEnteredAt == nil {
                        self.backgroundEnteredAt = Date()
                        self.backgroundPolls = 0
                        self.maxPollGap = 0
                    } else if !background { self.backgroundEnteredAt = nil }
                    self.pollNowPlaying()
                }
            })
        }
    }

    private func publish(snapshot: BridgeSnapshot, position: TimeInterval) {
        publicationSequence += 1
        let sequence = publicationSequence
        let issuedAt = Date()
        Task { await liveActivity.submit(snapshot: snapshot, position: position, issuedAt: issuedAt, sequence: sequence) }
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
                        self.applyLyrics([], status: "Chargement des paroles…", generation: generation)
                    }
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self, generation == self.lyricsGeneration, trackID == self.lastRawTrackID else { return }
                        self.fetchLyrics(lookup: lookup, trackID: trackID, generation: generation, attempt: attempt + 1)
                    }
                    self.lyricsRetry = retry
                    self.stateQueue.asyncAfter(deadline: .now() + delay, execute: retry)
                case .unavailable(let status):
                    if self.snapshot?.lines.isEmpty != false {
                        self.applyLyrics([], status: status, generation: generation)
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
            status: status
        )
        snapshot = updated
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
                    self.changingMode = false
                    if enabled {
                        self.lyricsDiagnostic = "Test local : aucune requête réseau"
                        self.updateDemo()
                    }
                    self.reloadWidget()
                }
            }
        }
    }

    private func updateDemo() {
        guard let start = demoStarted else { return }
        let position = min(30, max(0, Date().timeIntervalSince(start)))
        let demo = BridgeSnapshot(
            trackID: "lyricsdrive-diagnostic-test", title: "TEST LOCAL · 30 s", artist: "LyricsDrive v0.10 diagnostic",
            album: "", duration: 30, progressAtAnchor: 0, anchorDate: start, isPlaying: true,
            lines: [
                BridgeLyricLine(time: 0, text: "1/6 · Test démarré"),
                BridgeLyricLine(time: 5, text: "2/6 · Cinq secondes"),
                BridgeLyricLine(time: 10, text: "3/6 · Dix secondes"),
                BridgeLyricLine(time: 15, text: "4/6 · Quinze secondes"),
                BridgeLyricLine(time: 20, text: "5/6 · Vingt secondes"),
                BridgeLyricLine(time: 30, text: "6/6 · Test terminé")
            ], status: "Test local"
        )
        snapshot = demo
        publish(snapshot: demo, position: position)
    }

    func diagnosticReport(completion: @escaping (String) -> Void) {
        stateQueue.async {
            let now = Date()
            func age(_ date: Date?) -> String {
                date.map { String(format: "il y a %.1f s", max(0, now.timeIntervalSince($0))) } ?? "jamais"
            }
            let current = self.snapshot
            let position = current.map { min($0.duration > 0 ? $0.duration : .greatestFiniteMagnitude,
                $0.progressAtAnchor + ($0.isPlaying ? max(0, now.timeIntervalSince($0.anchorDate)) : 0)) } ?? 0
            let pair = current?.linePair(at: position)
            let report = """
            LyricsDrive v0.10 · DIAGNOSTIC
            Date : \(ISO8601DateFormatter().string(from: now))
            Mode : \(self.demoStarted == nil ? "Spotify réel" : "TEST LOCAL (Revenir à Spotify pour arrêter)")

            RÉCEPTION SPOTIFY
            Dernier relevé : \(age(self.lastPoll))
            Titre : \(current?.title ?? "absent")
            Artiste : \(current?.artist ?? "absent")
            Position brute : \(self.rawElapsed.map { String(format: "%.2f s", $0) } ?? "clé absente")
            Valeur brute modifiée : \(age(self.rawChangedAt))
            Vitesse brute : \(self.rawRate.map { String($0) } ?? "clé absente (interprétée comme pause)")
            Position calculée : \(String(format: "%.2f s", position))
            Lecture : \(current?.isPlaying == true ? "oui" : "non")
            Horloge : \(self.playbackClock.diagnostic)

            PAROLES
            \(self.lyricsDiagnostic)
            Lignes : \(current?.lines.count ?? 0)
            Phrase calculée : \(pair?.0 ?? "aucune")
            Phrase suivante : \(pair?.1 ?? "aucune")
            Avance affichage : \(String(format: "%.2f s", LyricsTiming.displayLead))
            CarPlay Dashboard : Live Activity ActivityFamily.small
            Live Activity : phrase courante + suivante, envoyées par le processus audio Spotify
            Verrouillage : rendu piloté par iOS, à vérifier sur l’écran
            Relevés en arrière-plan : \(self.backgroundPolls)
            Plus grand intervalle entre relevés : \(String(format: "%.2f s", self.maxPollGap))

            WIDGET
            Serveur : \(self.serverDiagnostic)
            Rechargement demandé : \(age(self.reloadRequested))
            Requête reçue : \(age(self.lastWidgetRequest))
            Accusé de réception : \(age(self.lastWidgetAck))
            Résultat : \(self.widgetDiagnostic)
            Une timeline fournie ne confirme pas son rendu par iOS.

            CLÉS NOW PLAYING
            \(self.lastNowPlayingKeys)
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
