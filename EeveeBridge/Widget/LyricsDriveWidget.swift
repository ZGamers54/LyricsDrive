import ActivityKit
import Network
import SwiftUI
import WidgetKit

struct LyricsActivityAttributes: ActivityAttributes {
    typealias ContentState = LyricsLiveState
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
    var playbackRate: Double? = nil
    var displayOffset: TimeInterval? = nil
    var effectiveRate: Double { isPlaying ? max(0, playbackRate ?? 1) : 0 }

    func position(at date: Date) -> TimeInterval {
        let delta = max(0, date.timeIntervalSince(anchorDate)) * effectiveRate
        let position = max(0, progressAtAnchor + delta)
        return duration > 0 ? min(duration, position) : position
    }

    func lyricPosition(at date: Date) -> TimeInterval {
        position(at: date) + (displayOffset ?? 0)
    }

    func lineIndex(at date: Date) -> Int? {
        LyricsSchedule.currentIndex(in: lines, position: position(at: date),
                                    offset: displayOffset ?? 0, time: { $0.time })
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
                completion(
                    Timeline(
                        entries: [Entry(date: now, snapshot: nil, diagnostic: error)],
                        policy: .after(now.addingTimeInterval(20))
                    )
                )
                return
            }

            var entries = [Entry(date: now, snapshot: snapshot)]

            if snapshot.effectiveRate > 0.001, !snapshot.lines.isEmpty {
                let currentLyricPosition = snapshot.lyricPosition(at: now)

                for line in snapshot.lines where line.time > currentLyricPosition {
                    let anticipatedTrackTime = max(0, line.time - (snapshot.displayOffset ?? 0))
                    guard snapshot.duration <= 0 || anticipatedTrackTime <= snapshot.duration else { continue }
                    let delta = (anticipatedTrackTime - snapshot.progressAtAnchor) / snapshot.effectiveRate
                    let date = snapshot.anchorDate.addingTimeInterval(delta)

                    if date > now && date > (entries.last?.date ?? now) {
                        entries.append(Entry(date: date, snapshot: snapshot))
                    }
                    if entries.count >= 220 { break }
                }

                // Keep the precomputed timeline alive until the end of the track.
                // This avoids asking the host app for a fresh timeline ~45 s later,
                // which is exactly when iOS may have suspended the host after locking.
                if snapshot.duration > 0 {
                    let endDelta = (snapshot.duration - snapshot.progressAtAnchor) / snapshot.effectiveRate
                    let endDate = snapshot.anchorDate.addingTimeInterval(max(0, endDelta))
                    if endDate > (entries.last?.date ?? now).addingTimeInterval(1) {
                        entries.append(Entry(date: endDate, snapshot: snapshot))
                    }
                }
            }

            let policy: TimelineReloadPolicy = snapshot.isPlaying ? .atEnd : .never
            BridgeClient.acknowledge(
                "Timeline complète : \(entries.count) entrées, \(snapshot.lines.count) lignes, lecture=\(snapshot.isPlaying), policy=\(snapshot.isPlaying ? "atEnd" : "never"), offset=\(snapshot.displayOffset ?? 0)s, rate=\(snapshot.effectiveRate)"
            )
            completion(Timeline(entries: entries, policy: policy))
        }
    }
}

private enum BridgeClient {
    static func acknowledge(_ message: String) {
        let queue = DispatchQueue(label: "lyricsdrive.widget.ack")
        let connection = NWConnection(host: "127.0.0.1", port: 38475, using: .tcp)

        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(
                    content: Data(("ACK " + message + "\n").utf8),
                    completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { _, _, _, _ in
                            connection.cancel()
                        }
                    }
                )
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
                if let error {
                    finish(nil, "Réception : " + error.localizedDescription)
                    return
                }

                do {
                    guard let payload = try frame.append(data, isComplete: complete) else {
                        receive()
                        return
                    }

                    if payload == Data("{}".utf8) {
                        finish(nil, "Bridge connecté · aucun morceau")
                        return
                    }

                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .millisecondsSince1970

                    do {
                        finish(try decoder.decode(BridgeSnapshot.self, from: payload))
                    } catch {
                        acknowledge("Échec décodage JSON")
                        finish(nil, "Données du bridge illisibles")
                    }
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
                    if error != nil {
                        finish(nil, "Échec envoi au bridge")
                        return
                    }
                    receive()
                })
            case .failed(let error):
                finish(nil, "Connexion : " + error.localizedDescription)
            case .cancelled:
                finish(nil, "Connexion fermée")
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) {
            finish(nil, "Bridge sans réponse (2 s)")
        }
    }
}

