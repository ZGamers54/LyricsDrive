import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager: ObservableObject {
    @Published private(set) var isRunning = false
    private var activity: Activity<LyricsActivityAttributes>?

    func start(title: String, artist: String, currentLine: String = "Chargement…") async throws {
        await stop()
        let attributes = LyricsActivityAttributes(sessionID: UUID().uuidString)
        let state = LyricsActivityAttributes.ContentState(
            title: title,
            artist: artist,
            currentLine: currentLine,
            nextLine: "",
            progress: 0,
            isPlaying: true
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        isRunning = true
    }

    func update(title: String, artist: String, currentLine: String, nextLine: String, progress: Double, isPlaying: Bool) async {
        guard let activity else { return }
        let state = LyricsActivityAttributes.ContentState(
            title: title,
            artist: artist,
            currentLine: currentLine,
            nextLine: nextLine,
            progress: min(max(progress, 0), 1),
            isPlaying: isPlaying
        )
        await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(15)))
    }

    func stop() async {
        if let activity {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        isRunning = false
    }
}
