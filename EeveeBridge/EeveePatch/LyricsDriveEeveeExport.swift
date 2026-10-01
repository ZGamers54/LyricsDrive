import Foundation
import Darwin

private struct LyricsDriveExportLine: Codable {
    let text: String
    let offsetMs: Int
}

private struct LyricsDriveExportPayload: Codable {
    let trackId: String
    let title: String
    let artist: String
    let source: String
    let timeSynced: Bool
    let lines: [LyricsDriveExportLine]
}

private typealias LyricsDrivePublishFn = @convention(c) (UnsafePointer<CChar>?) -> Void

func publishLyricsToLyricsDrive(
    trackId: String,
    title: String,
    artist: String,
    source: LyricsSource,
    lyrics: LyricsDto
) {
    guard lyrics.timeSynced else { return }

    let exportedLines = lyrics.lines.compactMap { line -> LyricsDriveExportLine? in
        guard let offset = line.offsetMs else { return nil }
        let text = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LyricsDriveExportLine(text: text, offsetMs: offset)
    }

    guard !exportedLines.isEmpty else { return }

    let payload = LyricsDriveExportPayload(
        trackId: trackId,
        title: title,
        artist: artist,
        source: source.description,
        timeSynced: lyrics.timeSynced,
        lines: exportedLines
    )

    guard let data = try? JSONEncoder().encode(payload),
          let json = String(data: data, encoding: .utf8) else {
        return
    }

    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LyricsDriveBridgePublishLyricsJSON") else {
        return
    }

    let publish = unsafeBitCast(symbol, to: LyricsDrivePublishFn.self)
    json.withCString { cString in
        publish(cString)
    }
}
