import Foundation

/// Reads a video's length from its MP4 / QuickTime `moov/mvhd` header.
///
/// Native recorders start encoding a moment after they are launched (about a second on an iOS
/// simulator or an Android emulator), so the clip is shorter than the time amoo waited. Reporting
/// the header's length keeps a result honest without a media framework, which Linux lacks.
/// Only box headers and the small `moov` box are read, so a long recording is never loaded whole.
enum VideoDuration {
    static func seconds(at url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard let header = box(in: handle, at: offset, fileEnd: end) else { return nil }
            if header.type == "moov" {
                try? handle.seek(toOffset: offset + header.headerLength)
                let length = Int(min(header.size - header.headerLength, 16 * 1024 * 1024))
                guard let payload = try? handle.read(upToCount: length) else { return nil }
                return mvhdSeconds(in: payload)
            }
            guard header.size > 0 else { return nil }
            offset += header.size
        }
        return nil
    }

    /// The `mvhd` duration inside a `moov` payload.
    static func mvhdSeconds(in moov: Data) -> Double? {
        let bytes = [UInt8](moov)
        var index = 0
        while index + 8 <= bytes.count {
            let size = Int(readUInt32(bytes, at: index))
            let type = String(bytes: bytes[(index + 4) ..< (index + 8)], encoding: .ascii)
            if type == "mvhd" {
                return mvhdPayloadSeconds(Array(bytes[(index + 8)...]))
            }
            guard size >= 8 else { return nil }
            index += size
        }
        return nil
    }

    private static func mvhdPayloadSeconds(_ payload: [UInt8]) -> Double? {
        guard let version = payload.first else { return nil }
        // version(1) flags(3), then creation and modification times: 4 bytes each in v0, 8 in v1.
        let timescaleOffset = version == 1 ? 20 : 12
        let durationLength = version == 1 ? 8 : 4
        guard payload.count >= timescaleOffset + 4 + durationLength else { return nil }
        let timescale = Double(readUInt32(payload, at: timescaleOffset))
        let duration = version == 1
            ? Double(readUInt64(payload, at: timescaleOffset + 4))
            : Double(readUInt32(payload, at: timescaleOffset + 4))
        guard timescale > 0 else { return nil }
        return duration / timescale
    }

    private struct BoxHeader {
        let type: String
        let size: UInt64
        let headerLength: UInt64
    }

    private static func box(in handle: FileHandle, at offset: UInt64, fileEnd: UInt64) -> BoxHeader? {
        try? handle.seek(toOffset: offset)
        guard let raw = try? handle.read(upToCount: 16), raw.count >= 8 else { return nil }
        let bytes = [UInt8](raw)
        let type = String(bytes: bytes[4 ..< 8], encoding: .ascii) ?? ""
        switch readUInt32(bytes, at: 0) {
        case 0:
            return BoxHeader(type: type, size: fileEnd - offset, headerLength: 8)
        case 1:
            guard bytes.count >= 16 else { return nil }
            return BoxHeader(type: type, size: readUInt64(bytes, at: 8), headerLength: 16)
        case let size:
            return BoxHeader(type: type, size: UInt64(size), headerLength: 8)
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        bytes[index ..< index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        bytes[index ..< index + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
