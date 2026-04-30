import Foundation
import CoreMedia
import QuartzCore

// MARK: - DASH Stream Controller

/// Downloads and manages DASH WebM segments, providing frames and audio packets
/// via the VP9FrameSource protocol for playback in VP9AlphaPlayerView.
final class DASHStreamController: VP9FrameSource {

    // MARK: - VP9FrameSource properties

    private(set) var width: Int = 0
    private(set) var height: Int = 0

    // Audio may be in separate segments (audioSegmentDemuxer) or muxed with video (segmentDemuxer)
    var hasAudio: Bool { audioSegmentDemuxer.audioConfig != nil || segmentDemuxer.audioConfig != nil }
    var audioConfig: AudioTrackConfig? { audioSegmentDemuxer.audioConfig ?? segmentDemuxer.audioConfig }
    private var hasSeparateAudio: Bool { manifest.audioAdaptationSet != nil }
    var isReady: Bool { !allFrames.isEmpty }

    var frameCount: Int {
        accessQueue.sync { allFrames.count }
    }

    var totalDuration: TimeInterval? { manifest.mediaPresentationDuration }

    // MARK: - Public

    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    // MARK: - Private

    private let manifest: MPDManifest
    private var baseURL: URL { manifest.baseURL }
    private let segmentDemuxer = WebMSegmentDemuxer()
    private let audioSegmentDemuxer = WebMSegmentDemuxer()  // separate demuxer for audio init+media

    // Buffer state — accessed from multiple threads, protected by accessQueue
    private let accessQueue = DispatchQueue(label: "dash.access")
    private var allFrames: [StreamingFrame] = []
    private var allAudioPackets: [StreamingAudioPacket] = []
    private var audioPlaybackCursor: Int = 0
    private var segmentBuffer: [SegmentFrames] = []  // retains segment Data

    // Download state
    private let downloadQueue = DispatchQueue(label: "dash.download", qos: .userInitiated)
    private var urlSession: URLSession!
    private var isStreaming = false
    private var nextSegmentIndex: Int = 0

    // ABR
    private var bandwidthEstimator = BandwidthEstimator()
    private var currentRepresentationIndex: Int = 0

    // Segment URLs (for current video representation)
    private var videoSegmentURLs: [URL] = []
    private var audioSegmentURLs: [URL] = []
    private var videoInitURL: URL?
    private var audioInitURL: URL?

    // Configuration
    private static let maxBufferedSegments = 6
    private static let minBufferedBeforeReady = 2

    // MARK: - Init

    init(manifest: MPDManifest) {
        self.manifest = manifest

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30
        config.urlCache = URLCache(memoryCapacity: 10_000_000, diskCapacity: 50_000_000)
        self.urlSession = URLSession(configuration: config)

        selectInitialRepresentation()
    }

    // MARK: - Start / Stop

    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true
        print("[DASH] Starting stream...")

