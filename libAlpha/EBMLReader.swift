import Foundation

// MARK: - EBML Element IDs (WebM subset)
enum EBMLID: UInt32 {
    // Top level
    case ebmlHeader      = 0x1A45DFA3
    case segment         = 0x18538067
    // Segment info
    case tracks          = 0x1654AE6B
    case trackEntry      = 0xAE
    case trackNumber     = 0xD7
    case trackType       = 0x83
    case codecID         = 0x86
    case video           = 0xE0
    case pixelWidth      = 0xB0
    case pixelHeight     = 0xBA
    // Cluster
    case cluster         = 0x1F43B675
    case timecode        = 0xE7          // cluster timestamp (ms)
    case simpleBlock     = 0xA3
    case blockGroup      = 0xA0
    case block           = 0xA1
    case blockAdditions  = 0x75A1
    case blockMore       = 0xA6
    case blockAddID      = 0xEE
    case blockAdditional = 0xA5
}

// MARK: - Low-level EBML byte reader

final class EBMLReader {
    private let data: Data
    private(set) var cursor: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.cursor = offset
    }

    var isAtEnd: Bool { cursor >= data.count }
    var remaining: Int { data.count - cursor }

    // MARK: Primitive reads

    func readByte() -> UInt8? {
        guard cursor < data.count else { return nil }
        defer { cursor += 1 }
        return data[cursor]
    }

    func readBytes(_ count: Int) -> Data? {
        guard cursor + count <= data.count else { return nil }
        defer { cursor += count }
        return Data(data[cursor ..< cursor + count])   // copy so startIndex == 0
    }

    func skip(_ count: Int) {
        cursor = min(cursor + count, data.count)
    }

    func seek(to offset: Int) {
        cursor = offset
    }

    // MARK: VINT — Variable-length integer

    /// Reads an EBML VINT used for element **IDs** (leading 1-bit preserved).
    func readID() -> UInt32? {
        guard let first = readByte() else { return nil }
        let width = leadingZeros(first) + 1          // 1..8 bytes
        guard width <= 4 else { return nil }          // IDs are max 4 bytes in practice
        var value = UInt32(first)
        for _ in 1 ..< width {
            guard let b = readByte() else { return nil }
            value = (value << 8) | UInt32(b)
        }
        return value
    }

    /// Reads an EBML VINT used for element **sizes** (leading 1-bit masked off).
    /// Returns `nil` for unknown-size sentinels.
    func readSize() -> Int? {
        guard let first = readByte() else { return nil }
        let width = leadingZeros(first) + 1
        guard width <= 8 else { return nil }
        let mask: UInt8 = 0xFF >> width               // mask off the leading width-indicator bit
        var value = Int(first & mask)
        for _ in 1 ..< width {
            guard let b = readByte() else { return nil }
            value = (value << 8) | Int(b)
        }
        // All-ones = unknown size (used for Segment container)
        let maxVal = (1 << (7 * width)) - 1
        if value == maxVal { return nil }
        return value
    }

    /// Reads a big-endian unsigned integer of exactly `byteCount` bytes.
    func readUInt(bytes byteCount: Int) -> UInt64? {
        guard let d = readBytes(byteCount) else { return nil }
        var v: UInt64 = 0
        for byte in d { v = (v << 8) | UInt64(byte) }
        return v
    }

    /// Reads a UTF-8 / ASCII string of exactly `length` bytes.
    func readString(length: Int) -> String? {
        guard let d = readBytes(length) else { return nil }
        return String(bytes: d, encoding: .utf8)?
            .trimmingCharacters(in: .init(charactersIn: "\0"))
    }

    // MARK: Helper

    private func leadingZeros(_ byte: UInt8) -> Int {
        var b = byte
        var count = 0
        while b & 0x80 == 0 {
            count += 1
            b <<= 1
            if count == 8 { break }
        }
        return count
    }
}
