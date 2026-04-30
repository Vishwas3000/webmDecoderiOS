import UIKit
import Metal
import MetalKit
import CoreMedia

// MARK: - VP9AlphaPlayerView (Optimized)

/// Decodes VP9+alpha WebM and composites with Metal.
///
/// Supports two frame source modes:
///   - File-based: `load(fileURL:)` — loads a local .webm file via WebMDemuxer
///   - Streaming:  `loadStream(controller:)` — DASH streaming via DASHStreamController
///
/// Both paths feed frames through the VP9FrameSource protocol into the same
/// Metal rendering pipeline and parallel decode engine.
final class VP9AlphaPlayerView: UIView {

    // MARK: Public

    var isLooping = true
    var onPlaybackEnd: (() -> Void)?
    var onDecoderReady: ((Bool) -> Void)?

    // AVPlayer-like interface
    private(set) var state: PlayerState = .idle
    var onStateChange: ((PlayerState) -> Void)?
    var onTimeUpdate: ((TimeInterval) -> Void)?

    /// Current playback position in seconds.
    var currentTime: TimeInterval {
        if let paused = pausedTime { return paused }
        guard isPlaying else { return 0 }
        return CACurrentMediaTime() - startTime
    }

    /// Total duration in seconds. Nil until the source is ready.
    var duration: TimeInterval? { frameSource?.totalDuration }

    // MARK: Private — Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?
    private var metalView: MTKView!
    private var drawCount = 0

