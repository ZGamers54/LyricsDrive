import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class SpotifyClient: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
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

    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let scope: String?
        let expires_in: Int
        let refresh_token: String?
    }

    private struct PlaybackResponse: Decodable {
        struct Item: Decodable {
            struct Artist: Decodable { let name: String }
            struct Album: Decodable { let name: String }
            let id: String
            let name: String
            let artists: [Artist]
            let album: Album
            let duration_ms: Int
        }
        let progress_ms: Int?
        let is_playing: Bool
        let item: Item?
    }

    @Published var isAuthorized = false
    @Published var status = "Spotify non connecté"

    private let defaults = UserDefaults.standard
    private let redirectURI = "lyricsdrive://callback"
    private let callbackScheme = "lyricsdrive"
    private var authSession: ASWebAuthenticationSession?

    private var accessToken: String? {
        get { defaults.string(forKey: "spotify.accessToken") }
        set { defaults.set(newValue, forKey: "spotify.accessToken") }
    }
    private var refreshToken: String? {
        get { defaults.string(forKey: "spotify.refreshToken") }
        set { defaults.set(newValue, forKey: "spotify.refreshToken") }
    }
    private var expiryDate: Date? {
        get { defaults.object(forKey: "spotify.expiryDate") as? Date }
        set { defaults.set(newValue, forKey: "spotify.expiryDate") }
    }
    private var clientID: String {
        get { defaults.string(forKey: "spotify.clientID") ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "spotify.clientID") }
    }

    override init() {
        super.init()
        isAuthorized = accessToken != nil || refreshToken != nil
        status = isAuthorized ? "Spotify connecté" : "Spotify non connecté"
    }

    func savedClientID() -> String { clientID }
    func saveClientID(_ value: String) { clientID = value }

    func disconnect() {
        accessToken = nil
        refreshToken = nil
        expiryDate = nil
        isAuthorized = false
        status = "Spotify déconnecté"
    }

    func authorize() async throws {
        guard !clientID.isEmpty else {
            throw NSError(domain: "LyricsDrive", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ajoute d'abord ton Spotify Client ID."])
        }

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafeString(length: 24)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "user-read-currently-playing user-read-playback-state"),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state)
        ]
        guard let authURL = components.url else { throw URLError(.badURL) }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: callbackScheme) { [weak self] url, error in
                self?.authSession = nil
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                continuation.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            if !session.start() {
                self.authSession = nil
                continuation.resume(throwing: URLError(.cannotConnectToHost))
            }
        }

        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw NSError(domain: "LyricsDrive", code: 2, userInfo: [NSLocalizedDescriptionKey: "État OAuth Spotify invalide."])
        }
        if let err = items.first(where: { $0.name == "error" })?.value {
            throw NSError(domain: "LyricsDrive", code: 3, userInfo: [NSLocalizedDescriptionKey: "Spotify: \(err)"])
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw NSError(domain: "LyricsDrive", code: 4, userInfo: [NSLocalizedDescriptionKey: "Code Spotify manquant."])
        }

        try await exchange(code: code, verifier: verifier)
        isAuthorized = true
        status = "Spotify connecté"
    }

    func currentPlayback() async throws -> PlaybackTrack? {
        try await ensureValidToken()
        guard let token = accessToken else { return nil }
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 204 { return nil }
        if http.statusCode == 401 {
            accessToken = nil
            try await ensureValidToken(forceRefresh: true)
            return try await currentPlayback()
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "LyricsDrive", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Spotify HTTP \(http.statusCode)"])
        }
        let payload = try JSONDecoder().decode(PlaybackResponse.self, from: data)
        guard let item = payload.item else { return nil }
        return PlaybackTrack(
            id: item.id,
            title: item.name,
            artist: item.artists.map(\.name).joined(separator: ", "),
            album: item.album.name,
            duration: Double(item.duration_ms) / 1000.0,
            progress: Double(payload.progress_ms ?? 0) / 1000.0,
            isPlaying: payload.is_playing,
            fetchedAt: Date()
        )
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }

    private func exchange(code: String, verifier: String) async throws {
        let body = [
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        let token = try await tokenRequest(body)
        store(token)
    }

    private func ensureValidToken(forceRefresh: Bool = false) async throws {
        if !forceRefresh, let accessToken, !accessToken.isEmpty,
           let expiryDate, expiryDate > Date().addingTimeInterval(60) { return }
        guard let refreshToken, !refreshToken.isEmpty else {
            isAuthorized = false
            throw NSError(domain: "LyricsDrive", code: 5, userInfo: [NSLocalizedDescriptionKey: "Reconnecte Spotify."])
        }
        let body = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        let token = try await tokenRequest(body)
        store(token)
    }

    private func tokenRequest(_ body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { key, value in
            "\(Self.formEncode(key))=\(Self.formEncode(value))"
        }.sorted().joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Erreur OAuth Spotify"
            throw NSError(domain: "LyricsDrive", code: 6, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(_ token: TokenResponse) {
        accessToken = token.access_token
        if let newRefresh = token.refresh_token { refreshToken = newRefresh }
        expiryDate = Date().addingTimeInterval(TimeInterval(token.expires_in))
        isAuthorized = true
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
