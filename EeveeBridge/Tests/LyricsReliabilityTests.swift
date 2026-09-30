import Foundation

private final class StubProtocol: URLProtocol {
    struct Response {
        let code: Int
        let headers: [String: String]
        let body: Data
    }
    static let lock = NSLock()
    static var responses: [Response] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let response = Self.responses.removeFirst()
        Self.lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.code,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct LyricsReliabilityTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func fetch(_ fetcher: LyricsFetcher, _ lookup: LyricsLookup, attempt: Int) -> (LyricsFetchResult, String) {
        let done = DispatchSemaphore(value: 0)
        var result: (LyricsFetchResult, String)?
        fetcher.fetch(lookup, attempt: attempt) { outcome, diagnostic in
            result = (outcome, diagnostic)
            done.signal()
        }
        check(done.wait(timeout: .now() + 5) == .success, "URLSession completion timed out")
        return result!
    }

    static func main() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let fetcher = LyricsFetcher(session: session, jitter: { 0 })
        let track = LyricsLookup(title: "Track & Version", artist: "Artist", album: "Album", duration: 180)
        let body = Data(#"{"trackName":"Track & Version","artistName":"Artist","duration":180,"syncedLyrics":"[00:01.00]First\n[00:04.00]Next"}"#.utf8)
        // Four failures, then success: the v0.9 three-attempt dead end is gone.
        StubProtocol.responses = (0..<4).map { _ in
            StubProtocol.Response(code: 503, headers: ["Retry-After": "19"], body: Data("busy".utf8))
        } + [StubProtocol.Response(code: 200, headers: [:], body: body)]
        for attempt in 0..<4 {
            let (result, diagnostic) = fetch(fetcher, track, attempt: attempt)
            guard case .retry(let delay) = result else { fatalError("503 must remain retryable") }
            check(delay >= 19, "Retry-After must be respected")
            check(diagnostic.contains("503"), "Technical details must remain available in diagnostics")
        }
        let (success, _) = fetch(fetcher, track, attempt: 4)
        guard case .lyrics(let lines) = success else { fatalError("Recovery after fourth retry failed") }
        check(lines.count == 2 && lines[0].text == "First" && lines[1].time == 4, "Recovered synced lyrics weren't decoded")
        let url = StubProtocol.requests.last!.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        check(query.contains(URLQueryItem(name: "track_name", value: track.title)), "Metadata must be URL encoded")
        check(query.contains(URLQueryItem(name: "album_name", value: track.album)), "Version metadata lost")
        print("PASS: HTTP 503 beyond three attempts, Retry-After, recovery, encoded track metadata")

        StubProtocol.responses = [StubProtocol.Response(code: 404, headers: [:], body: Data())]
        let (missing, _) = fetch(fetcher, track, attempt: 0)
        guard case .unavailable(let status) = missing else { fatalError("404 isn't transient") }
        check(!status.contains("HTTP") && !status.contains("LRCLIB"), "Lyrics card exposed an HTTP error")
        check(LyricsRetryPolicy.isTransient(http: 429, error: nil), "429 should back off")
        check(!LyricsRetryPolicy.isTransient(http: nil, error: URLError(.cancelled)), "Cancelled work must stop")
        let now = Date(timeIntervalSince1970: 0)
        let dateDelay = LyricsRetryPolicy.delay(attempt: 0, retryAfter: "Thu, 01 Jan 1970 00:01:00 GMT", now: now, jitter: 0)
        check(dateDelay == 60, "HTTP-date Retry-After not respected")
        check(LyricsRetryPolicy.delay(attempt: 40, retryAfter: nil, now: now, jitter: 0) == 60,
              "Exponential backoff must stay bounded")
        print("PASS: safe user messages, cancelled requests, 429 and HTTP-date backoff")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-cache-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsCache(directory: directory)
        check(cache.save(lines, for: track), "Cache write failed")
        let relaunched = LyricsCache(directory: directory)
        check(relaunched.load(track) == lines, "Lyrics must survive relaunch without LRCLIB")
        check(!relaunched.save([], for: track), "An error/empty response must not overwrite good lyrics")
        check(LyricsCache(directory: directory).load(track) == lines, "Good lyrics were lost after failed lookup")
        let remix = LyricsLookup(title: track.title, artist: track.artist, album: track.album, duration: 240)
        check(relaunched.load(remix) == nil, "Cache reused a different duration/version")
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(track.cacheKey + ".json"))
        check(LyricsCache(directory: directory).load(track) == nil, "Corrupt entries must be rejected safely")
        print("PASS: persistent lyrics, offline reuse, failure preservation, version isolation, corrupt cache")

        let repeated = LRCParser.parse("[offset:100]\n[00:01.00][00:05.250]Repeated\n[00:04.000]\n[ar:Metadata]")
        check(repeated.count == 3, "Multiple LRC timestamps were lost")
        check(abs(repeated[0].time - 1.1) < 0.001 && abs(repeated[2].time - 5.35) < 0.001,
              "LRC fractions/offset aren't applied consistently")
        check(repeated[1].text == "♪", "Instrumental gap must clear the last phrase")
        print("PASS: repeated timestamps, fractions, sorted lyrics, instrumental gaps")
    }
}
