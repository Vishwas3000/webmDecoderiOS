import Foundation
import CoreMedia

// MARK: - Output model

/// One frame pair: color VP9 bitstream + optional alpha VP9 bitstream.
struct VP9FramePair {
    let pts: CMTime          // presentation timestamp (milliseconds time base)
    let isKeyframe: Bool
    let colorData: Data      // raw VP9 frame — Track 1 (or the main Block)
    let alphaData: Data?     // raw VP9 frame — BlockAdditional id=1, or nil
}

// MARK: - WebM Demuxer

/// Parses a VP9+alpha WebM/Matroska file and returns all frame pairs.
/// Alpha is expected in BlockAdditional (BlockAddID=1) inside BlockGroup elements.
final class WebMDemuxer {

    // Video dimensions (from the first TrackEntry with type video)
    private(set) var width:  Int = 0
    private(set) var height: Int = 0

    // All parsed frame pairs, ordered by PTS
    private(set) var frames: [VP9FramePair] = []

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        parse(data: data)
        frames.sort { $0.pts < $1.pts }
        guard !frames.isEmpty else { return nil }
    }

    // MARK: - Top-level parse

    private func parse(data: Data) {
        let r = EBMLReader(data: data)

        while !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }

            switch id {
            case EBMLID.ebmlHeader.rawValue:
                r.skip(size ?? 0)           // skip EBML header, we already know it's WebM

            case EBMLID.segment.rawValue:
                // size can be nil (unknown size) — parse children until end of data
                let segEnd = size.map { r.cursor + $0 } ?? data.count
                parseSegment(r, end: segEnd)

            default:
                r.skip(size ?? 0)
            }
        }
    }

    // MARK: - Segment children

    private func parseSegment(_ r: EBMLReader, end: Int) {
        while r.cursor < end && !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end

            switch id {
            case EBMLID.tracks.rawValue:
                parseTracks(r, end: elementEnd)

            case EBMLID.cluster.rawValue:
                parseCluster(r, end: elementEnd)

            default:
                r.seek(to: elementEnd)
            }
        }
    }

    // MARK: - Tracks

    private func parseTracks(_ r: EBMLReader, end: Int) {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end

            if id == EBMLID.trackEntry.rawValue {
                parseTrackEntry(r, end: elementEnd)
            } else {
                r.seek(to: elementEnd)
            }
        }
    }

    private func parseTrackEntry(_ r: EBMLReader, end: Int) {
        var trackType: UInt64 = 0
        var localWidth = 0
        var localHeight = 0

        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.trackType.rawValue:
                trackType = r.readUInt(bytes: sz) ?? 0

            case EBMLID.video.rawValue:
                parseVideoElement(r, end: elementEnd,
                                  width: &localWidth, height: &localHeight)

            default:
                r.seek(to: elementEnd)
            }
        }

        if trackType == 1 && localWidth > 0 && localHeight > 0 {
            width  = localWidth
            height = localHeight
        }
    }

    private func parseVideoElement(_ r: EBMLReader, end: Int,
                                   width: inout Int, height: inout Int) {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let sz = size ?? 0
            switch id {
            case EBMLID.pixelWidth.rawValue:
                width = Int(r.readUInt(bytes: sz) ?? 0)
            case EBMLID.pixelHeight.rawValue:
                height = Int(r.readUInt(bytes: sz) ?? 0)
            default:
                r.skip(sz)
            }
        }
    }

    // MARK: - Cluster

    private func parseCluster(_ r: EBMLReader, end: Int) {
        var clusterTimecode: Int64 = 0

        while r.cursor < end && !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.timecode.rawValue:
                clusterTimecode = Int64(r.readUInt(bytes: sz) ?? 0)

            case EBMLID.simpleBlock.rawValue:
                if let frame = parseSimpleBlock(r, size: sz, clusterTimecode: clusterTimecode) {
                    frames.append(frame)
                } else {
                    r.seek(to: elementEnd)
                }

            case EBMLID.blockGroup.rawValue:
                if let frame = parseBlockGroup(r, end: elementEnd, clusterTimecode: clusterTimecode) {
                    frames.append(frame)
                } else {
                    r.seek(to: elementEnd)
                }

            default:
                r.seek(to: elementEnd)
            }
        }
    }

    // MARK: - SimpleBlock (no alpha extension support — alpha uses BlockGroup)

    private func parseSimpleBlock(_ r: EBMLReader, size: Int,
                                  clusterTimecode: Int64) -> VP9FramePair? {
        let start = r.cursor
        guard size > 4 else { r.skip(size); return nil }

        // Track number VINT
        guard let _ = r.readID() else { return nil }  // track number as VINT

        // 2-byte signed relative timecode
        guard let tcBytes = r.readBytes(2) else { return nil }
        let relTC = Int16(bitPattern: UInt16(tcBytes[0]) << 8 | UInt16(tcBytes[1]))

        // Flags byte
        guard let flags = r.readByte() else { return nil }
        let isKeyframe = (flags & 0x80) != 0

        // Remaining bytes = VP9 frame data
        let headerConsumed = r.cursor - start
        let frameSize = size - headerConsumed
        guard frameSize > 0, let frameData = r.readBytes(frameSize) else { return nil }

        let ptsMsec = clusterTimecode + Int64(relTC)
        let pts = CMTime(value: ptsMsec, timescale: 1000)
        return VP9FramePair(pts: pts, isKeyframe: isKeyframe,
                            colorData: frameData, alphaData: nil)
    }

    // MARK: - BlockGroup (carries BlockAdditions for alpha)

    private func parseBlockGroup(_ r: EBMLReader, end: Int,
                                 clusterTimecode: Int64) -> VP9FramePair? {
        var colorData: Data?
        var alphaData: Data?
        var pts: CMTime = .zero
        var isKeyframe = false

        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.block.rawValue:
                // Parse the main Block (same header layout as SimpleBlock, but no keyframe flag here)
                let blockStart = r.cursor
                guard sz > 4 else { r.skip(sz); break }

                guard let _ = r.readID() else { break }    // track number VINT
                guard let tcBytes = r.readBytes(2) else { break }
                let relTC = Int16(bitPattern: UInt16(tcBytes[0]) << 8 | UInt16(tcBytes[1]))
                guard let flags = r.readByte() else { break }
                isKeyframe = (flags & 0x80) != 0

                let headerConsumed = r.cursor - blockStart
                let frameSize = sz - headerConsumed
                if frameSize > 0, let fd = r.readBytes(frameSize) {
                    colorData = fd
                }
                let ptsMsec = clusterTimecode + Int64(relTC)
                pts = CMTime(value: ptsMsec, timescale: 1000)

            case EBMLID.blockAdditions.rawValue:
                alphaData = parseBlockAdditions(r, end: elementEnd)

            default:
                r.seek(to: elementEnd)
            }
        }

        guard let color = colorData else { return nil }
        return VP9FramePair(pts: pts, isKeyframe: isKeyframe,
                            colorData: color, alphaData: alphaData)
    }

    // MARK: - BlockAdditions → BlockMore → BlockAdditional (id=1 → alpha)

    private func parseBlockAdditions(_ r: EBMLReader, end: Int) -> Data? {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end

            if id == EBMLID.blockMore.rawValue {
                if let data = parseBlockMore(r, end: elementEnd) {
                    return data
                }
            } else {
                r.seek(to: elementEnd)
            }
        }
        return nil
    }

    private func parseBlockMore(_ r: EBMLReader, end: Int) -> Data? {
        var addID: UInt64 = 0
        var addData: Data?

        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let sz = size ?? 0
            let elementEnd = r.cursor + sz

            switch id {
            case EBMLID.blockAddID.rawValue:
                addID = r.readUInt(bytes: sz) ?? 0
            case EBMLID.blockAdditional.rawValue:
                addData = r.readBytes(sz)
            default:
                r.seek(to: elementEnd)
            }
        }

        // BlockAddID=1 is the VP9 alpha channel data
        return addID == 1 ? addData : nil
    }

    // MARK: - Helpers

    /// Reads a size VINT; if size is nil (unknown size), returns nil so callers use the container end.
    private func readElementSize(_ r: EBMLReader) -> Int?? {
        // Double optional: .some(nil) = unknown size, .none = parse error
        guard r.remaining > 0 else { return .none }
        let s = r.readSize()   // returns nil for unknown-size sentinel
        return .some(s)
    }
}

// Allow CMTime comparison for sort
extension CMTime: Comparable {
    public static func < (lhs: CMTime, rhs: CMTime) -> Bool {
        CMTimeCompare(lhs, rhs) < 0
    }
}
