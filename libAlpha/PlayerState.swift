// MARK: - PlayerState

/// Mirrors AVPlayer's status + rate concept in a single enum.
enum PlayerState: Equatable {
    case idle         // before any load() call
    case loading      // source initializing / DASH buffering initial segments
    case playing
    case paused
    case buffering    // stalled — waiting for decode or DASH download to catch up
    case ended        // reached end with isLooping = false
    case error(String)

    static func == (lhs: PlayerState, rhs: PlayerState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.playing, .playing), (.paused, .paused),
             (.buffering, .buffering), (.ended, .ended):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}
