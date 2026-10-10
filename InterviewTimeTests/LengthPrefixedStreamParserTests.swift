//
//  LengthPrefixedStreamParserTests.swift
//  InterviewTimeTests
//

import Foundation
import Testing
@testable import InterviewTime

@Suite struct LengthPrefixedStreamParserTests {

    @Test func frameAndParseRoundtrip() throws {
        let chunk1 = "Hello, world!".data(using: .utf8)!
        let chunk2 = "Second test segment data for audio/video".data(using: .utf8)!
        let chunk3 = Data([0x00, 0x01, 0x02, 0xFF, 0xFE])

        let framed = LengthPrefixedStreamParser.frame(chunks: [chunk1, chunk2, chunk3])
        let parsed = try LengthPrefixedStreamParser.parse(data: framed)

        #expect(parsed.count == 3)
        #expect(parsed[0] == chunk1)
        #expect(parsed[1] == chunk2)
        #expect(parsed[2] == chunk3)
    }

    @Test func emptyStreamParsing() throws {
        // Just terminal 0 marker
        var terminal: UInt32 = 0
        let terminalData = Data(bytes: &terminal, count: 4)

        let parsed = try LengthPrefixedStreamParser.parse(data: terminalData)
        #expect(parsed.isEmpty)
    }

    @Test func truncatedPayloadThrowsError() {
        var length: UInt32 = UInt32(100).bigEndian
        var corrupted = Data(bytes: &length, count: 4)
        corrupted.append("only 10 bytes".data(using: .utf8)!)

        #expect(throws: StreamParserError.self) {
            _ = try LengthPrefixedStreamParser.parse(data: corrupted)
        }
    }

    @Test func asyncSequenceParsing() async throws {
        let chunk1 = "Stream segment 1".data(using: .utf8)!
        let chunk2 = "Stream segment 2".data(using: .utf8)!
        let framed = LengthPrefixedStreamParser.frame(chunks: [chunk1, chunk2])

        var received: [Data] = []
        let asyncBytes = AsyncStream<UInt8> { continuation in
            for byte in framed {
                continuation.yield(byte)
            }
            continuation.finish()
        }

        let count = try await LengthPrefixedStreamParser.parse(bytes: asyncBytes) { data, idx in
            #expect(idx == received.count)
            received.append(data)
        }

        #expect(count == 2)
        #expect(received.count == 2)
        #expect(received[0] == chunk1)
        #expect(received[1] == chunk2)
    }
}
