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
    private var diagnostic = "Pas encore démarrée"
    private var lastSubmitted: Date?

    func report() -> String {
        diagnostic + (lastSubmitted.map { " · dernier envoi " + ISO8601DateFormatter().string(from: $0) } ?? "")
    }

    func ensureStarted(snapshot: BridgeSnapshot, appIsActive: Bool) async {
        if let current = activity {
            if current.activityState == .dismissed || current.activityState == .ended {
                activity = nil
                diagnostic = "Activité terminée par iOS ou l’utilisateur"
            } else { return }
        }
        guard appIsActive else { diagnostic = "Démarrage en attente : ouvrir Spotify"; return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            diagnostic = "Activités en direct désactivées dans iOS"; return
        }
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
            diagnostic = "Créée (affichage à vérifier sur l’écran)"
        } catch {
            diagnostic = "Échec création : \(error.localizedDescription)"
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
        let nextFingerprint = "\(snapshot.trackID)|\(pair.0)|\(pair.1)|\(snapshot.isPlaying)"

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
        lastSubmitted = Date()
        diagnostic = "Mise à jour transmise à ActivityKit (rendu non confirmé)"
    }

    func stop() async {
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        fingerprint = ""
        lastAttempt = .distantPast
        diagnostic = "Arrêtée"
        lastSubmitted = nil
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


    private init() {}

    func start() {
        stateQueue.async {
            guard !self.started else { return }
            self.started = true
            self.startServer()
            self.startPolling()
            DispatchQueue.main.async { BridgeDiagnosticsUI.shared.install() }
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
        lastPoll = Date()
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

        let artist = (info[MPMediaItemPropertyArtist] as? String) ?? ""
        let album = (info[MPMediaItemPropertyAlbumTitle] as? String) ?? ""
        let duration = numeric(info[MPMediaItemPropertyPlaybackDuration]) ?? 0
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

            Task {
                let active = await MainActor.run { UIApplication.shared.applicationState == .active }
                await liveActivity.restart(snapshot: fresh, appIsActive: active)
                await liveActivity.update(snapshot: fresh, position: fresh.progressAtAnchor)
            }

            fetchLyrics(title: title, artist: artist, duration: duration, trackID: trackID, generation: generation)
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
        lyricsGeneration = UUID()
        lastRawTrackID = nil
        playbackClock = PlaybackClock()
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
        lyricsDiagnostic = "Requête LRCLIB en cours"
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
        request.setValue("LyricsDrive-EeveeBridge/0.7-dashboard", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            self.stateQueue.async {
                guard generation == self.lyricsGeneration, trackID == self.lastRawTrackID else { return }

                let httpCode = (response as? HTTPURLResponse)?.statusCode
                self.lyricsDiagnostic = error.map { "Réseau : " + $0.localizedDescription }
                    ?? "HTTP \(httpCode.map(String.init) ?? "absent") · \(data?.count ?? 0) octets"
                if let data,
                   let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
                   let raw = decoded.syncedLyrics,
                   !raw.isEmpty {
                    let lines = Self.parseLRC(raw)
                    if !lines.isEmpty {
                        self.lyricsDiagnostic += " · \(lines.count) lignes · première \(lines.first!.time)s · dernière \(lines.last!.time)s"
                        self.applyLyrics(lines, status: "Paroles synchronisées", generation: generation)
                        return
                    }
                }

                let status: String
                if error != nil { status = "LRCLIB : erreur réseau" }
                else if httpCode == 404 { status = "Paroles introuvables" }
                else if let code = httpCode, !(200..<300).contains(code) { status = "LRCLIB : HTTP \(code)" }
                else { status = "Aucune parole synchronisée exploitable" }
                self.applyLyrics([], status: status, generation: generation)
            }
        }.resume()
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


        Task {
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            await liveActivity.ensureStarted(snapshot: updated, appIsActive: active)
            await liveActivity.update(snapshot: updated, position: stablePosition)
        }
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
            self.lyricsGeneration = UUID()
            self.snapshot = nil
            self.lastRawTrackID = nil
            Task {
                await self.liveActivity.stop()
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
            trackID: "lyricsdrive-diagnostic-test", title: "TEST LOCAL · 30 s", artist: "LyricsDrive v0.7 diagnostic",
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
        Task {
            let active = await MainActor.run { UIApplication.shared.applicationState == .active }
            await liveActivity.ensureStarted(snapshot: demo, appIsActive: active)
            await liveActivity.update(snapshot: demo, position: position)
        }
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
            LyricsDrive v0.7 · DIAGNOSTIC
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
