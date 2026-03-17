import Foundation
import CoreVideo
import CoreMedia

// MARK: - LibVPX Software VP9 Decoder

/// Decodes raw VP9 frame data using libvpx via VPXBridge (software decode).
/// Returns BGRA CVPixelBuffers ready for Metal compositing.
final class LibVPXDecoder {

    private let handle: VPXDecoderRef
    let width:  Int
    let height: Int

    // Pre-allocated BGRA buffer (avoids malloc per frame)
    private let bgraBuffer: UnsafeMutablePointer<UInt8>
    private let bgraStride: Int
    private let bgraSize: Int

    // Pixel buffer pool for efficient CVPixelBuffer allocation
    private var pixelBufferPool: CVPixelBufferPool?

    init?(width: Int, height: Int) {
        self.width  = width
        self.height = height
        self.bgraStride = width * 4
        self.bgraSize = bgraStride * height

        guard let h = vpx_bridge_create(Int32(width), Int32(height), /* threads */ 2) else {
            print("❌ [libvpx] vpx_bridge_create failed for \(width)×\(height)")
            return nil
        }
        self.handle = h
        self.bgraBuffer = .allocate(capacity: bgraSize)

        // CVPixelBufferPool for zero-copy Metal texture uploads
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey  as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                poolAttrs as CFDictionary, &pixelBufferPool)

        print("✅ [libvpx] VP9 software decoder ready (\(width)×\(height))")
    }

    deinit {
        vpx_bridge_destroy(handle)
        bgraBuffer.deallocate()
    }

    // MARK: - Public API

    /// Decode one raw VP9 frame and return a BGRA CVPixelBuffer, or nil on error.
    func decode(data: Data, pts: CMTime, isKeyframe: Bool) -> CVPixelBuffer? {

        // 1. Feed raw VP9 bitstream to libvpx
        let decodeOK = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            return vpx_bridge_decode(handle, base, data.count) == 0
        }

        guard decodeOK else {
            if let errStr = vpx_bridge_error(handle) {
                print("❌ [libvpx] decode error: \(String(cString: errStr))")
            }
            return nil
        }

        // 2. Get decoded BGRA pixels (YUV→BGRA conversion happens in C for speed)
        var outW: Int32 = 0
        var outH: Int32 = 0
        let getOK = vpx_bridge_get_frame_bgra(
            handle,
            bgraBuffer,
            Int32(bgraStride),
            &outW, &outH
        )
        guard getOK == 0 else { return nil }

        // 3. Wrap in CVPixelBuffer for Metal
        return makePixelBuffer(width: Int(outW), height: Int(outH))
    }

    // MARK: - CVPixelBuffer creation

    private func makePixelBuffer(width w: Int, height h: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let status: CVReturn
        if let pool = pixelBufferPool {
            status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        } else {
            status = CVPixelBufferCreate(
                kCFAllocatorDefault, w, h,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pb
            )
        }
        guard status == kCVReturnSuccess, let pixelBuffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let dst = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Copy BGRA rows from our C-side buffer into the CVPixelBuffer
        let src = bgraBuffer
        if dstStride == bgraStride {
            // Fast path — single memcpy
            memcpy(dst, src, bgraStride * h)
        } else {
            // Row-by-row copy (strides differ due to CVPixelBuffer alignment)
            let rowBytes = min(bgraStride, dstStride)
            for row in 0 ..< h {
                memcpy(dst + row * dstStride, src + row * bgraStride, rowBytes)
            }
        }

        return pixelBuffer
    }
}
