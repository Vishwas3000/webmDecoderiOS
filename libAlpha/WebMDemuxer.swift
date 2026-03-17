import Foundation
import CoreMedia

// MARK: - Output models

/// One video frame pair: offsets into the mmap'd file for color + optional alpha VP9 data.
struct VP9FramePair {
    let pts: CMTime
    let isKeyframe: Bool
    let colorOffset: Int
    let colorSize: Int
    let alphaOffset: Int       // 0 if no alpha
    let alphaSize: Int         // 0 if no alpha

    var hasAlpha: Bool { alphaSize > 0 }
}

/// One audio packet: offset into the mmap'd file.
struct AudioPacket {
    let pts: CMTime
    let offset: Int
    let size: Int
}

/// Audio track configuration parsed from TrackEntry.
struct AudioTrackConfig {
    let trackNumber: UInt64
    let codecID: String           // "A_OPUS" or "A_VORBIS"
    let sampleRate: Double
    let channels: Int
    let codecPrivateOffset: Int   // OpusHead / Vorbis headers in the file
    let codecPrivateSize: Int
}

// MARK: - WebM Demuxer (zero-copy, audio+video)

final class WebMDemuxer {

    private(set) var width:  Int = 0
    private(set) var height: Int = 0
    private(set) var frames: [VP9FramePair] = []

    // Audio
    private(set) var audioConfig: AudioTrackConfig?
    private(set) var audioPackets: [AudioPacket] = []

    // Track number mapping (discovered during Tracks parsing)
    private var videoTrackNumber: UInt64 = 1
    private var audioTrackNumber: UInt64 = 0

    private let fileData: Data

    init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            return nil
        }
        fileData = data
        parse(data: data)
        frames.sort { $0.pts < $1.pts }
        audioPackets.sort { $0.pts < $1.pts }
        guard !frames.isEmpty else { return nil }
    }

    var hasAudio: Bool { audioConfig != nil && !audioPackets.isEmpty }

    // MARK: - Zero-copy accessors

    func colorData(for frame: VP9FramePair) -> Data {
        fileData[frame.colorOffset ..< frame.colorOffset + frame.colorSize]
    }

    func alphaData(for frame: VP9FramePair) -> Data? {
        guard frame.hasAlpha else { return nil }
        return fileData[frame.alphaOffset ..< frame.alphaOffset + frame.alphaSize]
    }

    func audioData(for packet: AudioPacket) -> Data {
        fileData[packet.offset ..< packet.offset + packet.size]
    }

    func codecPrivateData() -> Data? {
        guard let cfg = audioConfig, cfg.codecPrivateSize > 0 else { return nil }
        return Data(fileData[cfg.codecPrivateOffset ..< cfg.codecPrivateOffset + cfg.codecPrivateSize])
    }

    // MARK: - Top-level parse

    private func parse(data: Data) {
        let r = EBMLReader(data: data)
        while !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            switch id {
            case EBMLID.ebmlHeader.rawValue:
                r.skip(size ?? 0)
            case EBMLID.segment.rawValue:
                let segEnd = size.map { r.cursor + $0 } ?? data.count
                parseSegment(r, end: segEnd)
            default:
                r.skip(size ?? 0)
            }
        }
    }

    private func parseSegment(_ r: EBMLReader, end: Int) {
        while r.cursor < end && !r.isAtEnd {
            guard let id = r.readID(), let size = readElementSize(r) else { break }
            let elementEnd = size.map { r.cursor + $0 } ?? end
            switch id {
            case EBMLID.tracks.rawValue:  parseTracks(r, end: elementEnd)
            case EBMLID.cluster.rawValue: parseCluster(r, end: elementEnd)
            default: r.seek(to: elementEnd)
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
        var trackNum: UInt64 = 0
        var trackType: UInt64 = 0
        var codecIDStr = ""
        var localWidth = 0, localHeight = 0
        var sampleRate: Double = 0
        var channelCount = 0
        var cpOffset = 0, cpSize = 0

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
                cpOffset = r.cursor
                cpSize = sz
                r.skip(sz)
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
            audioConfig = AudioTrackConfig(
                trackNumber: trackNum, codecID: codecIDStr,
                sampleRate: sampleRate, channels: channelCount,
                codecPrivateOffset: cpOffset, codecPrivateSize: cpSize)
            print("[Demux] Audio track #\(trackNum): \(codecIDStr) \(sampleRate)Hz \(channelCount)ch")
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
                // EBML float: big-endian IEEE 754 (8 or 4 bytes)
                if sz == 8, let d = r.readBytes(sz) {
                    let bits = d.withUnsafeBytes { ptr -> UInt64 in
                        var v: UInt64 = 0
                        for byte in ptr { v = (v << 8) | UInt64(byte) }
                        return v
                    }
                    sampleRate = Double(bitPattern: bits)
                } else if sz == 4, let d = r.readBytes(sz) {
                    let bits = d.withUnsafeBytes { ptr -> UInt32 in
                        var v: UInt32 = 0
                        for byte in ptr { v = (v << 8) | UInt32(byte) }
                        return v
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
                let beforeCursor = r.cursor
                parseSimpleBlockMultiTrack(r, size: sz, clusterTimecode: clusterTimecode)
                if r.cursor < elementEnd { r.seek(to: elementEnd) }

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

    // MARK: - SimpleBlock (routes to video or audio by track number)

    private func parseSimpleBlockMultiTrack(_ r: EBMLReader, size: Int, clusterTimecode: Int64) {
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

        if trackNum == audioTrackNumber && audioTrackNumber != 0 {
            audioPackets.append(AudioPacket(pts: pts, offset: frameOffset, size: frameSize))
        } else {
            frames.append(VP9FramePair(pts: pts, isKeyframe: isKeyframe,
                                       colorOffset: frameOffset, colorSize: frameSize,
                                       alphaOffset: 0, alphaSize: 0))
        }
    }

    // MARK: - BlockGroup (video with alpha)

    private func parseBlockGroup(_ r: EBMLReader, end: Int,
                                 clusterTimecode: Int64) -> VP9FramePair? {
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
        return VP9FramePair(pts: pts, isKeyframe: isKeyframe,
                            colorOffset: colorOffset, colorSize: colorSize,
                            alphaOffset: alphaOffset, alphaSize: alphaSize)
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

extension CMTime: @retroactive Comparable {
    public static func < (lhs: CMTime, rhs: CMTime) -> Bool {
        CMTimeCompare(lhs, rhs) < 0
    }
}
