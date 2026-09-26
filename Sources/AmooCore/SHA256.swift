import Foundation

/// Minimal SHA-256 (FIPS 180-4) for evidence hashes: portable to Linux without pulling
/// swift-crypto into every target that records provenance.
public struct SHA256Digest {
    private var state: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A, 0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while pending.count - offset >= 64 {
            compress(pending[offset ..< offset + 64])
            offset += 64
        }
        pending.removeFirst(offset)
    }

    public mutating func finalizeHex() -> String {
        var tail = pending
        tail.append(0x80)
        while tail.count % 64 != 56 {
            tail.append(0)
        }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        for start in stride(from: 0, to: tail.count, by: 64) {
            compress(tail[start ..< start + 64])
        }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    // FIPS 180-4 names its working variables a...h; renaming them would obscure the spec.
    // swiftlint:disable identifier_name
    private mutating func compress(_ block: ArraySlice<UInt8>) {
        var words = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for index in 0 ..< 16 {
            words[index] = (0 ..< 4).reduce(UInt32(0)) { ($0 << 8) | UInt32(block[base + index * 4 + $1]) }
        }
        for index in 16 ..< 64 {
            let low = words[index - 15].rotatedRight(7) ^ words[index - 15].rotatedRight(18) ^ (words[index - 15] >> 3)
            let high = words[index - 2].rotatedRight(17) ^ words[index - 2].rotatedRight(19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ low &+ words[index - 7] &+ high
        }
        var (a, b, c, d, e, f, g, h) = (state[0], state[1], state[2], state[3], state[4], state[5], state[6], state[7])
        for index in 0 ..< 64 {
            let sum1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
            let choice = (e & f) ^ (~e & g)
            let temp1 = h &+ sum1 &+ choice &+ Self.roundConstants[index] &+ words[index]
            let sum0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ temp1, c, b, a, temp1 &+ sum0 &+ majority)
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() {
            state[index] &+= value
        }
    }

    // swiftlint:enable identifier_name

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5, 0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3, 0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC, 0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7, 0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13, 0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3, 0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5, 0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208, 0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2
    ]
}

private extension UInt32 {
    func rotatedRight(_ count: UInt32) -> UInt32 {
        (self >> count) | (self << (32 - count))
    }
}

/// Hex SHA-256 of `data`.
public func sha256Hex(_ data: Data) -> String {
    var digest = SHA256Digest()
    digest.update(data)
    return digest.finalizeHex()
}

/// Hex SHA-256 of a file, or of a bundle directory's sorted relative paths and contents.
public func sha256Hex(ofPath path: String) -> String? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    guard isDirectory.boolValue else {
        return (try? Data(contentsOf: URL(fileURLWithPath: path))).map(sha256Hex)
    }
    let root = URL(fileURLWithPath: path)
    let files = (FileManager.default.enumerator(atPath: path)?.allObjects as? [String] ?? []).sorted()
    var digest = SHA256Digest()
    for relative in files {
        let url = root.appendingPathComponent(relative)
        var childIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &childIsDirectory),
              !childIsDirectory.boolValue,
              let contents = try? Data(contentsOf: url)
        else { continue }
        digest.update(Data(relative.utf8))
        digest.update(contents)
    }
    return digest.finalizeHex()
}
