import ActivityKit
import Network
import SwiftUI
import WidgetKit

struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let currentLine: String
        let nextLine: String
        let progress: Double
        let isPlaying: Bool
    }

    let trackID: String
}

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
        let position = max(0, progressAtAnchor + delta)
        return duration > 0 ? min(duration, position) : position
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
    var diagnostic: String? = nil
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        BridgeClient.fetch { snapshot, error in
            completion(Entry(date: .now, snapshot: snapshot, diagnostic: error))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        BridgeClient.fetch { snapshot, error in
            let now = Date()
            guard let snapshot else {
                completion(Timeline(entries: [Entry(date: now, snapshot: nil, diagnostic: error)], policy: .after(now.addingTimeInterval(20))))
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

            BridgeClient.acknowledge("Timeline fournie : \(entries.count) entrées, \(snapshot.lines.count) lignes, lecture=\(snapshot.isPlaying)")
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(45))))
        }
    }
}

private enum BridgeClient {
    static func acknowledge(_ message: String) {
        let queue = DispatchQueue(label: "lyricsdrive.widget.ack")
        let connection = NWConnection(host: "127.0.0.1", port: 38475, using: .tcp)
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: Data(("ACK " + message + "\n").utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { _, _, _, _ in connection.cancel() }
                })
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    static func fetch(completion: @escaping (BridgeSnapshot?, String?) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: 38475, using: .tcp)
        let queue = DispatchQueue(label: "lyricsdrive.widget.bridge")
        var finished = false
        var frame = BridgeFrame()

        func finish(_ snapshot: BridgeSnapshot?, _ error: String? = nil) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            DispatchQueue.main.async { completion(snapshot, error) }
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                guard !finished else { return }
                if let error { finish(nil, "Réception : " + error.localizedDescription); return }
                do {
                    guard let payload = try frame.append(data, isComplete: complete) else { receive(); return }
                    if payload == Data("{}".utf8) { finish(nil, "Bridge connecté · aucun morceau"); return }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970
                    do { finish(try decoder.decode(BridgeSnapshot.self, from: payload)) }
                    catch { acknowledge("Échec décodage JSON"); finish(nil, "Données du bridge illisibles") }
                } catch {
                    acknowledge("Réponse tronquée ou trop grande")
                    finish(nil, "Réponse incomplète du bridge")
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("STATE\n".utf8), completion: .contentProcessed { error in
                    if error != nil { finish(nil, "Échec envoi au bridge"); return }
                    receive()
                })
            case .failed(let error): finish(nil, "Connexion : " + error.localizedDescription)
            case .cancelled: finish(nil, "Connexion fermée")
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) { finish(nil, "Bridge sans réponse (2 s)") }
    }
}

private struct LyricsView: View {
    let entry: Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            let index = snapshot.lineIndex(at: entry.date)
            let current = index.map { snapshot.lines[$0].text }
                ?? snapshot.lines.first?.text
                ?? snapshot.status
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
                Text(entry.diagnostic ?? "En attente du bridge")
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

private struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: activityFamily == .small ? 5 : 7) {
            HStack(spacing: 5) {
                Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                Text(context.state.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text(context.state.currentLine)
                .font(activityFamily == .small ? .headline.weight(.bold) : .title3.weight(.bold))
                .lineLimit(activityFamily == .small ? 2 : 3)
                .minimumScaleFactor(0.70)

            if !context.state.nextLine.isEmpty {
                Text(context.state.nextLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(context.state.artist)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(value: context.state.progress)
                .progressViewStyle(.linear)
        }
        .padding(activityFamily == .small ? 10 : 14)
        .activityBackgroundTint(.black.opacity(0.88))
        .activitySystemActionForegroundColor(.white)
    }
}

struct LyricsDriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 3) {
                        Text(context.state.currentLine)
                            .font(.headline)
                            .lineLimit(2)
                        if !context.state.nextLine.isEmpty {
                            Text(context.state.nextLine)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "music.note")
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

@main
struct LyricsDriveWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsDriveCarPlayWidget()
        LyricsDriveLiveActivity()
    }
}
