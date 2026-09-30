import UIKit

/// Only protects an actual ActivityKit submission. It doesn't keep Spotify alive.
@MainActor
final class ActivityUpdateLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    private(set) var granted = false
    private(set) var expired = false

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "LyricsDrive lyric update") { [weak self] in
            Task { @MainActor in
                self?.expired = true
                self?.finish()
            }
        }
        granted = identifier != .invalid
    }

    func finish() {
        guard identifier != .invalid else { return }
        let task = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}
