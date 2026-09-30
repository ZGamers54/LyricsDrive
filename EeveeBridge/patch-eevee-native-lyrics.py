#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1])
custom = root / "Sources/EeveeSpotify/Lyrics/CustomLyrics.x.swift"
instance_hook = root / "Sources/EeveeSpotify/Lyrics/NowPlayingScrollViewControllerInstanceHook.x.swift"

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

helper_anchor = '''func getLyricsDataForCurrentTrack(originalLyrics: Lyrics? = nil) throws -> Data {
'''
helper = '''private let lyricsDrivePrefetchQueue = DispatchQueue(label: "lyricsdrive.eevee.prefetch")
private var lyricsDriveLastPrefetchedTrackID: String?

func lyricsDrivePrefetchCurrentTrackIfNeeded() {
    guard UserDefaults.lyricsSource.isReplacingLyrics else { return }
    guard let track = nowPlayingScrollViewController?.loadedTrack else { return }

    let trackID = track.URI().spt_trackIdentifier()
    guard !trackID.isEmpty else { return }

    lyricsDrivePrefetchQueue.async {
        if lyricsDriveLastPrefetchedTrackID == trackID { return }
        lyricsDriveLastPrefetchedTrackID = trackID

        // Eevee's repository layer is intentionally reused here. This means the
        // LyricsDrive widget follows the exact source chosen in Eevee settings
        // (LRCLIB, Musixmatch, PetitLyrics or Genius) instead of performing its
        // own second lyrics lookup.
        _ = try? loadCustomLyricsForCurrentTrack()
    }
}

func getLyricsDataForCurrentTrack(originalLyrics: Lyrics? = nil) throws -> Data {
'''

if helper_anchor not in src:
    raise SystemExit("Could not find prefetch helper insertion point")
src = src.replace(helper_anchor, helper, 1)
custom.write_text(src)

hook = instance_hook.read_text()
hook_needle = '''        nowPlayingScrollViewController = orig.nowPlayingScrollViewModelWithDidMoveToRelativeTrack(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        return nowPlayingScrollViewController!
'''
hook_insert = '''        nowPlayingScrollViewController = orig.nowPlayingScrollViewModelWithDidMoveToRelativeTrack(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )

        // Give Spotify a moment to finish switching its current-track objects,
        // then ask Eevee's own selected lyrics provider to prepare the lines.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            lyricsDrivePrefetchCurrentTrackIfNeeded()
        }
        
        return nowPlayingScrollViewController!
'''

if hook_needle not in hook:
    raise SystemExit("Could not find track-change prefetch insertion point")
hook = hook.replace(hook_needle, hook_insert, 1)
instance_hook.write_text(hook)

print("Patched", custom)
print("Patched", instance_hook)
