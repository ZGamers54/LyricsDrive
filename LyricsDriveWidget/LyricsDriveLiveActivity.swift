import ActivityKit
import SwiftUI
import WidgetKit

private struct LyricsDriveActivityView: View {
    @Environment(\.activityFamily) private var activityFamily
    let context: ActivityViewContext<LyricsActivityAttributes>

    var body: some View {
        Group {
            if activityFamily == .small {
                smallContent
            } else {
                regularContent
            }
        }
        .activityBackgroundTint(.black.opacity(0.88))
        .activitySystemActionForegroundColor(.white)
    }

    private var smallContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                    .font(.caption2.weight(.bold))
                Text(context.state.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }

            Text(context.state.currentLine)
                .font(.headline.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.72)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: context.state.isPlaying ? "music.note" : "pause.fill")
                Text(context.state.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            Text(context.state.currentLine)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
            if !context.state.nextLine.isEmpty {
                Text(context.state.nextLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            ProgressView(value: context.state.progress)
        }
        .padding()
    }
}

struct LyricsDriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LyricsDriveActivityView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "music.note")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(Int(context.state.progress * 100))%")
                        .font(.caption2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Text(context.state.currentLine)
                            .font(.headline)
                            .multilineTextAlignment(.center)
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
                Text(shortLine(context.state.currentLine))
                    .font(.caption2)
                    .lineLimit(1)
            } minimal: {
                Image(systemName: "music.note")
            }
        }
        .supplementalActivityFamilies([.small])
    }

    private func shortLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 16 { return trimmed }
        return String(trimmed.prefix(15)) + "…"
    }
}