private struct LyricsView: View {
    @Environment(\.showsWidgetContainerBackground) private var showsContainerBackground

    let entry: Entry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                lyrics(snapshot)
            } else {
                waiting
            }
        }
        .padding(showsContainerBackground ? 12 : 10)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.94),
                    Color.indigo.opacity(0.62)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func lyrics(_ snapshot: BridgeSnapshot) -> some View {
        let index = snapshot.lineIndex(at: entry.date)
        let current = index.map { snapshot.lines[$0].text }
            ?? snapshot.lines.first?.text
            ?? snapshot.status
        let next = index.flatMap {
            $0 + 1 < snapshot.lines.count ? snapshot.lines[$0 + 1].text : nil
        }

        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))

                Text(snapshot.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: snapshot.isPlaying ? "play.fill" : "pause.fill")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            Text(current)
                .font(.system(size: showsContainerBackground ? 18 : 20, weight: .bold, design: .rounded))
                .lineLimit(3)
                .minimumScaleFactor(0.68)
                .multilineTextAlignment(.leading)

            if let next, !next.isEmpty {
                Text(next)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(snapshot.artist)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ProgressView(
                value: snapshot.duration > 0
                    ? snapshot.position(at: entry.date) / snapshot.duration
                    : 0
            )
            .progressViewStyle(.linear)
            .tint(.primary)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text("LyricsDrive")
                    .font(.caption.weight(.semibold))
            }

            Spacer()

            Text("En attente de Spotify")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .lineLimit(2)

            Text(entry.diagnostic ?? "Bridge prêt")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
        .description("Paroles synchronisées pour iPhone, CarPlay et le Dashboard.")
        .supportedFamilies([.systemSmall])
        .containerBackgroundRemovable(true)
        .contentMarginsDisabled()
    }
}

private struct LyricsActivityView: View {
    @Environment(\.activityFamily) private var activityFamily

    let context: ActivityViewContext<LyricsActivityAttributes>

    private struct RenderedState {
        let currentLine: String
        let nextLine: String
        let progress: Double
    }

    var body: some View {
        let rendered = RenderedState(currentLine: context.state.currentLine,
                                     nextLine: context.state.nextLine,
                                     progress: context.state.progress)
        Group {
            if activityFamily == .small {
                carPlayLayout(rendered)
            } else {
                standardLayout(rendered)
            }
        }
    }

    private func carPlayLayout(_ rendered: RenderedState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.red)
                        .frame(width: 22, height: 22)

                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text("LyricsDrive")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(context.state.title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .trailing)
            }

            Spacer(minLength: 0)

            Text(rendered.currentLine)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.68)
                .multilineTextAlignment(.leading)
                .contentTransition(.numericText())

            if !rendered.nextLine.isEmpty {
                Text(rendered.nextLine)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else {
                Text(context.state.artist)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<18, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(index == 8 || index == 9 ? Color.red : Color.secondary.opacity(0.42))
                        .frame(
                            width: 3,
                            height: dashboardBarHeight(index: index, progress: rendered.progress)
                        )
                }

                Spacer(minLength: 8)

                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .activityBackgroundTint(.black.opacity(0.92))
        .activitySystemActionForegroundColor(.white)
    }

    private func dashboardBarHeight(index: Int, progress: Double) -> CGFloat {
        let phase = Int(progress * 1000) + index * 3
        let pattern: [CGFloat] = [4, 7, 11, 15, 9, 13, 6, 10]
        return pattern[abs(phase) % pattern.count]
    }

    private func standardLayout(_ rendered: RenderedState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(context.state.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text(rendered.currentLine)
                .font(.title3.weight(.bold))
                .lineLimit(3)
                .minimumScaleFactor(0.70)

            if !rendered.nextLine.isEmpty {
                Text(rendered.nextLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Group {
                if context.state.effectiveRate > 0.001 && context.state.duration > 0 {
                    let start = context.state.anchorDate.addingTimeInterval(-context.state.positionAtAnchor / context.state.effectiveRate)
                    ProgressView(timerInterval: start...start.addingTimeInterval(context.state.duration / context.state.effectiveRate),
                                 countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: rendered.progress)
                }
            }
            .progressViewStyle(.linear)
        }
        .padding(14)
        .activityBackgroundTint(.black.opacity(0.92))
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
                Image(systemName: "waveform")
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 86)
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
