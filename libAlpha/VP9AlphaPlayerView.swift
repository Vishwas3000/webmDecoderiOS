import UIKit
import Metal
import MetalKit
import CoreMedia

// MARK: - VP9AlphaPlayerView (Optimized)

/// Decodes VP9+alpha WebM and composites with Metal.
///
/// Optimizations over the original:
///   1. GPU-side YUV→RGB — raw Y/U/V planes uploaded as R8 textures,
///      conversion happens in the fragment shader. Eliminates CPU i420→BGRA loop.
///   2. Parallel decode — color and alpha decoded concurrently on separate threads.
///   3. Zero-copy demux — frame data sliced from mmap'd file, no heap copies.
///   4. Alpha Y-only — only the luma plane is uploaded for alpha (skip U/V).
///   5. Pre-allocated textures — no per-frame allocation, textures reused.
///   6. No CVPixelBuffer / CVMetalTextureCache overhead.
final class VP9AlphaPlayerView: UIView {

    // MARK: Public

    var isLooping = true
    var onPlaybackEnd: (() -> Void)?
    var onDecoderReady: ((Bool) -> Void)?

    // MARK: Private — Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?
    private var metalView: MTKView!
    private var drawCount = 0

    // MARK: Private — Playback

    private var demuxer: WebMDemuxer?
    private var colorDecoder: LibVPXDecoder?
    private var alphaDecoder: LibVPXDecoder?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var frameIndex: Int = 0
    private var isPlaying = false

    // Audio
    private var audioPlayer: AudioPlayer?
    private var audioPacketIndex: Int = 0
    private static let audioPreBufferCount = 10  // packets to pre-buffer before play

    // Single coordination queue — parallel decode uses global concurrent queues
    private let decodeQueue = DispatchQueue(label: "vp9.decode", qos: .userInteractive)

    // Double-buffer: decoded YUV textures ready for next render pass
    // Color: Y + U + V (3 textures)    Alpha: Y only (1 texture)
    private var colorYTex: MTLTexture?
    private var colorUTex: MTLTexture?
    private var colorVTex: MTLTexture?
    private var alphaYTex: MTLTexture?

    private var nextColorY: MTLTexture?
    private var nextColorU: MTLTexture?
    private var nextColorV: MTLTexture?
    private var nextAlphaY: MTLTexture?
    private let textureLock = NSLock()

    // MARK: - Init

    override init(frame: CGRect) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq  = dev.makeCommandQueue() else {
            fatalError("VP9AlphaPlayerView: Metal unavailable on this device.")
        }
        device       = dev
        commandQueue = cq

