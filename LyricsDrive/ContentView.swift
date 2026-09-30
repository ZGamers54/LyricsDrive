import SwiftUI
import WidgetKit

struct ContentView: View {
    @StateObject private var spotify = SpotifyClient()
    @StateObject private var liveActivity = LiveActivityManager()
    @State private var clientID = ""
    @State private var message = "Prêt"
    @State private var currentTrack: SpotifyClient.PlaybackTrack?
    @State private var lyrics: LyricsTrack?
    @State private var monitorTask: Task<Void, Never>?
    @State private var currentLine = "—"
    @State private var nextLine = ""

    private let lrclib = LRCLibClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Spotify") {
                    TextField("Spotify Client ID", text: $clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Redirect URI à enregistrer dans Spotify Developer Dashboard : lyricsdrive://callback")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if spotify.isAuthorized {
                        Button("Déconnecter Spotify", role: .destructive) {
                            spotify.disconnect()
                            stopMonitoring()
                        }
                    } else {
                        Button("Connecter Spotify") {
                            spotify.saveClientID(clientID)
                            Task {
                                do {
                                    try await spotify.authorize()
                                    message = "Spotify connecté."
                                } catch {
                                    message = error.localizedDescription
                                }
                            }
                        }
                    }
                }

                Section("Lecture") {
                    if let track = currentTrack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(.headline)
                            Text(track.artist).foregroundStyle(.secondary)
                            Text(currentLine).font(.title3).bold().padding(.top, 6)
                            if !nextLine.isEmpty {
                                Text(nextLine).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("Aucun morceau détecté")
                            .foregroundStyle(.secondary)
                    }

                    Button(monitorTask == nil ? "Démarrer LyricsDrive" : "Arrêter LyricsDrive") {
                        if monitorTask == nil { startMonitoring() } else { stopMonitoring() }
                    }
                    .disabled(!spotify.isAuthorized)
                }

                Section("CarPlay") {
                    Label("Widget WidgetKit systemSmall", systemImage: "car.side")
                    Label("Live Activity pour la synchro fine", systemImage: "waveform")
                    Text("Dans CarPlay, ajoute LyricsDrive depuis l’écran Widgets. Le widget pré-calculera les changements de lignes ; la Live Activity reste utilisée en parallèle car iOS peut décaler les rafraîchissements WidgetKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("État") {
                    Text(message)
                }
            }
            .navigationTitle("LyricsDrive")
            .onAppear { clientID = spotify.savedClientID() }
        }
    }

    private func startMonitoring() {
        guard monitorTask == nil else { return }
        message = "Surveillance Spotify…"

        monitorTask = Task {
            var lastTrackID: String?
            var anchor: SpotifyClient.PlaybackTrack?
            var loadedLyrics: LyricsTrack?
            var lastSpotifyRefresh = Date.distantPast
            var widgetTrackID: String?
            var widgetAnchorDate = Date.distantPast
            var widgetAnchorProgress: TimeInterval = 0
            var widgetWasPlaying = false
            var widgetHadPlayback = false
            var lastActivityFingerprint = ""

            while !Task.isCancelled {
                do {
                    if Date().timeIntervalSince(lastSpotifyRefresh) >= 4 || anchor == nil {
                        if let playback = try await spotify.currentPlayback() {
                            currentTrack = playback
                            anchor = playback
                            lastSpotifyRefresh = Date()
                            widgetHadPlayback = true

                            if playback.id != lastTrackID {
                                lastTrackID = playback.id
                                message = "Recherche des paroles…"

                                var lyricsError: String?
                                do {
                                    loadedLyrics = try await lrclib.fetch(
                                        title: playback.title,
                                        artist: playback.artist,
                                        duration: playback.duration
                                    )
                                    lyrics = loadedLyrics
                                } catch {
                                    loadedLyrics = nil
                                    lyrics = nil
                                    lyricsError = error.localizedDescription
                                }

                                if let loadedLyrics,
                                   let index = loadedLyrics.lineIndex(at: playback.progress) {
                                    currentLine = loadedLyrics.lines[index].text
                                    nextLine = index + 1 < loadedLyrics.lines.count ? loadedLyrics.lines[index + 1].text : ""
                                } else if let loadedLyrics {
                                    currentLine = "♪"
                                    nextLine = loadedLyrics.lines.first?.text ?? ""
                                } else {
                                    currentLine = "Paroles synchronisées introuvables"
                                    nextLine = ""
                                }

                                var activityStarted = false
                                do {
                                    try await liveActivity.start(
                                        title: playback.title,
                                        artist: playback.artist,
                                        currentLine: currentLine
                                    )
                                    activityStarted = true
                                } catch {
                                    activityStarted = false
                                }
                                lastActivityFingerprint = ""

                                publishWidget(
                                    playback: playback,
                                    lyrics: loadedLyrics,
                                    fallback: loadedLyrics == nil ? currentLine : nil
                                )
                                widgetTrackID = playback.id
                                widgetAnchorDate = playback.fetchedAt
                                widgetAnchorProgress = playback.progress
                                widgetWasPlaying = playback.isPlaying

                                if let lyricsError {
                                    message = lyricsError + (activityStarted ? "" : " • Live Activity indisponible")
                                } else {
                                    message = activityStarted
                                        ? "Widget CarPlay + Live Activity actifs."
                                        : "Widget CarPlay actif. Live Activity indisponible."
                                }
                            } else if widgetTrackID == playback.id {
                                let expectedPosition: TimeInterval
                                if widgetWasPlaying {
                                    expectedPosition = widgetAnchorProgress + max(0, playback.fetchedAt.timeIntervalSince(widgetAnchorDate))
                                } else {
                                    expectedPosition = widgetAnchorProgress
                                }
                                let drift = abs(expectedPosition - playback.progress)
                                let transportChanged = widgetWasPlaying != playback.isPlaying

                                if drift > 2.5 || transportChanged {
                                    publishWidget(
                                        playback: playback,
                                        lyrics: loadedLyrics,
                                        fallback: loadedLyrics == nil ? "Paroles synchronisées introuvables" : nil
                                    )
                                    widgetAnchorDate = playback.fetchedAt
                                    widgetAnchorProgress = playback.progress
                                    widgetWasPlaying = playback.isPlaying
                                }
                            }
                        } else {
                            currentTrack = nil
                            currentLine = "Aucune lecture Spotify"
                            nextLine = ""
                            anchor = nil
                            loadedLyrics = nil
                            lastTrackID = nil

                            if widgetHadPlayback {
                                SharedLyricsStore.clear()
                                WidgetCenter.shared.reloadTimelines(ofKind: LyricsDriveWidgetConstants.kind)
                                await liveActivity.stop()
                                lastActivityFingerprint = ""
                                widgetHadPlayback = false
                                widgetTrackID = nil
                            }
                        }
                    }

                    if let playback = anchor {
                        let elapsed = playback.isPlaying ? Date().timeIntervalSince(playback.fetchedAt) : 0
                        let position = min(playback.duration, max(0, playback.progress + elapsed))
                        let progress = playback.duration > 0 ? position / playback.duration : 0

                        if let loadedLyrics, let index = loadedLyrics.lineIndex(at: position) {
                            currentLine = loadedLyrics.lines[index].text
                            nextLine = index + 1 < loadedLyrics.lines.count ? loadedLyrics.lines[index + 1].text : ""
                        } else if loadedLyrics != nil {
                            currentLine = "♪"
                            nextLine = loadedLyrics?.lines.first?.text ?? ""
                        }

                        // ActivityKit updates are intentionally throttled. A new state is sent
                        // for lyric/transport changes, plus coarse 5% progress milestones.
                        let progressBucket = Int(progress * 20)
                        let fingerprint = "\(playback.id)|\(currentLine)|\(nextLine)|\(playback.isPlaying)|\(progressBucket)"
                        if fingerprint != lastActivityFingerprint {
                            await liveActivity.update(
                                title: playback.title,
                                artist: playback.artist,
                                currentLine: currentLine,
                                nextLine: nextLine,
                                progress: progress,
                                isPlaying: playback.isPlaying
                            )
                            lastActivityFingerprint = fingerprint
                        }
                    }
                } catch {
                    message = error.localizedDescription
                }

                try? await Task.sleep(for: .milliseconds(750))
            }
        }
    }

    private func publishWidget(
        playback: SpotifyClient.PlaybackTrack,
        lyrics: LyricsTrack?,
        fallback: String?
    ) {
        let payload = SharedLyricsPayload(
            trackID: playback.id,
            title: playback.title,
            artist: playback.artist,
            album: playback.album,
            duration: playback.duration,
            progressAtAnchor: playback.progress,
            anchorDate: playback.fetchedAt,
            isPlaying: playback.isPlaying,
            lines: lyrics?.lines.map { SharedLyricLine(time: $0.time, text: $0.text) } ?? [],
            fallbackMessage: fallback
        )
        SharedLyricsStore.save(payload)
        WidgetCenter.shared.reloadTimelines(ofKind: LyricsDriveWidgetConstants.kind)
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        Task { await liveActivity.stop() }
        SharedLyricsStore.clear()
        WidgetCenter.shared.reloadTimelines(ofKind: LyricsDriveWidgetConstants.kind)
        currentTrack = nil
        lyrics = nil
        currentLine = "—"
        nextLine = ""
        message = "Arrêté"
    }
}
