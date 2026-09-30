#!/usr/bin/env python3
from pathlib import Path

root = Path(__import__("sys").argv[1])
custom = root / "Sources/EeveeSpotify/Lyrics/CustomLyrics.x.swift"

src = custom.read_text()

needle = '''    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
'''
insert = '''    lyricsState.loadedSuccessfully = true

    let lyricsDriveTrack = nowPlayingScrollViewController?.loadedTrack
    let lyricsDriveTitle = lyricsDriveTrack?.trackTitle() ?? searchQuery.title
    let lyricsDriveArtist: String = {
        if let track = lyricsDriveTrack {
            return EeveeSpotify.hookTarget == .lastAvailableiOS14
                ? track.artistTitle()
                : track.artistName()
        }
        return searchQuery.primaryArtist
    }()
    let lyricsDriveTrackID = lyricsDriveTrack?.URI().spt_trackIdentifier() ?? searchQuery.spotifyTrackId

    let lyricsDriveLines: [[String: Any]] = lyricsDto.lines.map { line in
        [
            "content": line.content,
            "offsetMs": line.offsetMs ?? -1
        ]
    }

    NotificationCenter.default.post(
        name: Notification.Name("LyricsDrive.EeveeLyricsLoaded"),
        object: nil,
        userInfo: [
            "trackId": lyricsDriveTrackID,
            "title": lyricsDriveTitle,
            "artist": lyricsDriveArtist,
            "source": source.description,
            "timeSynced": lyricsDto.timeSynced,
            "lines": lyricsDriveLines
        ]
    )

    let lyrics = Lyrics.with {
'''

if needle not in src:
    raise SystemExit("Could not find lyrics publication insertion point")

src = src.replace(needle, insert, 1)
custom.write_text(src)
print("Patched", custom)