    // Loading indicator — lives inside the player so it's always above the Metal layer
    private let loadingIndicator: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .medium)
        v.color = .white
        v.hidesWhenStopped = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: Private — Playback

    private var frameSource: VP9FrameSource?
    private var colorDecoder: LibVPXDecoder?
    private var alphaDecoder: LibVPXDecoder?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var frameIndex: Int = 0
    private var isPlaying = false
    private var pausedTime: TimeInterval?

    // Audio
    private var audioPlayer: AudioPlayer?

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

    // Index of the most recently decoded frame sitting in next* textures.
    // -1 = nothing decoded yet. Guarded by textureLock.
    private var decodedFrameIdx: Int = -1

    // Solid white 1×1 texture — used as alpha fallback for fully opaque rendering
    private lazy var opaqueAlphaTexture: MTLTexture? = {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        // Value 255 → shader computes (1.0 - 16/255) * 255/219 ≈ 1.09, saturate → 1.0
        var white: UInt8 = 255
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        return tex
    }()

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

        // Add indicator AFTER metalView so it renders on top of the Metal layer
        addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])
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

    // MARK: - Load (File-based)

    func load(fileURL: URL) {
        transition(to: .loading)
        print("[Demux] loading \(fileURL.lastPathComponent)")
        DispatchQueue.global(qos: .userInitiated).async {
            guard let demux = WebMDemuxer(fileURL: fileURL) else {
                print("❌ [Demux] parse failed or 0 frames")
                self.transition(to: .error("Failed to parse WebM file"))
                return
            }
            print("✅ [Demux] \(demux.frames.count) frames, \(demux.width)×\(demux.height)")
            DispatchQueue.main.async { self.setupWithSource(demux) }
        }
    }

    // MARK: - Load (DASH Streaming)

    func loadStream(controller: DASHStreamController) {
        transition(to: .loading)
        print("[DASH] Loading stream controller...")
        controller.onReady = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.setupWithSource(controller)
                self.play()
            }
        }
        controller.onError = { [weak self] error in
            print("❌ [DASH] \(error)")
            self?.transition(to: .error(error))
        }
        controller.startStreaming()
    }

    // MARK: - Common Setup

    private func setupWithSource(_ source: VP9FrameSource) {
        frameSource = source

        colorDecoder = LibVPXDecoder(width: source.width, height: source.height, device: device)
        alphaDecoder = LibVPXDecoder(width: source.width, height: source.height, device: device)

        let ready = colorDecoder != nil && alphaDecoder != nil
        onDecoderReady?(ready)
        guard ready else { return }

        // Setup audio if the source has an audio track
        if source.hasAudio, let config = source.audioConfig {
            audioPlayer = AudioPlayer(config: config)
            print("✅ [Player] Audio track detected: \(config.codecID)")
        } else {
            print("ℹ️ [Player] No audio track (video-only)")
        }

        // Pre-decode first frame
        decodeQueue.async { self.decodeAndBuffer(index: 0) }
    }

    // MARK: - Playback Control

    func play() {
        // Resume from paused without resetting
        if let paused = pausedTime {
            startTime = CACurrentMediaTime() - paused
            pausedTime = nil
            displayLink?.isPaused = false
            audioPlayer?.resume()
            isPlaying = true
            transition(to: .playing)
            return
        }

        guard let source = frameSource, source.isReady, !isPlaying else { return }
        isPlaying  = true
        frameIndex = 0
        textureLock.lock(); decodedFrameIdx = -1; textureLock.unlock()
        source.resetPlayback()

        // Pre-buffer audio
        if let audio = audioPlayer, source.hasAudio {
            let packets = source.audioPackets(upTo: 0.5)  // first 500ms
            for pkt in packets {
                audio.schedulePacket(data: pkt.data)
            }
            audio.start()
        }

        startTime  = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = .init(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
        transition(to: .playing)
    }

    func pause() {
        guard state == .playing else { return }
        pausedTime = currentTime
        displayLink?.isPaused = true
        audioPlayer?.pause()
        isPlaying = false
        transition(to: .paused)
    }

    func seek(to time: TimeInterval) {
        guard let source = frameSource else { return }
        let clampedTime = max(0, min(time, source.totalDuration ?? time))

        startTime = CACurrentMediaTime() - clampedTime
        if state == .paused {
            pausedTime = clampedTime
        }
        frameIndex = Int(clampedTime * 30)
        textureLock.lock(); decodedFrameIdx = -1; textureLock.unlock()

        // Reset audio: stop → flush → re-feed from new position
        audioPlayer?.stop()
        source.resetPlayback()
        let lead = source.audioPackets(upTo: clampedTime + 0.5)
        lead.forEach { audioPlayer?.schedulePacket(data: $0.data) }
        if state == .playing { audioPlayer?.start() }
    }

    func stop() {
        isPlaying = false
        pausedTime = nil
        displayLink?.invalidate()
        displayLink = nil
        audioPlayer?.stop()
    }

    // MARK: - State

    private func transition(to newState: PlayerState) {
        state = newState
        let applyUI = { [weak self] in
            guard let self else { return }
            switch newState {
            case .loading, .buffering: self.loadingIndicator.startAnimating()
            default:                  self.loadingIndicator.stopAnimating()
            }
            self.onStateChange?(newState)
        }
        if Thread.isMainThread { applyUI() } else { DispatchQueue.main.async(execute: applyUI) }
    }

    private func enterBuffering() {
        let t = currentTime
        print("⏸ [Audio] Pausing audio at \(String(format: "%.2f", t))s")
        pausedTime = t
        audioPlayer?.pause()
        transition(to: .buffering)
    }

    private func exitBuffering() {
        if let t = pausedTime {
            startTime = CACurrentMediaTime() - t
            pausedTime = nil
            print("▶️ [Audio] Resuming audio from \(String(format: "%.2f", t))s")
        }
        audioPlayer?.resume()
        transition(to: .playing)
    }

    // MARK: - Display link

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let source = frameSource else { return }
        let count = source.frameCount
        guard count > 0 else { return }

        let elapsed = CACurrentMediaTime() - startTime
        let fps: Double = 30
        let targetIdx = Int(elapsed * fps)

        onTimeUpdate?(currentTime)

        // ── Stall detection ────────────────────────────────────────────────────
        //
        // Two conditions that require buffering:
        //
        // 1. DASH download stall: targetIdx is past what's been downloaded.
        //    But only if we're not genuinely at the end of the stream.
        let isAtTrueEnd = source.totalDuration.map { elapsed >= $0 - 0.1 } ?? false
        let downloadStall = targetIdx >= count && !isAtTrueEnd

        // 2. Decode stall: the background decode thread hasn't finished the
        //    frame we need yet (decodedFrameIdx hasn't reached targetIdx).
        textureLock.lock()
        let decoded = decodedFrameIdx
        textureLock.unlock()
        let decodeStall = decoded < targetIdx && decoded >= 0  // decoded >= 0 skips startup

        let shouldBuffer = downloadStall || decodeStall

        switch state {
        case .playing where shouldBuffer:
            let reason = downloadStall ? "DASH download stall (frame \(targetIdx) >= buffered \(count))"
                                       : "decode stall (decoded=\(decoded) < target=\(targetIdx))"
            print("⏸ [Player] Buffering — \(reason)")
            enterBuffering()
            // Kick the decode loop so it catches up while we wait
            let catchUpIdx = min(targetIdx, count - 1)
            decodeQueue.async { self.decodeAndBuffer(index: catchUpIdx) }
            return

        case .buffering where shouldBuffer:
            return  // still not ready — keep polling each display link tick

        case .buffering where !shouldBuffer:
            print("▶️ [Player] Buffering resolved — resuming at \(String(format: "%.2f", currentTime))s")
            exitBuffering()   // recovered — fall through to render

        default:
            break
        }
        // ── End stall detection ────────────────────────────────────────────────

        // End-of-stream detection (only reached when !downloadStall)
        if targetIdx >= count {
            if isLooping {
                startTime = CACurrentMediaTime()
                frameIndex = 0
                audioPlayer?.stop()
                source.resetPlayback()
                if let audio = audioPlayer, source.hasAudio {
                    let packets = source.audioPackets(upTo: 0.5)
                    for pkt in packets { audio.schedulePacket(data: pkt.data) }
                    audio.start()
                }
            } else {
                stop()
                transition(to: .ended)
                onPlaybackEnd?()
                return
            }
        }

        let idx = min(targetIdx, count - 1)
        guard idx != frameIndex || frameIndex == 0 else {
            metalView.draw()
            return
        }
        frameIndex = idx

        // Feed audio packets up to the current time
        feedAudio(elapsed: elapsed)

        // Kick off next frame decode on background queue
        let nextIdx = (idx + 1) % count
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

    private func feedAudio(elapsed: TimeInterval) {
        guard let source = frameSource, let audio = audioPlayer, source.hasAudio else { return }
        let packets = source.audioPackets(upTo: elapsed)
        for pkt in packets {
            audio.schedulePacket(data: pkt.data)
        }
    }

    // MARK: - Decode (parallel color + alpha)

    private func decodeAndBuffer(index: Int) {
        guard let source = frameSource,
              let cd = colorDecoder,
              let ad = alphaDecoder else { return }

        guard let colorData = source.colorData(at: index) else { return }
        let alphaData = source.alphaData(at: index)

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
        decodedFrameIdx = index   // mark which frame is now ready in next* textures
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
        // Alpha Y — use opaque white fallback when no alpha data (fully opaque)
        encoder.setFragmentTexture(alphaYTex ?? opaqueAlphaTexture ?? yTex, index: 3)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
