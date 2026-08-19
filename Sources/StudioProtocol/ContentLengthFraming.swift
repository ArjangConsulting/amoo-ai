import Foundation

public enum ContentLengthFraming {
    public struct FramingError: Error, CustomStringConvertible, Equatable {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    public static func readMessage(from input: FileHandle) throws -> Data? {
        var header = Data()
        while !header.suffix(4).elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty {
                if header.isEmpty {
                    return nil
                }
                throw FramingError("Stream closed mid-header")
            }
            header.append(byte)
        }

        guard let text = String(data: header, encoding: .utf8) else {
            throw FramingError("Header is not valid UTF-8")
        }
        let length = text.components(separatedBy: "\r\n").compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        guard let length, length >= 0 else { throw FramingError("Missing or invalid Content-Length header") }

        var body = Data()
        while body.count < length {
            let chunk = input.readData(ofLength: length - body.count)
            if chunk.isEmpty {
                throw FramingError("Stream closed mid-body")
            }
            body.append(chunk)
        }
        return body
    }

    public static func writeMessage(_ body: Data, to output: FileHandle) throws {
        var message = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        message.append(body)
        try output.write(contentsOf: message)
    }
}
