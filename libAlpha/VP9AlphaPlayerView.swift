import UIKit
import Metal
import MetalKit
import CoreMedia

// MARK: - VP9AlphaPlayerView

/// A UIView subclass that:
///   1. Demuxes a VP9+alpha WebM file
///   2. Decodes each frame pair using libvpx software VP9 decoder (color + alpha)
///   3. Composites them with a Metal shader
///   4. Displays the result via MTKView at the source frame rate
final class VP9AlphaPlayerView: UIView {

    // MARK: Public

    var isLooping = true
    var onPlaybackEnd: (() -> Void)?
    /// Called after load() finishes — `true` if decoders initialised, `false` if VP9 unavailable.
    var onDecoderReady: ((Bool) -> Void)?
    private var drawCount = 0
    // MARK: Private — Metal

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?
    private var metalView: MTKView!

    // Textures uploaded each frame
    private var colorTexture: MTLTexture?
    private var alphaTexture: MTLTexture?
    private let textureCache: CVMetalTextureCache

    // MARK: Private — Playback

    private var demuxer: WebMDemuxer?
    private var colorDecoder: LibVPXDecoder?
    private var alphaDecoder: LibVPXDecoder?

    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var frameIndex: Int = 0
    private var isPlaying = false

    // Background decode queue — keeps UI thread free
    private let decodeQueue = DispatchQueue(label: "vp9.decode", qos: .userInteractive)

    // Double-buffer: decoded textures ready for the next render pass
    private var nextColorTexture: MTLTexture?
    private var nextAlphaTexture: MTLTexture?
    private let textureLock = NSLock()

    // MARK: - Init

