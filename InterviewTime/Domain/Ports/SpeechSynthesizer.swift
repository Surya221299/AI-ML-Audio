//
//  SpeechSynthesizer.swift
//  InterviewTime
//

import Foundation

public struct SpeechSynthesisRequest: Sendable {
    public let text: String
    public let emotion: String
    public let voice: String
    public let cfgValue: Double
    public let inferenceTimesteps: Int
    public let maxTokens: Int
    public let warmupPatches: Int

    public init(
        text: String,
        emotion: String = "calm, professional",
        voice: String = "male_40s",
        cfgValue: Double = 2.5,
        inferenceTimesteps: Int = 10,
        maxTokens: Int = 1200,
        warmupPatches: Int = 2
    ) {
        self.text = text
        self.emotion = emotion
        self.voice = voice
        self.cfgValue = cfgValue
        self.inferenceTimesteps = inferenceTimesteps
        self.maxTokens = maxTokens
        self.warmupPatches = warmupPatches
    }
}

public protocol SpeechSynthesizer: Sendable {
    func synthesizeSpeech(request: SpeechSynthesisRequest) async throws -> Data
}

extension SpeechSynthesizer {
    public func synthesizeSpeech(text: String) async throws -> Data {
        try await synthesizeSpeech(request: SpeechSynthesisRequest(text: text))
    }
}
