import Foundation
import SpotifyiOS

@MainActor
final class SpotifyClient: NSObject, ObservableObject, SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    struct PlaybackTrack: Equatable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let progress: TimeInterval
        let isPlaying: Bool
        let fetchedAt: Date
    }

    @Published private(set) var isAuthorized = false
    @Published private(set) var isConnected = false
    @Published private(set) var status = "Spotify non connecté"
    @Published private(set) var latestPlayback: PlaybackTrack?

    static let clientID = "dbf1a97d6f6a49188905872fcc6813d9"
    static let redirectURL = URL(string: "lyricsdrive://callback")!

    private let defaults = UserDefaults.standard

    private lazy var configuration: SPTConfiguration = {
        let config = SPTConfiguration(clientID: Self.clientID, redirectURL: Self.redirectURL)
        config.playURI = ""
        return config
    }()

    private lazy var appRemote: SPTAppRemote = {
        let remote = SPTAppRemote(configuration: configuration, logLevel: .error)
        remote.delegate = self
        if let token = storedAccessToken {
            remote.connectionParameters.accessToken = token
        }
        return remote
    }()

    private var storedAccessToken: String? {
        get { defaults.string(forKey: "spotify.appRemoteAccessToken") }
        set {
            defaults.set(newValue, forKey: "spotify.appRemoteAccessToken")
            isAuthorized = !(newValue?.isEmpty ?? true)
        }
    }

    override init() {
        super.init()
        isAuthorized = !(storedAccessToken?.isEmpty ?? true)
        status = isAuthorized ? "Spotify autorisé — connexion en attente" : "Spotify non connecté"
    }

    func authorize() {
        status = "Ouverture de Spotify…"
        appRemote.authorizeAndPlayURI("") { [weak self] spotifyInstalled in
            Task { @MainActor in
                guard let self else { return }
                if !spotifyInstalled {
                    self.status = "L’app Spotify doit être installée sur l’iPhone."
                }
            }
        }
    }

    @discardableResult
    func handleRedirectURL(_ url: URL) -> Bool {
        guard let parameters = appRemote.authorizationParameters(from: url) else {
            return false
        }

        if let token = parameters[SPTAppRemoteAccessTokenKey] {
            storedAccessToken = token
            appRemote.connectionParameters.accessToken = token
            status = "Autorisation Spotify reçue…"
            appRemote.connect()
            return true
        }

        if let errorDescription = parameters[SPTAppRemoteErrorDescriptionKey] {
            status = "Spotify : \(errorDescription)"
            return true
        }

        status = "Réponse Spotify invalide."
        return true
    }

    func reconnectIfPossible() {
        guard let token = storedAccessToken, !token.isEmpty else { return }
        appRemote.connectionParameters.accessToken = token
        if !appRemote.isConnected {
            status = "Connexion à Spotify…"
            appRemote.connect()
        }
    }

    func disconnectForBackground() {
        if appRemote.isConnected {
            appRemote.disconnect()
        }
    }

    func disconnect() {
        if appRemote.isConnected {
            appRemote.disconnect()
        }
        storedAccessToken = nil
        latestPlayback = nil
        isConnected = false
        isAuthorized = false
        status = "Spotify déconnecté"
    }

    func currentPlayback() async throws -> PlaybackTrack? {
        guard isAuthorized else {
            throw NSError(
                domain: "LyricsDrive",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Connecte d’abord LyricsDrive à Spotify."]
            )
        }

        guard appRemote.isConnected, let playerAPI = appRemote.playerAPI else {
            reconnectIfPossible()
            return latestPlayback
        }

        return try await withCheckedThrowingContinuation { continuation in
            playerAPI.getPlayerState { [weak self] result, error in
                Task { @MainActor in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let state = result as? SPTAppRemotePlayerState else {
                        continuation.resume(returning: self?.latestPlayback)
                        return
                    }

                    let playback = Self.makePlayback(from: state)
                    self?.latestPlayback = playback
                    continuation.resume(returning: playback)
                }
            }
        }
    }

    func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        isConnected = true
        isAuthorized = true
        status = "Spotify connecté via App Remote"

        appRemote.playerAPI?.delegate = self
        appRemote.playerAPI?.subscribe(toPlayerState: { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.status = "Abonnement Spotify : \(error.localizedDescription)"
                }
            }
        })

        appRemote.playerAPI?.getPlayerState { [weak self] result, _ in
            guard let state = result as? SPTAppRemotePlayerState else { return }
            Task { @MainActor in
                self?.latestPlayback = Self.makePlayback(from: state)
            }
        }
    }

    func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        isConnected = false
        status = error.map { "Connexion Spotify impossible : \($0.localizedDescription)" }
            ?? "Connexion Spotify impossible."
    }

    func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        isConnected = false
        if let error {
            status = "Spotify déconnecté : \(error.localizedDescription)"
        } else if isAuthorized {
            status = "Spotify en arrière-plan — reconnexion au retour"
        }
    }

    func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        latestPlayback = Self.makePlayback(from: playerState)
    }

    private static func makePlayback(from state: SPTAppRemotePlayerState) -> PlaybackTrack {
        let track = state.track
        return PlaybackTrack(
            id: track.uri,
            title: track.name,
            artist: track.artist.name,
            album: track.album.name,
            duration: Double(track.duration) / 1000.0,
            progress: Double(state.playbackPosition) / 1000.0,
            isPlaying: !state.isPaused,
            fetchedAt: Date()
        )
    }
}