    override init(frame: CGRect) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq  = dev.makeCommandQueue() else {
            fatalError("VP9AlphaPlayerView: Metal unavailable on this device.")
        }
        device       = dev
        commandQueue = cq

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        textureCache = cache!

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

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        textureCache = cache!

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
        metalView.isPaused            = true       // we drive via CADisplayLink
        metalView.enableSetNeedsDisplay = false
        metalView.isOpaque            = false
        metalView.layer.isOpaque      = false
        addSubview(metalView)
    }

    private func buildRenderPipeline() {
        guard let lib = device.makeDefaultLibrary() else {
            print("❌ [Metal] makeDefaultLibrary failed — Metal shader not compiled into bundle")
            return
        }
        print("✅ [Metal] library loaded, functions: \(lib.functionNames)")

        guard let vertFn = lib.makeFunction(name: "compositor_vertex") else {
            print("❌ [Metal] compositor_vertex not found in library")
            return
        }
        guard let fragFn = lib.makeFunction(name: "compositor_fragment") else {
            print("❌ [Metal] compositor_fragment not found in library")
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
            print("✅ [Metal] render pipeline created")
        } catch {
            print("❌ [Metal] pipeline creation failed: \(error)")
        }
    }

    // MARK: - Load & Play

    func load(fileURL: URL) {
        print("📂 [Demux] loading \(fileURL.lastPathComponent)")
        guard let demux = WebMDemuxer(fileURL: fileURL) else {
            print("❌ [Demux] WebMDemuxer returned nil — parse failed or 0 frames")
            return
        }
        print("✅ [Demux] \(demux.frames.count) frames, \(demux.width)×\(demux.height)")

        let withAlpha = demux.frames.filter { $0.alphaData != nil }.count
        print("   [Demux] frames with alpha data: \(withAlpha)/\(demux.frames.count)")

        demuxer = demux

        colorDecoder = LibVPXDecoder(width: demux.width, height: demux.height)
        if colorDecoder == nil { print("❌ [libvpx] color decoder init failed") }
        else                   { print("✅ [libvpx] color decoder ready") }

        alphaDecoder = LibVPXDecoder(width: demux.width, height: demux.height)
        if alphaDecoder == nil { print("❌ [libvpx] alpha decoder init failed") }
        else                   { print("✅ [libvpx] alpha decoder ready") }

        let decodersReady = colorDecoder != nil && alphaDecoder != nil
        onDecoderReady?(decodersReady)
        guard decodersReady else { return }

        // Pre-decode first frame so display is immediate on play()
        decodeQueue.async { self.decodeAndBuffer(index: 0) }
    }

    func play() {
        guard demuxer != nil, !isPlaying else { return }
        isPlaying  = true
        frameIndex = 0
        startTime  = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        displayLink?.preferredFrameRateRange = .init(minimum: 30, maximum: 30, preferred: 30)
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Display link

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let frames = demuxer?.frames, !frames.isEmpty else { return }

        let elapsed  = CACurrentMediaTime() - startTime
        let fps: Double = 30
        let targetIdx = Int(elapsed * fps)

        if targetIdx >= frames.count {
            if isLooping {
                startTime = CACurrentMediaTime()
                frameIndex = 0
            } else {
                stop()
                onPlaybackEnd?()
                return
            }
        }

        let idx = min(targetIdx, frames.count - 1)
        guard idx != frameIndex || frameIndex == 0 else {
            metalView.draw()    // redraw with existing textures
            return
        }
        frameIndex = idx

        // Decode next frame on background queue
        let nextIdx = (idx + 1) % frames.count
        decodeQueue.async { self.decodeAndBuffer(index: nextIdx) }

        // Swap in the buffered textures and draw
        textureLock.lock()
        colorTexture = nextColorTexture
        alphaTexture = nextAlphaTexture
        textureLock.unlock()

        metalView.draw()
    }

    // MARK: - Decode

    private func decodeAndBuffer(index: Int) {
        guard let frames = demuxer?.frames,
              let cd = colorDecoder,
              let ad = alphaDecoder,
              index < frames.count else {
            print("⚠️ [Decode] guard failed at index \(index) — demuxer:\(demuxer != nil) cd:\(colorDecoder != nil) ad:\(alphaDecoder != nil)")
            return
        }

        let frame = frames[index]

        let colorBuf = cd.decode(data: frame.colorData,
                                 pts: frame.pts,
                                 isKeyframe: frame.isKeyframe)
        if colorBuf == nil {
            print("❌ [Decode] color decode returned nil at frame \(index) (keyframe=\(frame.isKeyframe), \(frame.colorData.count) bytes)")
        }

        let alphaBuf: CVPixelBuffer?
        if let aData = frame.alphaData {
            alphaBuf = ad.decode(data: aData,
                                  pts: frame.pts,
                                  isKeyframe: frame.isKeyframe)
            if alphaBuf == nil {
                print("❌ [Decode] alpha decode returned nil at frame \(index) (\(aData.count) bytes)")
            }
        } else {
            if index == 0 { print("⚠️ [Decode] frame 0 has no alpha data") }
            alphaBuf = nil
        }

        guard let colorPB = colorBuf else { return }

        let colorTex = makeTexture(from: colorPB)
        let alphaTex = alphaBuf.flatMap { makeTexture(from: $0) }

        if index == 0 {
            print("🖼 [Texture] frame 0 — color:\(colorTex != nil ? "✅" : "❌")  alpha:\(alphaTex != nil ? "✅" : "⚠️ nil (opaque fallback)")")
        }

        textureLock.lock()
        nextColorTexture = colorTex
        nextAlphaTexture = alphaTex
        textureLock.unlock()
    }

    // MARK: - CVPixelBuffer → MTLTexture

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            w, h,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvt = cvTexture else {
            let fmtStr = String(format: "0x%08X", fmt)
            print("❌ [Texture] CVMetalTextureCacheCreateTextureFromImage failed status=\(status) fmt=\(fmtStr) \(w)×\(h)")
            return nil
        }
        return CVMetalTextureGetTexture(cvt)
    }
}

// MARK: - MTKViewDelegate

extension VP9AlphaPlayerView: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // Throttle draw-call noise: only print the first draw and failures


    func draw(in view: MTKView) {
        drawCount += 1
        guard let pipeline = renderPipeline else {
            if drawCount <= 3 { print("❌ [Draw] renderPipeline is nil") }
            return
        }
        guard let drawable = view.currentDrawable else {
            if drawCount <= 3 { print("❌ [Draw] no currentDrawable") }
            return
        }
        guard let passDesc = view.currentRenderPassDescriptor else {
            if drawCount <= 3 { print("❌ [Draw] no currentRenderPassDescriptor") }
            return
        }
        guard let colorTex = colorTexture else {
            if drawCount <= 3 { print("⚠️ [Draw] colorTexture is nil — frame not decoded yet") }
            return
        }
        if drawCount == 1 { print("✅ [Draw] first successful draw, colorTex=\(colorTex.width)×\(colorTex.height) alphaTex=\(alphaTexture != nil ? "✅" : "nil")") }

        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].storeAction = .store

        guard let cmdBuf  = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(colorTex,    index: 0)
        // Fall back to color texture as alpha if no alpha track (renders opaque)
        encoder.setFragmentTexture(alphaTexture ?? colorTex, index: 1)

        // Draw fullscreen quad (4 vertices, triangle-strip)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