        super.init(frame: frame)
        backgroundColor = .clear
        setupMetalView()
        buildRenderPipeline()
    }

    required init?(coder: NSCoder) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq  = dev.makeCommandQueue() else { return nil }
        device       = dev
        commandQueue = cq

        super.init(coder: coder)
        backgroundColor = .clear
        setupMetalView()
        buildRenderPipeline()
    }

    // MARK: - Setup

    private func setupMetalView() {
        metalView = MTKView(frame: bounds, device: device)
        metalView.autoresizingMask    = [.flexibleWidth, .flexibleHeight]
        metalView.delegate            = self
        metalView.framebufferOnly     = false
        metalView.colorPixelFormat    = .bgra8Unorm
        metalView.isPaused            = true
        metalView.enableSetNeedsDisplay = false
        metalView.isOpaque            = false
        metalView.layer.isOpaque      = false
        addSubview(metalView)
    }

    private func buildRenderPipeline() {
        guard let lib = device.makeDefaultLibrary() else {
            print("❌ [Metal] makeDefaultLibrary failed")
            return
        }
        guard let vertFn = lib.makeFunction(name: "compositor_vertex"),
              let fragFn = lib.makeFunction(name: "compositor_fragment") else {
            print("❌ [Metal] shader functions not found")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = vertFn
        desc.fragmentFunction = fragFn

        let ca = desc.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.sourceRGBBlendFactor        = .one
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
            print("✅ [Metal] render pipeline created (YUV→RGB GPU path)")
        } catch {
            print("❌ [Metal] pipeline creation failed: \(error)")
        }
    }

    // MARK: - Load & Play

    func load(fileURL: URL) {
        print("[Demux] loading \(fileURL.lastPathComponent)")
        guard let demux = WebMDemuxer(fileURL: fileURL) else {
            print("❌ [Demux] parse failed or 0 frames")
            return
        }
        print("✅ [Demux] \(demux.frames.count) frames, \(demux.width)×\(demux.height)")
        demuxer = demux

        // Both decoders get the Metal device for direct texture upload
        colorDecoder = LibVPXDecoder(width: demux.width, height: demux.height, device: device)
        alphaDecoder = LibVPXDecoder(width: demux.width, height: demux.height, device: device)

        let ready = colorDecoder != nil && alphaDecoder != nil
        onDecoderReady?(ready)
        guard ready else { return }

        // Setup audio if the file has an audio track
        if demux.hasAudio, let config = demux.audioConfig {
            audioPlayer = AudioPlayer(config: config)
            print("✅ [Player] Audio track detected: \(config.codecID) — \(demux.audioPackets.count) packets")
        } else {
            print("ℹ️ [Player] No audio track in this file (video-only)")
        }

        // Pre-decode first frame
        decodeQueue.async { self.decodeAndBuffer(index: 0) }
    }

    func play() {
        guard let demux = demuxer, !isPlaying else { return }
        isPlaying  = true
        frameIndex = 0
        audioPacketIndex = 0

        // Pre-buffer audio packets before starting playback
        if let audio = audioPlayer, demux.hasAudio {
            let preBuffer = Array(demux.audioPackets.prefix(Self.audioPreBufferCount))
            audio.schedulePackets(packets: preBuffer, demuxer: demux)
            audioPacketIndex = preBuffer.count
            audio.start()
        }

        startTime  = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = .init(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        audioPlayer?.stop()
    }

    // MARK: - Display link

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let frames = demuxer?.frames, !frames.isEmpty else { return }

        let elapsed   = CACurrentMediaTime() - startTime
        let fps: Double = 30
        let targetIdx = Int(elapsed * fps)

        if targetIdx >= frames.count {
            if isLooping {
                startTime  = CACurrentMediaTime()
                frameIndex = 0
                // Reset audio for loop
                audioPlayer?.stop()
                audioPacketIndex = 0
                if let demux = demuxer, let audio = audioPlayer, demux.hasAudio {
                    let preBuffer = Array(demux.audioPackets.prefix(Self.audioPreBufferCount))
                    audio.schedulePackets(packets: preBuffer, demuxer: demux)
                    audioPacketIndex = preBuffer.count
                    audio.start()
                }
            } else {
                stop()
                onPlaybackEnd?()
                return
            }
        }

        let idx = min(targetIdx, frames.count - 1)
        guard idx != frameIndex || frameIndex == 0 else {
            metalView.draw()
            return
        }
        frameIndex = idx

        // Feed audio packets up to the current video PTS
        feedAudioUpTo(elapsed: elapsed)

        // Kick off next frame decode on background queue
        let nextIdx = (idx + 1) % frames.count
        decodeQueue.async { self.decodeAndBuffer(index: nextIdx) }

        // Swap buffered textures → current
        textureLock.lock()
        colorYTex = nextColorY
        colorUTex = nextColorU
        colorVTex = nextColorV
        alphaYTex = nextAlphaY
        textureLock.unlock()

        metalView.draw()
    }

    // MARK: - Audio feeding

    private func feedAudioUpTo(elapsed: TimeInterval) {
        guard let demux = demuxer, let audio = audioPlayer, demux.hasAudio else { return }

        let packets = demux.audioPackets
        // Schedule audio packets whose PTS <= current elapsed time + small lookahead
        let lookahead = elapsed + 0.1  // 100ms lookahead to avoid underruns
        while audioPacketIndex < packets.count {
            let pkt = packets[audioPacketIndex]
            let pktTime = CMTimeGetSeconds(pkt.pts)
            guard pktTime <= lookahead else { break }
            let data = demux.audioData(for: pkt)
            audio.schedulePacket(data: data)
            audioPacketIndex += 1
        }
    }

    // MARK: - Decode (parallel color + alpha)

    private func decodeAndBuffer(index: Int) {
        guard let demux = demuxer,
              let cd = colorDecoder,
              let ad = alphaDecoder,
              index < demux.frames.count else { return }

        let frame = demux.frames[index]
        let colorData = demux.colorData(for: frame)
        let alphaData = demux.alphaData(for: frame)

        var colorResult: YUVFrame?
        var alphaResult: AlphaFrame?

        if let aData = alphaData {
            // Parallel: color + alpha on global concurrent queues
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                colorResult = cd.decodeYUV(data: colorData)
                group.leave()
            }

            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                alphaResult = ad.decodeAlpha(data: aData)
                group.leave()
            }

            group.wait()
        } else {
            colorResult = cd.decodeYUV(data: colorData)
        }

        guard let color = colorResult else {
            print("❌ [Decode] color decode nil at frame \(index)")
            return
        }

        textureLock.lock()
        nextColorY = color.yTexture
        nextColorU = color.uTexture
        nextColorV = color.vTexture
        nextAlphaY = alphaResult?.yTexture
        textureLock.unlock()
    }
}

// MARK: - MTKViewDelegate

extension VP9AlphaPlayerView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        drawCount += 1
        guard let pipeline = renderPipeline,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let yTex = colorYTex,
              let uTex = colorUTex,
              let vTex = colorVTex else {
            if drawCount <= 3 { print("⚠️ [Draw] waiting for first frame...") }
            return
        }

        if drawCount == 1 {
            print("✅ [Draw] first frame — Y:\(yTex.width)×\(yTex.height) alpha:\(alphaYTex != nil ? "yes" : "no")")
        }

        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf  = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTex, index: 0)     // color Y
        encoder.setFragmentTexture(uTex, index: 1)     // color U
        encoder.setFragmentTexture(vTex, index: 2)     // color V
        // Alpha Y — fall back to color Y (renders opaque if no alpha track)
        encoder.setFragmentTexture(alphaYTex ?? yTex, index: 3)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
