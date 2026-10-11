//
//  LengthPrefixedStreamParser.swift
//  InterviewTime
//

import Foundation

public enum StreamParserError: LocalizedError, Equatable {
    case truncatedHeader
    case truncatedPayload(expected: Int, actual: Int)
    case invalidLength(Int)
    case emptyStream

    public var errorDescription: String? {
        switch self {
        case .truncatedHeader:
            return "Stream ended prematurely while reading chunk length header."
        case .truncatedPayload(let expected, let actual):
            return "Stream payload truncated. Expected \(expected) bytes, got \(actual) bytes."
        case .invalidLength(let length):
            return "Invalid chunk length: \(length) bytes."
        case .emptyStream:
            return "Stream produced no chunks."
        }
    }
}

public struct LengthPrefixedStreamParser: Sendable {

    /// Helper to package chunks into 4-byte big-endian framed data (useful for testing or wire framing).
    public static func frame(chunks: [Data]) -> Data {
        var result = Data()
        for chunk in chunks {
            var length = UInt32(chunk.count).bigEndian
            result.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
            result.append(chunk)
        }
        // Terminal 0-length marker
        var terminal: UInt32 = 0
        result.append(Data(bytes: &terminal, count: MemoryLayout<UInt32>.size))
        return result
    }

    /// Synchronously parse from in-memory Data.
    public static func parse(data: Data) throws -> [Data] {
        var chunks: [Data] = []
        var offset = 0
        let total = data.count

        while offset + 4 <= total {
            let lengthBytes = data.subdata(in: offset..<(offset + 4))
            offset += 4
            let length = lengthBytes.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            if length == 0 {
                break
            }
            guard length > 0 else {
                throw StreamParserError.invalidLength(length)
            }
            guard offset + length <= total else {
                let actual = total - offset
                throw StreamParserError.truncatedPayload(expected: length, actual: actual)
            }
            let chunk = data.subdata(in: offset..<(offset + length))
            offset += length
            chunks.append(chunk)
        }

        return chunks
    }

    /// Asynchronously parse from any AsyncSequence of bytes (e.g. URLSession.AsyncBytes).
    public static func parse<S: AsyncSequence>(
        bytes: S,
        onChunk: (Data, Int) async throws -> Void
    ) async throws -> Int where S.Element == UInt8 {
        var iterator = bytes.makeAsyncIterator()

        func readBytes(_ count: Int) async throws -> Data? {
            var buffer = Data()
            buffer.reserveCapacity(count)
            for _ in 0..<count {
                guard let byte = try await iterator.next() else {
                    return buffer.isEmpty ? nil : buffer
                }
                buffer.append(byte)
            }
            return buffer
        }

        var chunkIndex = 0
        while true {
            guard let header = try await readBytes(4) else {
                break
            }
            guard header.count == 4 else {
                throw StreamParserError.truncatedHeader
            }
            let length = header.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            if length == 0 {
                break
            }
            guard length > 0 else {
                throw StreamParserError.invalidLength(length)
            }
            guard let payload = try await readBytes(length) else {
                throw StreamParserError.truncatedPayload(expected: length, actual: 0)
            }
            guard payload.count == length else {
                throw StreamParserError.truncatedPayload(expected: length, actual: payload.count)
            }

            try await onChunk(payload, chunkIndex)
            chunkIndex += 1
        }

        return chunkIndex
    }
}
