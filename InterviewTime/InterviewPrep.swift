//
//  InterviewPrep.swift
//  InterviewTime
//
//  ViewModel & facade untuk persiapan wawancara.
//  Mengorkestrasi Whisper STT, AI LLM Service, Media Store, TTS, dan LipSync Renderer.
//

import Foundation
import AppKit
import Combine

@MainActor
final class InterviewPrep: ObservableObject {

    typealias Stage = PrepStage
    typealias PrepStep = InterviewTime.PrepStep

    @Published var stage: PrepStage = .idle
    @Published var steps: [PrepStep] = []
    @Published var questions: [String] = []
    @Published var jobDescription = ""
    @Published var interviewCompleted = false
    @Published var feedbackCompleted = false

    let whisper = WhisperService()
    let mediaStore: InterviewMediaStore
    let aiService: InterviewAIServiceProtocol
    let localTTS: SpeechSynthesizer
    let lipSyncClient: LipSyncRenderer
    let imageProvider: InterviewerImageProviding
    private let prepareUseCase: PrepareInterviewUseCase

    let numQuestions = AppConfig.numQuestions
    let maxFollowUps = AppConfig.maxFollowUps
    let maxClosingQA = AppConfig.maxClosingQA

    // RunPod TTS (opsional) — kalau endpoint+key terisi, follow-up aktif.
    @Published var runpodEndpoint = ""
    @Published var runpodKey = ""
    var followUpEnabled: Bool {
        !runpodEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
        && !runpodKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var runpodClient: RunPodTTSClient {
        RunPodTTSClient(endpointId: runpodEndpoint, apiKey: runpodKey)
    }

    var outputsRoot: URL { mediaStore.outputsRoot }
    var openingDir: URL { mediaStore.openingDirectory }
    var closingDir: URL { mediaStore.closingDirectory }
    func questionDir(_ i: Int) -> URL { mediaStore.questionDirectory(index: i) }
    func answerDir(_ cat: String) -> URL { mediaStore.answerDirectory(category: cat) }

    var isReady: Bool { if case .ready = stage { return true }; return false }
    var isWorking: Bool {
        switch stage { case .idle, .ready, .failed: return false; default: return true }
    }

    init(
        mediaStore: InterviewMediaStore = FileInterviewMediaStore(),
        aiService: InterviewAIServiceProtocol = InterviewAIService(),
        localTTS: SpeechSynthesizer = LocalTTSClient(),
        lipSyncClient: LipSyncRenderer = LipSyncClient(),
        imageProvider: InterviewerImageProviding = InterviewerImageProvider.shared
    ) {
        self.mediaStore = mediaStore
        self.aiService = aiService
        self.localTTS = localTTS
        self.lipSyncClient = lipSyncClient
        self.imageProvider = imageProvider
        self.prepareUseCase = PrepareInterviewUseCase(
            aiService: aiService,
            speechSynthesizer: localTTS,
            lipSyncRenderer: lipSyncClient,
            mediaStore: mediaStore,
            imageProvider: imageProvider,
            numQuestions: AppConfig.numQuestions
        )
    }

    // MARK: - Step tracking

    private func initSteps(questionCount: Int) {
        steps = PrepareInterviewUseCase.makeInitialSteps(questionCount: questionCount)
    }

    private func markStep(_ index: Int, _ status: PrepStep.Status) {
        guard steps.indices.contains(index) else { return }
        steps[index].status = status
    }

    // MARK: - Persiapan lengkap

    func prepare(jobDescription: String) async {
        self.jobDescription = jobDescription
        interviewCompleted = false
        feedbackCompleted = false
        warmUpRunpodIfNeeded()
        initSteps(questionCount: numQuestions)

        do {
            let generated = try await prepareUseCase.execute(
                jobDescription: jobDescription,
                ensureSTTReady: { [weak self] in
                    guard let self else { return false }
                    if !self.whisper.isReady {
                        await self.whisper.loadModel()
                    }
                    return self.whisper.isReady
                },
                onStepUpdate: { [weak self] index, status in
                    self?.markStep(index, status)
                },
                onStageUpdate: { [weak self] newStage in
                    self?.stage = newStage
                }
            )
            self.questions = generated
            self.stage = .ready
        } catch {
            self.stage = .failed(error.localizedDescription)
            print("PREP ERROR:", error)
        }
    }

    // MARK: - RunPod & Follow-up

    func warmUpRunpodIfNeeded() {
        guard followUpEnabled else { return }
        runpodClient.warmUp()
    }

    func generateFollowUp(question: String, answer: String) async -> String {
        await aiService.generateFollowUp(question: question, answer: answer)
    }

    func renderFollowUp(text: String) async -> [URL]? {
        let dir = mediaStore.createFollowUpDirectory()
        do {
            let tts: SpeechSynthesizer = followUpEnabled ? runpodClient : localTTS
            let wav = try await tts.synthesizeSpeech(text: text)
            let img = try imageProvider.loadInterviewerImageData()
            return try await lipSyncClient.render(
                request: LipSyncRenderRequest(
                    audioData: wav,
                    imageData: img,
                    outputDirectory: dir
                )
            )
        } catch {
            return nil
        }
    }

    // MARK: - Closing Intent & QA

    func classifyDecline(_ answer: String) async -> Bool {
        await aiService.classifyDecline(answer)
    }

    func classifyClosingCategory(_ question: String) async -> String {
        let cat = await aiService.classifyClosingCategory(question)
        return cat.rawValue
    }

    func generateClosingAnswer(candidateQuestion: String, remaining: Int) async -> String {
        await aiService.generateClosingAnswer(candidateQuestion: candidateQuestion, remaining: remaining)
    }

    func renderAnswer(text: String) async -> [URL]? {
        let dir = mediaStore.createClosingAnswerDirectory()
        do {
            let wav = try await localTTS.synthesizeSpeech(text: text)
            let img = try imageProvider.loadInterviewerImageData()
            return try await lipSyncClient.render(
                request: LipSyncRenderRequest(
                    audioData: wav,
                    imageData: img,
                    outputDirectory: dir
                )
            )
        } catch {
            return nil
        }
    }

    // MARK: - Feedback generation (with backward compatibility)

    func generateOverallFeedback(
        jobDescription: String,
        questions: [String],
        transcripts: [String]
    ) async -> JSONValue {
        guard let typed = await aiService.generateOverallFeedback(
            jobDescription: jobDescription,
            questions: questions,
            transcripts: transcripts
        ) else { return .null }

        return .object([
            "overall_score": .number(typed.overallScore),
            "recommendation": .string(typed.recommendation),
            "strengths": .array(typed.strengths.map { .string($0) }),
            "weaknesses_or_gaps": .array(typed.weaknessesOrGaps.map { .string($0) }),
            "red_flags": .array(typed.redFlags.map { .string($0) }),
            "fit_vs_jd": .string(typed.fitVsJD),
            "feedback_for_candidate": .array(typed.feedbackForCandidate.map { .string($0) })
        ])
    }

    func generateQuestionFeedback(
        question: String,
        answer: String,
        position: String
    ) async -> JSONValue {
        guard let typed = await aiService.generateQuestionFeedback(
            question: question,
            answer: answer,
            position: position
        ) else { return .null }

        return .object([
            "question": .string(typed.question),
            "plus_points": .array(typed.plusPoints.map { .string($0) }),
            "improvements": .array(typed.improvements.map { .string($0) })
        ])
    }

    func generateNoQuestionsFeedback(position: String) async -> String {
        await aiService.generateNoQuestionsFeedback(position: position)
    }

    func loadSaved(_ dir: URL) -> [URL]? {
        mediaStore.loadSavedSegments(from: dir)
    }

    static func loadInterviewerImage() -> NSImage? {
        InterviewerImageProvider.shared.loadInterviewerImage()
    }
}
