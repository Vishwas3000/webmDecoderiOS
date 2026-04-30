import Foundation
import CoreMedia

// MARK: - VP9FrameSource Protocol

/// Abstraction over frame data sources — allows VP9AlphaPlayerView to consume
/// frames from either a local file (WebMDemuxer) or a DASH stream (DASHStreamController).
protocol VP9FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var hasAudio: Bool { get }
    var audioConfig: AudioTrackConfig? { get }

    /// Whether the source has enough data to begin playback.
    var isReady: Bool { get }

    /// Number of video frames currently available.
    /// For file-based sources this is the total count; for streaming it grows as segments arrive.
    var frameCount: Int { get }

    /// Total duration if known (nil for live streams).
    var totalDuration: TimeInterval? { get }

    /// Get color VP9 data for frame at the given index. Returns nil if not yet available.
    func colorData(at index: Int) -> Data?

    /// Get alpha VP9 data for frame at the given index. Returns nil if no alpha or not yet available.
    func alphaData(at index: Int) -> Data?

    /// Get audio packets with PTS up to the given time (seconds).
    /// Returns an array of (pts, data) tuples. Each call returns only NEW packets
    /// not previously returned (source tracks internal cursor).
    func audioPackets(upTo time: TimeInterval) -> [(pts: CMTime, data: Data)]

    /// Reset playback cursors to the beginning (for looping).
    func resetPlayback()
}

// MARK: - WebMDemuxer Conformance

/// Wraps the existing file-based WebMDemuxer as a VP9FrameSource.
/// All existing file-playback behavior is preserved unchanged.
extension WebMDemuxer: VP9FrameSource {

    var isReady: Bool { !frames.isEmpty }

    var frameCount: Int { frames.count }

    var totalDuration: TimeInterval? {
        guard let last = frames.last else { return nil }
        return CMTimeGetSeconds(last.pts)
    }

    func colorData(at index: Int) -> Data? {
        guard index >= 0, index < frames.count else { return nil }
        return colorData(for: frames[index])
    }

    func alphaData(at index: Int) -> Data? {
        guard index >= 0, index < frames.count else { return nil }
        return alphaData(for: frames[index])
    }

    func audioPackets(upTo time: TimeInterval) -> [(pts: CMTime, data: Data)] {
        guard hasAudio else { return [] }
        let cutoff = time + 0.1  // 100ms lookahead

        var result: [(pts: CMTime, data: Data)] = []
        while audioPlaybackCursor < audioPackets.count {
            let pkt = audioPackets[audioPlaybackCursor]
            let pktTime = CMTimeGetSeconds(pkt.pts)
            guard pktTime <= cutoff else { break }
            result.append((pkt.pts, audioData(for: pkt)))
            audioPlaybackCursor += 1
        }
        return result
    }

    func resetPlayback() {
        audioPlaybackCursor = 0
    }
}
