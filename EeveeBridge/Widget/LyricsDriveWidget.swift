import ActivityKit
import Compression
import Network
import SwiftUI
import WidgetKit

private enum LyricsTiming {
    static let displayLead: TimeInterval = 0.45
}

struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let title: String
        let artist: String
        let currentLine: String
        let nextLine: String
        let progress: Double
        let isPlaying: Bool
        let lyricSchedule: Data
        let anchorDate: Date
        let positionAtAnchor: Double
        let duration: Double
    }

    let trackID: String
}

private struct LyricLine: Codable, Hashable {
    let time: TimeInterval
    let text: String
}

private struct LiveLyricCue: Hashable {
    let time: TimeInterval
    let text: String
}

private enum LiveLyricsScheduleCodec {
    private static let compressedMagic = Data([0x4C, 0x44, 0x5A, 0x31]) // LDZ1
    private static let rawMagic = Data([0x4C, 0x44, 0x52, 0x31])        // LDR1

    static func decode(_ data: Data) -> [LiveLyricCue] {
        guard data.count >= 8 else { return [] }

        let magic = Data(data.prefix(4))
        var rawSizeLE: UInt32 = 0
        withUnsafeMutableBytes(of: &rawSizeLE) { buffer in
            data.copyBytes(to: buffer, from: 4..<8)
        }
        let rawSize = Int(UInt32(littleEndian: rawSizeLE))
        guard rawSize > 0, rawSize < 256_000 else { return [] }

        let payload = Data(data.dropFirst(8))
        let raw: Data

        if magic == compressedMagic {
            var decoded = Data(count: rawSize)
            let count: Int = payload.withUnsafeBytes { srcBuffer in
                decoded.withUnsafeMutableBytes { dstBuffer in
                    guard let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress,
                          let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }

                    return compression_decode_buffer(
                        dst,
                        rawSize,
                        src,
                        payload.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
            }
            guard count == rawSize else { return [] }
            raw = decoded
        } else if magic == rawMagic {
            raw = payload
        } else {
            return []
        }

        var cues: [LiveLyricCue] = []
        var offset = 0

        while offset + 6 <= raw.count {
            var millisLE: UInt32 = 0
            var lengthLE: UInt16 = 0

            withUnsafeMutableBytes(of: &millisLE) { buffer in
                raw.copyBytes(to: buffer, from: offset..<(offset + 4))
            }
            offset += 4

            withUnsafeMutableBytes(of: &lengthLE) { buffer in
                raw.copyBytes(to: buffer, from: offset..<(offset + 2))
            }
            offset += 2

            let length = Int(UInt16(littleEndian: lengthLE))
            guard length >= 0, offset + length <= raw.count else { break }

            let textData = raw.subdata(in: offset..<(offset + length))
            offset += length

            guard let text = String(data: textData, encoding: .utf8), !text.isEmpty else { continue }
            cues.append(
                LiveLyricCue(
                    time: Double(UInt32(littleEndian: millisLE)) / 1000.0,
                    text: text
                )
            )
        }

        return cues
    }
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

    func lyricPosition(at date: Date) -> TimeInterval {
        max(0, position(at: date) + LyricsTiming.displayLead)
    }

    func lineIndex(at date: Date) -> Int? {
        let position = lyricPosition(at: date)
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
                completion(
                    Timeline(
                        entries: [Entry(date: now, snapshot: nil, diagnostic: error)],
                        policy: .after(now.addingTimeInterval(20))
                    )
                )
                return
            }

            var entries = [Entry(date: now, snapshot: snapshot)]

            if snapshot.isPlaying, !snapshot.lines.isEmpty {
                let currentLyricPosition = snapshot.lyricPosition(at: now)

                for line in snapshot.lines where line.time > currentLyricPosition {
                    let anticipatedTrackTime = max(0, line.time - LyricsTiming.displayLead)
                    let delta = anticipatedTrackTime - snapshot.progressAtAnchor
                    let date = snapshot.anchorDate.addingTimeInterval(delta)

                    if date > now {
                        entries.append(Entry(date: date, snapshot: snapshot))
                    }
                    if entries.count >= 220 { break }
                }

                // Keep the precomputed timeline alive until the end of the track.
                // This avoids asking the host app for a fresh timeline ~45 s later,
                // which is exactly when iOS may have suspended the host after locking.
                if snapshot.duration > 0 {
                    let endDelta = snapshot.duration - snapshot.progressAtAnchor
                    let endDate = snapshot.anchorDate.addingTimeInterval(max(0, endDelta))
                    if endDate > (entries.last?.date ?? now).addingTimeInterval(1) {
                        entries.append(Entry(date: endDate, snapshot: snapshot))
                    }
                }
            }

            let policy: TimelineReloadPolicy = snapshot.isPlaying ? .atEnd : .never
            BridgeClient.acknowledge(
                "Timeline complète : \(entries.count) entrées, \(snapshot.lines.count) lignes, lecture=\(snapshot.isPlaying), policy=\(snapshot.isPlaying ? "atEnd" : "never"), avance=\(LyricsTiming.displayLead)s"
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
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            let rendered = renderedState(at: timeline.date)

            Group {
                if activityFamily == .small {
                    carPlayLayout(rendered)
                } else {
                    standardLayout(rendered)
                }
            }
        }
    }

    private func renderedState(at date: Date) -> RenderedState {
        let state = context.state
        let elapsed = state.isPlaying ? max(0, date.timeIntervalSince(state.anchorDate)) : 0
        let position = max(0, min(state.duration > 0 ? state.duration : .greatestFiniteMagnitude,
                                  state.positionAtAnchor + elapsed))
        let lyricPosition = position + LyricsTiming.displayLead
        let cues = LiveLyricsScheduleCodec.decode(state.lyricSchedule)

        guard !cues.isEmpty else {
            return RenderedState(
                currentLine: state.currentLine,
                nextLine: state.nextLine,
                progress: state.duration > 0 ? min(max(position / state.duration, 0), 1) : state.progress
            )
        }

        var low = 0
        var high = cues.count - 1
        var answer: Int?

        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].time <= lyricPosition {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let current: String
        let next: String

        if let index = answer {
            current = cues[index].text
            next = index + 1 < cues.count ? cues[index + 1].text : ""
        } else {
            current = state.currentLine
            next = cues.first?.text ?? state.nextLine
        }

        return RenderedState(
            currentLine: current,
            nextLine: next,
            progress: state.duration > 0 ? min(max(position / state.duration, 0), 1) : state.progress
        )
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

            ProgressView(value: rendered.progress)
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