        downloadQueue.async { [weak self] in
            self?.downloadInitSegmentsAndBegin()
        }
    }

    func stopStreaming() {
        isStreaming = false
        urlSession.invalidateAndCancel()
    }

    // MARK: - VP9FrameSource

    func colorData(at index: Int) -> Data? {
        accessQueue.sync {
            guard index >= 0, index < allFrames.count else { return nil }
            return allFrames[index].colorData
        }
    }

    func alphaData(at index: Int) -> Data? {
        accessQueue.sync {
            guard index >= 0, index < allFrames.count else { return nil }
            return allFrames[index].alphaData
        }
    }

    func audioPackets(upTo time: TimeInterval) -> [(pts: CMTime, data: Data)] {
        accessQueue.sync {
            let cutoff = time + 0.1
            var result: [(pts: CMTime, data: Data)] = []
            while audioPlaybackCursor < allAudioPackets.count {
                let pkt = allAudioPackets[audioPlaybackCursor]
                let pktTime = CMTimeGetSeconds(pkt.pts)
                guard pktTime <= cutoff else { break }
                result.append((pkt.pts, pkt.data))
                audioPlaybackCursor += 1
            }
            return result
        }
    }

    func resetPlayback() {
        accessQueue.sync {
            audioPlaybackCursor = 0
        }
    }

    // MARK: - Representation Selection

    private func selectInitialRepresentation() {
        guard let videoSet = manifest.videoAdaptationSet else { return }
        let sorted = videoSet.representations.sorted { $0.bandwidth < $1.bandwidth }
        // Start with the lowest quality for fast startup
        currentRepresentationIndex = 0
        updateSegmentURLs(videoRep: sorted[currentRepresentationIndex])
    }

    private func updateSegmentURLs(videoRep: MPDRepresentation) {
        videoInitURL = videoRep.initSegmentURL(baseURL: baseURL)
        videoSegmentURLs = videoRep.mediaSegmentURLs(baseURL: baseURL,
                                                      totalDuration: manifest.mediaPresentationDuration)

        // Audio (use first audio representation if available)
        if let audioSet = manifest.audioAdaptationSet,
           let audioRep = audioSet.representations.first {
            audioInitURL = audioRep.initSegmentURL(baseURL: baseURL)
            audioSegmentURLs = audioRep.mediaSegmentURLs(baseURL: baseURL,
                                                          totalDuration: manifest.mediaPresentationDuration)
        }

        print("[DASH] Video: \(videoSegmentURLs.count) segments, Audio: \(audioSegmentURLs.count) segments")
    }

    // MARK: - Download Pipeline

    private func downloadInitSegmentsAndBegin() {
        // Download video init segment
        guard let videoInit = videoInitURL else {
            onError?("No video init segment URL")
            return
        }

        print("[DASH] Downloading video init segment...")
        guard let videoInitData = synchronousDownload(url: videoInit) else {
            onError?("Failed to download video init segment")
            return
        }

        guard segmentDemuxer.parseInitSegment(data: videoInitData) else {
            onError?("Failed to parse video init segment")
            return
        }

        width = segmentDemuxer.width
        height = segmentDemuxer.height
        print("[DASH] Init parsed: \(width)×\(height)")

        if let cfg = segmentDemuxer.audioConfig {
            // Muxed: audio track found in video init segment
            print("[DASH] Muxed audio: track#\(segmentDemuxer.audioTrackNumber) \(cfg.codecID) \(cfg.sampleRate)Hz \(cfg.channels)ch")
        }

        // Download separate audio init segment if present
        if let audioInit = audioInitURL {
            print("[DASH] Downloading audio init segment...")
            if let audioInitData = synchronousDownload(url: audioInit) {
                audioSegmentDemuxer.parseInitSegment(data: audioInitData)
                if let cfg = audioSegmentDemuxer.audioConfig {
                    print("[DASH] Separate audio init: track#\(audioSegmentDemuxer.audioTrackNumber) \(cfg.codecID) \(cfg.sampleRate)Hz \(cfg.channels)ch")
                } else {
                    print("⚠️ [DASH] Audio init parsed but no audio track found")
                }
            }
        }

        // Begin downloading media segments
        nextSegmentIndex = 0
        downloadNextSegments()
    }

    private func downloadNextSegments() {
        while isStreaming && nextSegmentIndex < videoSegmentURLs.count {
            let bufferedCount = accessQueue.sync { segmentBuffer.count }
            guard bufferedCount < Self.maxBufferedSegments else {
                // Buffer full — wait and retry
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            let segIdx = nextSegmentIndex
            let url = videoSegmentURLs[segIdx]

            let startTime = CACurrentMediaTime()
            guard let data = synchronousDownload(url: url) else {
                print("⚠️ [DASH] Failed to download segment \(segIdx), retrying...")
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let elapsed = CACurrentMediaTime() - startTime
            bandwidthEstimator.record(bytes: data.count, duration: elapsed)

            // Parse the media segment
            let segFrames = segmentDemuxer.parseMediaSegment(data: data)

            if hasSeparateAudio && segIdx < audioSegmentURLs.count {
                // Separate audio track — download and parse with audio demuxer
                let audioURL = audioSegmentURLs[segIdx]
                if let audioData = synchronousDownload(url: audioURL) {
                    let audioFrames = audioSegmentDemuxer.parseMediaSegment(data: audioData)
                    accessQueue.sync {
                        allAudioPackets.append(contentsOf: audioFrames.audioPackets)
                        segmentBuffer.append(audioFrames)
                    }
                }
            }

            // Append video frames + muxed audio (if audio is in the same segments)
            accessQueue.sync {
                allFrames.append(contentsOf: segFrames.videoFrames)
                if !hasSeparateAudio {
                    allAudioPackets.append(contentsOf: segFrames.audioPackets)
                }
                segmentBuffer.append(segFrames)
            }

            nextSegmentIndex += 1

            let fc = accessQueue.sync { allFrames.count }
            let alphaCount = segFrames.videoFrames.filter { $0.alphaData != nil }.count
            print("[DASH] Segment \(segIdx) loaded: +\(segFrames.videoFrames.count) frames (\(alphaCount) with alpha) (total: \(fc))")

            // Signal ready after minimum buffering
            if segIdx == Self.minBufferedBeforeReady - 1 {
                DispatchQueue.main.async { [weak self] in
                    self?.onReady?()
                }
            }

            // ABR: consider switching representation at segment boundary
            maybeAdaptBitrate()
        }

        if isStreaming {
            print("[DASH] All \(videoSegmentURLs.count) segments downloaded")
        }
    }

    // MARK: - ABR

    private func maybeAdaptBitrate() {
        guard let videoSet = manifest.videoAdaptationSet else { return }
        let sorted = videoSet.representations.sorted { $0.bandwidth < $1.bandwidth }
        guard sorted.count > 1 else { return }

        let estimatedBW = bandwidthEstimator.estimatedBandwidth

        // Switch up if bandwidth is 1.5× the next higher representation
        if currentRepresentationIndex < sorted.count - 1 {
            let nextUp = sorted[currentRepresentationIndex + 1]
            if estimatedBW > Int(Double(nextUp.bandwidth) * 1.5) {
                currentRepresentationIndex += 1
                updateSegmentURLs(videoRep: sorted[currentRepresentationIndex])
                print("[DASH] ABR: switching UP to \(nextUp.bandwidth / 1000)kbps")
            }
        }

        // Switch down immediately if bandwidth is below current
        if currentRepresentationIndex > 0 {
            let current = sorted[currentRepresentationIndex]
            if estimatedBW < current.bandwidth {
                currentRepresentationIndex -= 1
                updateSegmentURLs(videoRep: sorted[currentRepresentationIndex])
                print("[DASH] ABR: switching DOWN to \(sorted[currentRepresentationIndex].bandwidth / 1000)kbps")
            }
        }
    }

    // MARK: - Network

    private func synchronousDownload(url: URL) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        let task = urlSession.dataTask(with: url) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                result = data
            } else if let error = error {
                print("⚠️ [DASH] Download error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return result
    }
}

// MARK: - Bandwidth Estimator

private struct BandwidthEstimator {
    private var samples: [(bytes: Int, duration: TimeInterval)] = []
    private let windowSize = 5

    mutating func record(bytes: Int, duration: TimeInterval) {
        samples.append((bytes, duration))
        if samples.count > windowSize {
            samples.removeFirst()
        }
    }

    /// Estimated bandwidth in bits/sec (exponentially weighted).
    var estimatedBandwidth: Int {
        guard !samples.isEmpty else { return 0 }
        var weightedSum: Double = 0
        var weightTotal: Double = 0
        for (i, sample) in samples.enumerated() {
            let weight = pow(2.0, Double(i))  // newer samples weighted higher
            let bps = Double(sample.bytes * 8) / max(sample.duration, 0.001)
            weightedSum += bps * weight
            weightTotal += weight
        }
        return Int(weightedSum / weightTotal)
    }
}
