import Foundation
import CoreMedia

// MARK: - Streaming Frame Types

/// A single video frame from a DASH segment — holds Data slices directly (not file offsets).
struct StreamingFrame {
    let pts: CMTime
    let isKeyframe: Bool
    let colorData: Data
    let alphaData: Data?       // nil if no alpha
}

/// A single audio packet from a DASH segment.
struct StreamingAudioPacket {
    let pts: CMTime
    let data: Data
}

/// Parsed frames from one DASH media segment.
/// Retains the segment's raw Data so that the frame/packet Data slices remain valid.
final class SegmentFrames {
    let segmentData: Data
    let videoFrames: [StreamingFrame]
    let audioPackets: [StreamingAudioPacket]

    init(segmentData: Data, videoFrames: [StreamingFrame], audioPackets: [StreamingAudioPacket]) {
        self.segmentData = segmentData
        self.videoFrames = videoFrames
        self.audioPackets = audioPackets
    }
}

// MARK: - WebM Segment Demuxer

/// Parses individual DASH WebM segments (init + media).
/// Reuses the same EBML parsing approach as WebMDemuxer but works per-segment
/// instead of on a complete file.
final class WebMSegmentDemuxer {

    // Parsed from init segment
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var audioConfig: AudioTrackConfig?
    private(set) var videoTrackNumber: UInt64 = 1
    private(set) var audioTrackNumber: UInt64 = 0

    private var codecPrivateData: Data?

    // MARK: - Init Segment

    /// Parse the DASH initialization segment.
    /// Contains EBML header + Segment with Tracks element (no Clusters).
    /// Returns true if video track was found.
    @discardableResult
    func parseInitSegment(data: Data) -> Bool {
        let r = EBMLReader(data: data)

        while !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            switch id {
            case EBMLID.ebmlHeader.rawValue:
                r.skip(size ?? 0)
            case EBMLID.segment.rawValue:
                let segEnd = size.map { r.cursor + $0 } ?? data.count
                parseSegmentInit(r, end: segEnd)
            default:
                r.skip(size ?? 0)
            }
        }

