import Foundation
import Metal
import CoreMedia

// MARK: - Decoded YUV frame — GPU-ready plane textures

struct YUVFrame {
    let yTexture: MTLTexture    // W×H     R8Unorm (luma)
    let uTexture: MTLTexture    // W/2×H/2 R8Unorm (Cb)
    let vTexture: MTLTexture    // W/2×H/2 R8Unorm (Cr)
}

struct AlphaFrame {
    let yTexture: MTLTexture    // W×H R8Unorm (luma = alpha)
}

// MARK: - LibVPX Software VP9 Decoder (YUV-direct path)

/// Decodes raw VP9 frame data using libvpx via VPXBridge.
/// Returns raw YUV planes uploaded directly to Metal textures.
///
/// Uses ping-pong texture sets: while the GPU renders set A,
/// the CPU can write into set B without a race condition.
final class LibVPXDecoder {

    private let handle: VPXDecoderRef
    let width:  Int
    let height: Int

    // Ping-pong: two sets of Y/U/V textures to avoid write-while-render race
    private let yTextures: [MTLTexture]   // [0] and [1]
    private let uTextures: [MTLTexture]
    private let vTextures: [MTLTexture]
    private var slot = 0                  // toggles 0 ↔ 1

    init?(width: Int, height: Int, device: MTLDevice) {
        self.width  = width
        self.height = height

        guard let h = vpx_bridge_create(Int32(width), Int32(height), 2) else {
            print("❌ [libvpx] vpx_bridge_create failed for \(width)×\(height)")
            return nil
        }
        self.handle = h

        let yDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        yDesc.usage = .shaderRead

        let uvW = width / 2
        let uvH = height / 2
        let uvDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: uvW, height: uvH, mipmapped: false)
        uvDesc.usage = .shaderRead

        // Allocate 2 sets (ping-pong)
        var yArr = [MTLTexture](), uArr = [MTLTexture](), vArr = [MTLTexture]()
        for _ in 0..<2 {
            guard let y = device.makeTexture(descriptor: yDesc),
                  let u = device.makeTexture(descriptor: uvDesc),
                  let v = device.makeTexture(descriptor: uvDesc) else {
                vpx_bridge_destroy(h)
                print("❌ [libvpx] MTLTexture allocation failed")
                return nil
            }
            yArr.append(y); uArr.append(u); vArr.append(v)
        }
        yTextures = yArr; uTextures = uArr; vTextures = vArr

        print("✅ [libvpx] VP9 decoder ready (\(width)×\(height)) — GPU YUV path")
    }

    deinit {
        vpx_bridge_destroy(handle)
    }

    // MARK: - Decode → YUV textures

    func decodeYUV(data: Data) -> YUVFrame? {
        let ok = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return vpx_bridge_decode(handle, base, data.count) == 0
        }
        guard ok else { return nil }

        var planes = VPXYUVPlanes()
        guard vpx_bridge_get_yuv_planes(handle, &planes) == 0 else { return nil }

        let w = Int(planes.width)
        let h = Int(planes.height)
        let s = slot
        slot ^= 1  // flip for next call

        yTextures[s].replace(region: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0,
                             withBytes: planes.y,
                             bytesPerRow: Int(planes.y_stride))

        let uvW = w / 2, uvH = h / 2
        uTextures[s].replace(region: MTLRegionMake2D(0, 0, uvW, uvH),
                             mipmapLevel: 0,
                             withBytes: planes.u,
                             bytesPerRow: Int(planes.u_stride))

        vTextures[s].replace(region: MTLRegionMake2D(0, 0, uvW, uvH),
                             mipmapLevel: 0,
                             withBytes: planes.v,
                             bytesPerRow: Int(planes.v_stride))

        return YUVFrame(yTexture: yTextures[s], uTexture: uTextures[s], vTexture: vTextures[s])
    }

    /// Decode alpha — only uploads Y plane (luma = alpha).
    func decodeAlpha(data: Data) -> AlphaFrame? {
        let ok = data.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return vpx_bridge_decode(handle, base, data.count) == 0
        }
        guard ok else { return nil }

        var planes = VPXYUVPlanes()
        guard vpx_bridge_get_yuv_planes(handle, &planes) == 0 else { return nil }

        let w = Int(planes.width)
        let h = Int(planes.height)
        let s = slot
        slot ^= 1

        yTextures[s].replace(region: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0,
                             withBytes: planes.y,
                             bytesPerRow: Int(planes.y_stride))

        return AlphaFrame(yTexture: yTextures[s])
    }
}
