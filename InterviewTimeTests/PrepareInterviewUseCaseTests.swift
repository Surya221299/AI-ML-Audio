//
//  PrepareInterviewUseCaseTests.swift
//  InterviewTimeTests
//

import Foundation
import AppKit
import Testing
@testable import InterviewTime

private final class MockAIService: InterviewAIServiceProtocol, @unchecked Sendable {
    var questionsToReturn: [String] = ["Pertanyaan 1", "Pertanyaan 2", "Pertanyaan 3", "Pertanyaan 4"]
    var closingAnswersToReturn: [ClosingCategory: String] = [
        .posisi: "Jawaban posisi",
        .perusahaan: "Jawaban perusahaan"
    ]

    func generateQuestions(jobDescription: String) async -> [String] {
        questionsToReturn
    }

    func generateClosingAnswers(jobDescription: String) async -> [ClosingCategory: String] {
        closingAnswersToReturn
    }

    func classifyClosingCategory(_ question: String) async -> ClosingCategory { .proses }
    func classifyDecline(_ answer: String) async -> Bool { false }
    func generateClosingAnswer(candidateQuestion: String, remaining: Int) async -> String { "Jawaban closing" }
    func generateFollowUp(question: String, answer: String) async -> String { "Follow up" }
    func generateOverallFeedback(jobDescription: String, questions: [String], transcripts: [String]) async -> OverallFeedback? { nil }
    func generateQuestionFeedback(question: String, answer: String, position: String) async -> QuestionFeedback? { nil }
    func generateNoQuestionsFeedback(position: String) async -> String { "" }
}

private final class MockSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    func synthesizeSpeech(request: SpeechSynthesisRequest) async throws -> Data {
        "MOCK_WAV_DATA".data(using: .utf8)!
    }
}

private final class MockLipSyncRenderer: LipSyncRenderer, @unchecked Sendable {
    func render(request: LipSyncRenderRequest) async throws -> [URL] {
        try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let segURL = request.outputDirectory.appendingPathComponent("seg_0000.mp4")
        try "MOCK_MP4".write(to: segURL, atomically: true, encoding: .utf8)
        return [segURL]
    }
}

private final class MockImageProvider: InterviewerImageProviding, @unchecked Sendable {
    func loadInterviewerImage() -> AppKit.NSImage? { nil }
    func loadInterviewerImageData() throws -> Data {
        "MOCK_IMAGE_DATA".data(using: .utf8)!
    }
}

@Suite struct PrepareInterviewUseCaseTests {

    @Test func executeSucceedsAndSetsReadyStage() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mediaStore = FileInterviewMediaStore(outputsRoot: tempRoot)
        let ai = MockAIService()
        let tts = MockSpeechSynthesizer()
        let lipsync = MockLipSyncRenderer()
        let img = MockImageProvider()

        let useCase = PrepareInterviewUseCase(
            aiService: ai,
            speechSynthesizer: tts,
            lipSyncRenderer: lipsync,
            mediaStore: mediaStore,
            imageProvider: img,
            numQuestions: 4
        )

        var finalStage: PrepStage = .idle
        var updatedSteps: [Int: PrepStep.Status] = [:]

        let questions = try await useCase.execute(
            jobDescription: "Sample Job Description for Software Engineer",
            ensureSTTReady: { true },
            onStepUpdate: { index, status in
                updatedSteps[index] = status
            },
            onStageUpdate: { stage in
                finalStage = stage
            }
        )

        #expect(questions.count == 4)
        #expect(finalStage == .ready)
        #expect(updatedSteps[0] == .done)
        #expect(updatedSteps[1] == .done)
    }

    @Test func executeFailsWhenSTTNotReady() async {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let mediaStore = FileInterviewMediaStore(outputsRoot: tempRoot)
        let useCase = PrepareInterviewUseCase(
            aiService: MockAIService(),
            speechSynthesizer: MockSpeechSynthesizer(),
            lipSyncRenderer: MockLipSyncRenderer(),
            mediaStore: mediaStore,
            imageProvider: MockImageProvider(),
            numQuestions: 4
        )

        var finalStage: PrepStage = .idle

        await #expect(throws: Error.self) {
            _ = try await useCase.execute(
                jobDescription: "Sample JD",
                ensureSTTReady: { false },
                onStepUpdate: { _, _ in },
                onStageUpdate: { stage in
                    finalStage = stage
                }
            )
        }

        #expect(finalStage == .failed("STT gagal dimuat"))
    }
}