        return width > 0 && height > 0
    }

    private func parseSegmentInit(_ r: EBMLReader, end: Int) {
        while r.cursor < end && !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            switch id {
            case EBMLID.tracks.rawValue:
                parseTracks(r, end: elementEnd)
            default:
                r.seek(to: elementEnd)
            }
        }
    }

    // MARK: - Media Segment

    /// Parse a DASH media segment (one or more Clusters).
    /// Returns SegmentFrames containing video frames and audio packets.
    func parseMediaSegment(data: Data) -> SegmentFrames {
        let r = EBMLReader(data: data)
        var videoFrames: [StreamingFrame] = []
        var audioPackets: [StreamingAudioPacket] = []

        while !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? data.count

            switch id {
            case EBMLID.cluster.rawValue:
                parseCluster(r, end: elementEnd, data: data,
                             videoFrames: &videoFrames, audioPackets: &audioPackets)
            case EBMLID.segment.rawValue:
                // Some DASH segments wrap the Cluster in a Segment element
                continue  // parse children
            default:
                r.seek(to: elementEnd)
            }
        }

        videoFrames.sort { $0.pts < $1.pts }
        audioPackets.sort { $0.pts < $1.pts }

        return SegmentFrames(segmentData: data,
                             videoFrames: videoFrames,
                             audioPackets: audioPackets)
    }

    // MARK: - Tracks Parsing (same logic as WebMDemuxer)

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
        var trackNum: UInt64 = 0
        var trackType: UInt64 = 0
        var codecIDStr = ""
        var localWidth = 0, localHeight = 0
        var sampleRate: Double = 0
        var channelCount = 0
        var cpData: Data?

        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.trackNumber.rawValue:
                trackNum = r.readUInt(bytes: sz) ?? 0
            case EBMLID.trackType.rawValue:
                trackType = r.readUInt(bytes: sz) ?? 0
            case EBMLID.codecID.rawValue:
                codecIDStr = r.readString(length: sz) ?? ""
            case EBMLID.codecPrivate.rawValue:
                cpData = r.readBytes(sz).map { Data($0) }
            case EBMLID.video.rawValue:
                parseVideoElement(r, end: elementEnd, width: &localWidth, height: &localHeight)
            case EBMLID.audio.rawValue:
                parseAudioElement(r, end: elementEnd, sampleRate: &sampleRate, channels: &channelCount)
            default:
                r.seek(to: elementEnd)
            }
        }

        if trackType == 1 && localWidth > 0 && localHeight > 0 {
            width = localWidth; height = localHeight
            videoTrackNumber = trackNum
        }

        if trackType == 2 && sampleRate > 0 && channelCount > 0 {
            audioTrackNumber = trackNum
            codecPrivateData = cpData
            audioConfig = AudioTrackConfig(
                trackNumber: trackNum, codecID: codecIDStr,
                sampleRate: sampleRate, channels: channelCount,
                codecPrivateOffset: 0, codecPrivateSize: cpData?.count ?? 0)
            print("[SegDemux] Audio track #\(trackNum): \(codecIDStr) \(sampleRate)Hz \(channelCount)ch")
        }
    }

    private func parseVideoElement(_ r: EBMLReader, end: Int,
                                   width: inout Int, height: inout Int) {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let sz = size ?? 0
            switch id {
            case EBMLID.pixelWidth.rawValue:  width = Int(r.readUInt(bytes: sz) ?? 0)
            case EBMLID.pixelHeight.rawValue: height = Int(r.readUInt(bytes: sz) ?? 0)
            default: r.skip(sz)
            }
        }
    }

    private func parseAudioElement(_ r: EBMLReader, end: Int,
                                   sampleRate: inout Double, channels: inout Int) {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let sz = size ?? 0
            switch id {
            case EBMLID.samplingFreq.rawValue:
                if sz == 8, let d = r.readBytes(sz) {
                    let bits = d.withUnsafeBytes { ptr -> UInt64 in
                        var v: UInt64 = 0; for byte in ptr { v = (v << 8) | UInt64(byte) }; return v
                    }
                    sampleRate = Double(bitPattern: bits)
                } else if sz == 4, let d = r.readBytes(sz) {
                    let bits = d.withUnsafeBytes { ptr -> UInt32 in
                        var v: UInt32 = 0; for byte in ptr { v = (v << 8) | UInt32(byte) }; return v
                    }
                    sampleRate = Double(Float(bitPattern: bits))
                } else {
                    sampleRate = Double(r.readUInt(bytes: sz) ?? 0)
                }
            case EBMLID.channels.rawValue:
                channels = Int(r.readUInt(bytes: sz) ?? 0)
            default:
                r.skip(sz)
            }
        }
    }

    // MARK: - Cluster Parsing

    private func parseCluster(_ r: EBMLReader, end: Int, data: Data,
                              videoFrames: inout [StreamingFrame],
                              audioPackets: inout [StreamingAudioPacket]) {
        var clusterTimecode: Int64 = 0

        while r.cursor < end && !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.timecode.rawValue:
                clusterTimecode = Int64(r.readUInt(bytes: sz) ?? 0)

            case EBMLID.simpleBlock.rawValue:
                parseSimpleBlock(r, size: sz, clusterTimecode: clusterTimecode,
                                 data: data, videoFrames: &videoFrames, audioPackets: &audioPackets)
                if r.cursor < elementEnd { r.seek(to: elementEnd) }

            case EBMLID.blockGroup.rawValue:
                if let frame = parseBlockGroup(r, end: elementEnd, clusterTimecode: clusterTimecode, data: data) {
                    videoFrames.append(frame)
                } else {
                    r.seek(to: elementEnd)
                }

            default:
                r.seek(to: elementEnd)
            }
        }
    }

    private func parseSimpleBlock(_ r: EBMLReader, size: Int, clusterTimecode: Int64,
                                  data: Data,
                                  videoFrames: inout [StreamingFrame],
                                  audioPackets: inout [StreamingAudioPacket]) {
        let start = r.cursor
        guard size > 4 else { r.skip(size); return }

        guard let trackNumRaw = r.readID() else { return }
        let trackNum = UInt64(stripVINTMarker(trackNumRaw))

        guard let tcBytes = r.readBytes(2) else { return }
        let relTC = Int16(bitPattern: UInt16(tcBytes[0]) << 8 | UInt16(tcBytes[1]))
        guard let flags = r.readByte() else { return }
        let isKeyframe = (flags & 0x80) != 0

        let headerConsumed = r.cursor - start
        let frameSize = size - headerConsumed
        guard frameSize > 0 else { return }

        let frameOffset = r.cursor
        r.skip(frameSize)

        let ptsMsec = clusterTimecode + Int64(relTC)
        let pts = CMTime(value: ptsMsec, timescale: 1000)
        let frameData = data[frameOffset ..< frameOffset + frameSize]

        if trackNum == audioTrackNumber && audioTrackNumber != 0 {
            audioPackets.append(StreamingAudioPacket(pts: pts, data: frameData))
        } else {
            videoFrames.append(StreamingFrame(pts: pts, isKeyframe: isKeyframe,
                                              colorData: frameData, alphaData: nil))
        }
    }

    private func parseBlockGroup(_ r: EBMLReader, end: Int, clusterTimecode: Int64,
                                 data: Data) -> StreamingFrame? {
        var colorOffset = 0, colorSize = 0
        var alphaOffset = 0, alphaSize = 0
        var pts: CMTime = .zero
        var isKeyframe = false

        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            let sz = size ?? 0

            switch id {
            case EBMLID.block.rawValue:
                let blockStart = r.cursor
                guard sz > 4 else { r.skip(sz); break }
                guard let _ = r.readID() else { break }
                guard let tcBytes = r.readBytes(2) else { break }
                let relTC = Int16(bitPattern: UInt16(tcBytes[0]) << 8 | UInt16(tcBytes[1]))
                guard let flags = r.readByte() else { break }
                isKeyframe = (flags & 0x80) != 0
                let headerConsumed = r.cursor - blockStart
                let frameSize = sz - headerConsumed
                if frameSize > 0 {
                    colorOffset = r.cursor; colorSize = frameSize
                    r.skip(frameSize)
                }
                let ptsMsec = clusterTimecode + Int64(relTC)
                pts = CMTime(value: ptsMsec, timescale: 1000)

            case EBMLID.blockAdditions.rawValue:
                let result = parseBlockAdditions(r, end: elementEnd)
                alphaOffset = result.offset; alphaSize = result.size

            default:
                r.seek(to: elementEnd)
            }
        }

        guard colorSize > 0 else { return nil }

        let colorData = data[colorOffset ..< colorOffset + colorSize]
        let alphaData = alphaSize > 0 ? data[alphaOffset ..< alphaOffset + alphaSize] : nil

        return StreamingFrame(pts: pts, isKeyframe: isKeyframe,
                              colorData: colorData, alphaData: alphaData)
    }

    // MARK: - BlockAdditions

    private func parseBlockAdditions(_ r: EBMLReader, end: Int) -> (offset: Int, size: Int) {
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            if id == EBMLID.blockMore.rawValue {
                let result = parseBlockMore(r, end: elementEnd)
                if result.size > 0 { return result }
            } else { r.seek(to: elementEnd) }
        }
        return (0, 0)
    }

    private func parseBlockMore(_ r: EBMLReader, end: Int) -> (offset: Int, size: Int) {
        var addID: UInt64 = 0
        var dataOffset = 0, dataSize = 0
        while r.cursor < end {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let sz = size ?? 0
            let elementEnd = r.cursor + sz
            switch id {
            case EBMLID.blockAddID.rawValue:      addID = r.readUInt(bytes: sz) ?? 0
            case EBMLID.blockAdditional.rawValue:  dataOffset = r.cursor; dataSize = sz; r.skip(sz)
            default: r.seek(to: elementEnd)
            }
        }
        return addID == 1 ? (dataOffset, dataSize) : (0, 0)
    }

    // MARK: - Helpers

    private func readElementSize(_ r: EBMLReader) -> Int?? {
        guard r.remaining > 0 else { return .none }
        return .some(r.readSize())
    }

    private func stripVINTMarker(_ raw: UInt32) -> UInt32 {
        if raw >= 0x80   && raw <= 0xFF       { return raw & 0x7F }
        if raw >= 0x4000 && raw <= 0x7FFF     { return raw & 0x3FFF }
        if raw >= 0x200000 && raw <= 0x3FFFFF { return raw & 0x1FFFFF }
        if raw >= 0x10000000                  { return raw & 0x0FFFFFFF }
        return raw
    }
}
