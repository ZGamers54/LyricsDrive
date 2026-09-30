import SwiftUI
import WidgetKit
import Network

private struct LyricLine: Codable, Hashable {
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
    let lines: [LyricLine]
    let status: String

    func position(at date: Date) -> TimeInterval {
        let delta = isPlaying ? max(0, date.timeIntervalSince(anchorDate)) : 0
        return min(duration, max(0, progressAtAnchor + delta))
    }

    func lineIndex(at date: Date) -> Int? {
        let position = position(at: date)
        var low = 0
        var high = lines.count - 1
        var answer: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= position {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}

private struct Entry: TimelineEntry {
    let date: Date
    let snapshot: BridgeSnapshot?
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        BridgeClient.fetch { snapshot in
            completion(Entry(date: .now, snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        BridgeClient.fetch { snapshot in
            let now = Date()
            guard let snapshot else {
                completion(Timeline(entries: [Entry(date: now, snapshot: nil)], policy: .after(now.addingTimeInterval(20))))
                return
            }

            var entries = [Entry(date: now, snapshot: snapshot)]

            if snapshot.isPlaying, !snapshot.lines.isEmpty {
                let current = snapshot.position(at: now)
                for line in snapshot.lines where line.time > current {
                    let delta = line.time - snapshot.progressAtAnchor
                    let date = snapshot.anchorDate.addingTimeInterval(delta)
                    if date > now {
                        entries.append(Entry(date: date, snapshot: snapshot))
                    }
                    if entries.count >= 220 { break }
                }
            }

            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(45))))
        }
    }
}

private enum BridgeClient {
    static func fetch(completion: @escaping (BridgeSnapshot?) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: 38475, using: .tcp)
        let queue = DispatchQueue(label: "lyricsdrive.widget.bridge")
        var finished = false

        func finish(_ snapshot: BridgeSnapshot?) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { completion(snapshot) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("STATE\n".utf8), completion: .contentProcessed { error in
                    if error != nil { finish(nil); return }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_500_000) { data, _, _, _ in
                        guard let data, !data.isEmpty else { finish(nil); return }
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .millisecondsSince1970
                        finish(try? decoder.decode(BridgeSnapshot.self, from: data))
                    }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + 2.0) {
            finish(nil)
        }
    }
}

private struct LyricsView: View {
    let entry: Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            let index = snapshot.lineIndex(at: entry.date)
            let current = index.map { snapshot.lines[$0].text } ?? snapshot.status
            let next = index.flatMap { $0 + 1 < snapshot.lines.count ? snapshot.lines[$0 + 1].text : nil }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: snapshot.isPlaying ? "music.note" : "pause.fill")
                    Text(snapshot.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(current)
                    .font(.headline.weight(.bold))
                    .lineLimit(3)
                    .minimumScaleFactor(0.68)

                if let next, !next.isEmpty {
                    Text(next)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(snapshot.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressView(value: snapshot.duration > 0 ? snapshot.position(at: entry.date) / snapshot.duration : 0)
                    .progressViewStyle(.linear)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("LyricsDrive", systemImage: "music.note")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Lance EeveeSpotify")
                    .font(.headline)
                    .lineLimit(2)
                Text("En attente du bridge")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct LyricsDriveCarPlayWidget: Widget {
    let kind = "LyricsDriveCarPlay"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            LyricsView(entry: entry)
        }
        .configurationDisplayName("LyricsDrive")
        .description("Paroles synchronisées du morceau Spotify en cours.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct LyricsDriveWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsDriveCarPlayWidget()
    }
}
