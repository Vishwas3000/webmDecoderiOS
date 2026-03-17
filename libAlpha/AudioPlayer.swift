import Foundation
import AVFoundation

// MARK: - Opus Audio Player

/// Decodes Opus packets via libopus and plays them through AVAudioEngine.
/// Designed to work alongside VP9AlphaPlayerView for A/V sync.
final class AudioPlayer {

    // MARK: Public

    /// Current audio playback time in seconds (for video sync).
    var currentTime: TimeInterval {
        guard let node = playerNode, let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return 0
        }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    var isPlaying: Bool { playerNode?.isPlaying ?? false }

    // MARK: Private

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var opusDecoder: OpaquePointer?

    private let sampleRate: Double
    private let channels: Int
    private let outputFormat: AVAudioFormat

    // Opus decodes to 48kHz always; max frame = 120ms = 5760 samples
    private static let maxFrameSize = 5760
    private var pcmBuffer: [Float]

    // MARK: - Init

    init?(config: AudioTrackConfig) {
        self.sampleRate = config.sampleRate
        self.channels = config.channels

        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: AVAudioChannelCount(config.channels),
            interleaved: false
        ) else {
            print("❌ [Audio] Cannot create AVAudioFormat")
            return nil
        }
        self.outputFormat = fmt
        self.pcmBuffer = [Float](repeating: 0, count: Self.maxFrameSize * channels)

        // Create Opus decoder
        let decoder = opus_bridge_create(Int32(config.sampleRate), Int32(config.channels))
        guard decoder != nil else {
            print("❌ [Audio] opus_bridge_create failed")
            return nil
        }
        self.opusDecoder = OpaquePointer(decoder)

        setupEngine()
        print("✅ [Audio] Opus decoder ready: \(config.sampleRate)Hz \(config.channels)ch")
    }

    deinit {
        stop()
        if let dec = opusDecoder {
            opus_bridge_destroy(UnsafeMutableRawPointer(dec))
        }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)

        self.engine = engine
        self.playerNode = node
    }

    // MARK: - Playback

    func start() {
        guard let engine = engine, let node = playerNode else { return }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        do {
            try engine.start()
            node.play()
            print("✅ [Audio] Engine started")
        } catch {
            print("❌ [Audio] Engine start failed: \(error)")
        }
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
    }

    /// Decode an Opus packet and schedule it for playback.
    /// Call this for each AudioPacket from the demuxer.
    func schedulePacket(data: Data) {
        guard let dec = opusDecoder else { return }

        let frameCount = data.withUnsafeBytes { rawBuf -> Int32 in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return opus_bridge_decode_float(
                UnsafeMutableRawPointer(dec),
                ptr, Int32(data.count),
                &pcmBuffer, Int32(Self.maxFrameSize)
            )
        }

        guard frameCount > 0 else {
            if frameCount < 0 {
                let errStr = String(cString: opus_bridge_strerror(frameCount))
                print("⚠️ [Audio] Opus decode error: \(errStr)")
            }
            return
        }

        // Create AVAudioPCMBuffer from decoded float samples
        guard let pcmBuf = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }

        pcmBuf.frameLength = AVAudioFrameCount(frameCount)

        // Copy interleaved → non-interleaved (AVAudioEngine expects non-interleaved)
        if channels == 1 {
            memcpy(pcmBuf.floatChannelData![0],
                   pcmBuffer,
                   Int(frameCount) * MemoryLayout<Float>.size)
        } else {
            // De-interleave stereo: [L R L R ...] → [L L L ...] [R R R ...]
            let left  = pcmBuf.floatChannelData![0]
            let right = pcmBuf.floatChannelData![1]
            for i in 0 ..< Int(frameCount) {
                left[i]  = pcmBuffer[i * 2]
                right[i] = pcmBuffer[i * 2 + 1]
            }
        }

        playerNode?.scheduleBuffer(pcmBuf)
    }

    /// Batch-schedule multiple packets at once (for pre-buffering).
    func schedulePackets(packets: [AudioPacket], demuxer: WebMDemuxer) {
        for packet in packets {
            let data = demuxer.audioData(for: packet)
            schedulePacket(data: data)
        }
    }
}
