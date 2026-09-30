#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "upstream-eevee"
custom = root / "Sources/EeveeSpotify/Lyrics/CustomLyrics.x.swift"

text = custom.read_text()

needle1 = '''    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
'''

replacement1 = '''    lyricsState.loadedSuccessfully = true

    if let title = currentTitle, let artist = currentArtist {
        publishLyricsToLyricsDrive(
            trackId: trackId,
            title: title,
            artist: artist,
            source: source,
            lyrics: lyricsDto
        )
    }

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
'''

if needle1 not in text:
    raise SystemExit("Could not patch loadCustomLyricsForTrackId")
text = text.replace(needle1, replacement1, 1)

needle2 = '''    lyricsState.loadedSuccessfully = true

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}
'''

replacement2 = '''    lyricsState.loadedSuccessfully = true

    publishLyricsToLyricsDrive(
        trackId: track.trackIdentifier,
        title: trackTitle,
        artist: artistName,
        source: source,
        lyrics: lyricsDto
    )

    let lyrics = Lyrics.with {
        $0.data = lyricsDto.toSpotifyLyricsData(source: source.description)
    }
    
    return lyrics
}
'''

if needle2 not in text:
    raise SystemExit("Could not patch loadCustomLyricsForCurrentTrack")
text = text.replace(needle2, replacement2, 1)

custom.write_text(text)

bridge_src = Path(__file__).resolve().parent / "LyricsDriveEeveeExport.swift"
dst = root / "Sources/EeveeSpotify/Lyrics/LyricsDriveEeveeExport.swift"
dst.write_text(bridge_src.read_text())

print("Eevee lyrics pipeline patched for LyricsDrive export")
