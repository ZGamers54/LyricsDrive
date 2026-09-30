import SwiftUI
import WidgetKit

struct LyricsDriveWidgetEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let currentLine: String
    let nextLine: String
    let progress: Double
    let isPlaying: Bool
    let hasTrack: Bool
}

struct LyricsDriveWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> LyricsDriveWidgetEntry {
        LyricsDriveWidgetEntry(
            date: .now,
            title: "LyricsDrive",
            artist: "Spotify",
            currentLine: "Les paroles arrivent ici",
            nextLine: "♪",
            progress: 0.35,
            isPlaying: true,
            hasTrack: true
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (LyricsDriveWidgetEntry) -> Void) {
        completion(entry(for: SharedLyricsStore.load(), at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LyricsDriveWidgetEntry>) -> Void) {
        guard let payload = SharedLyricsStore.load() else {
            let entry = entry(for: nil, at: .now)
            completion(Timeline(entries: [entry], policy: .never))
            return
        }

        let now = Date()

        guard payload.isPlaying, !payload.lines.isEmpty else {
            completion(Timeline(entries: [entry(for: payload, at: now)], policy: .never))
            return
        }

        var entries: [LyricsDriveWidgetEntry] = [entry(for: payload, at: now)]
        let currentPosition = payload.projectedPosition(at: now)

        // Prépare les changements de ligne à l'avance. WidgetKit reste maître du
        // moment exact de rendu, donc la Live Activity demeure la vue la plus fine.
        for line in payload.lines where line.time > currentPosition {
            let delta = line.time - payload.progressAtAnchor
            let displayDate = payload.anchorDate.addingTimeInterval(delta)
            guard displayDate > now else { continue }
            entries.append(entry(for: payload, at: displayDate))
        }

        // Évite les doublons de dates et limite une timeline anormalement énorme.
        let endDate = payload.anchorDate.addingTimeInterval(max(0, payload.duration - payload.progressAtAnchor) + 2)
        entries.append(
            LyricsDriveWidgetEntry(
                date: endDate,
                title: "LyricsDrive",
                artist: "Spotify",
                currentLine: "Ouvre LyricsDrive pour synchroniser le morceau suivant",
                nextLine: "",
                progress: 1,
                isPlaying: false,
                hasTrack: false
            )
        )

        // Keep the timeline bounded while still covering a typical song.
        let ordered = Array(entries
            .sorted { $0.date < $1.date }
            .prefix(220))

        completion(Timeline(entries: ordered, policy: .never))
    }

    private func entry(for payload: SharedLyricsPayload?, at date: Date) -> LyricsDriveWidgetEntry {
        guard let payload else {
            return LyricsDriveWidgetEntry(
                date: date,
                title: "LyricsDrive",
                artist: "Ouvre l’app sur l’iPhone",
                currentLine: "Aucun morceau synchronisé",
                nextLine: "",
                progress: 0,
                isPlaying: false,
                hasTrack: false
            )
        }

        let position = payload.projectedPosition(at: date)
        let progress = payload.duration > 0 ? min(max(position / payload.duration, 0), 1) : 0

        if let index = payload.lineIndex(atPosition: position) {
            let current = payload.lines[index].text
            let next = index + 1 < payload.lines.count ? payload.lines[index + 1].text : ""
            return LyricsDriveWidgetEntry(
                date: date,
                title: payload.title,
                artist: payload.artist,
                currentLine: current,
                nextLine: next,
                progress: progress,
                isPlaying: payload.isPlaying,
                hasTrack: true
            )
        }

        let fallback = payload.fallbackMessage ?? (payload.lines.first?.text ?? "♪")
        return LyricsDriveWidgetEntry(
            date: date,
            title: payload.title,
            artist: payload.artist,
            currentLine: fallback,
            nextLine: payload.lines.first?.text ?? "",
            progress: progress,
            isPlaying: payload.isPlaying,
            hasTrack: true
        )
    }
}

struct LyricsDriveCarPlayWidgetView: View {
    let entry: LyricsDriveWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: entry.isPlaying ? "music.note" : "pause.fill")
                    .font(.caption2.weight(.bold))
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text(entry.currentLine)
                .font(.headline.weight(.bold))
                .lineLimit(3)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !entry.nextLine.isEmpty {
                Text(entry.nextLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(entry.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(value: entry.progress)
                .progressViewStyle(.linear)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct LyricsDriveCarPlayWidget: Widget {
    let kind = LyricsDriveWidgetConstants.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LyricsDriveWidgetProvider()) { entry in
            LyricsDriveCarPlayWidgetView(entry: entry)
        }
        .configurationDisplayName("LyricsDrive")
        .description("Affiche la ligne de paroles courante dans un petit widget, compatible avec l’écran Widgets de CarPlay.")
        .supportedFamilies([.systemSmall])
    }
}
