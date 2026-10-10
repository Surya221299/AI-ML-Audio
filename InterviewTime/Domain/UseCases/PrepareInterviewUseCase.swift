//
//  PrepareInterviewUseCase.swift
//  InterviewTime
//

import Foundation

public struct PrepStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public var status: Status

    public enum Status: Sendable {
        case pending, active, done
    }

    public init(id: UUID = UUID(), title: String, status: Status = .pending) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public enum PrepStage: Equatable, Sendable {
    case idle
    case loadingSTT
    case analyzing
    case rendering(String)
    case ready
    case failed(String)
}

public final class PrepareInterviewUseCase: Sendable {
    private let aiService: InterviewAIServiceProtocol
    private let speechSynthesizer: SpeechSynthesizer
    private let lipSyncRenderer: LipSyncRenderer
    private let mediaStore: InterviewMediaStore
    private let imageProvider: InterviewerImageProviding
    private let numQuestions: Int

    public init(
        aiService: InterviewAIServiceProtocol,
        speechSynthesizer: SpeechSynthesizer,
        lipSyncRenderer: LipSyncRenderer,
        mediaStore: InterviewMediaStore,
        imageProvider: InterviewerImageProviding,
        numQuestions: Int = AppConfig.numQuestions
    ) {
        self.aiService = aiService
        self.speechSynthesizer = speechSynthesizer
        self.lipSyncRenderer = lipSyncRenderer
        self.mediaStore = mediaStore
        self.imageProvider = imageProvider
        self.numQuestions = numQuestions
    }

    public static func makeInitialSteps(questionCount: Int = AppConfig.numQuestions) -> [PrepStep] {
        var list: [PrepStep] = []
        list.append(.init(title: "Memuat model suara", status: .pending))
        list.append(.init(title: "Menganalisis job description", status: .pending))
        list.append(.init(title: "Menyiapkan pembuka", status: .pending))
        for i in 0..<questionCount {
            list.append(.init(title: "Menyiapkan pertanyaan \(i + 1)", status: .pending))
        }
        list.append(.init(title: "Menyiapkan penutup", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: posisi", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: perusahaan", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: benefit", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: proses", status: .pending))
        return list
    }

    public func execute(
        jobDescription: String,
        ensureSTTReady: () async -> Bool,
        onStepUpdate: @MainActor @Sendable (Int, PrepStep.Status) -> Void,
        onStageUpdate: @MainActor @Sendable (PrepStage) -> Void
    ) async throws -> [String] {
        // 1. STT — step 0
        await onStepUpdate(0, .active)
        await onStageUpdate(.loadingSTT)
        let sttReady = await ensureSTTReady()
        guard sttReady else {
            let errorMsg = "STT gagal dimuat"
            await onStageUpdate(.failed(errorMsg))
            throw NSError(domain: "PrepareInterview", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        await onStepUpdate(0, .done)

        // 2. Generate Pertanyaan — step 1
        await onStepUpdate(1, .active)
        await onStageUpdate(.analyzing)
        let questions = await aiService.generateQuestions(jobDescription: jobDescription)
        guard questions.count == numQuestions else {
            let errorMsg = "Gagal membuat pertanyaan"
            await onStageUpdate(.failed(errorMsg))
            throw NSError(domain: "PrepareInterview", code: 2, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }
        await onStepUpdate(1, .done)

        // 3. Render video ke folder
        // Pertanyaan SELALU dirender ulang (beda JD = beda pertanyaan)
        mediaStore.cleanQuestionDirectories(count: numQuestions)

        let imageData = try imageProvider.loadInterviewerImageData()

        // Opening (cached)
        await onStepUpdate(2, .active)
        if mediaStore.loadSavedSegments(from: mediaStore.openingDirectory) == nil {
            await onStageUpdate(.rendering("Menyiapkan opening…"))
            let wav = try await speechSynthesizer.synthesizeSpeech(text: InterviewScript.openingText)
            _ = try await lipSyncRenderer.render(
                request: LipSyncRenderRequest(
                    audioData: wav,
                    imageData: imageData,
                    outputDirectory: mediaStore.openingDirectory
                )
            )
        }
        await onStepUpdate(2, .done)

        // Questions
        for (i, q) in questions.enumerated() {
            let stepIndex = 3 + i
            await onStepUpdate(stepIndex, .active)
            if mediaStore.loadSavedSegments(from: mediaStore.questionDirectory(index: i)) == nil {
                await onStageUpdate(.rendering("Menyiapkan pertanyaan \(i + 1) dari \(questions.count)…"))
                let wav = try await speechSynthesizer.synthesizeSpeech(text: q)
                _ = try await lipSyncRenderer.render(
                    request: LipSyncRenderRequest(
                        audioData: wav,
                        imageData: imageData,
                        outputDirectory: mediaStore.questionDirectory(index: i)
                    )
                )
            }
            await onStepUpdate(stepIndex, .done)
        }

        // Closing (cached)
        let closingStep = 3 + numQuestions
        await onStepUpdate(closingStep, .active)
        if mediaStore.loadSavedSegments(from: mediaStore.closingDirectory) == nil {
            await onStageUpdate(.rendering("Menyiapkan closing…"))
            let wav = try await speechSynthesizer.synthesizeSpeech(text: InterviewScript.closingText)
            _ = try await lipSyncRenderer.render(
                request: LipSyncRenderRequest(
                    audioData: wav,
                    imageData: imageData,
                    outputDirectory: mediaStore.closingDirectory
                )
            )
        }
        await onStepUpdate(closingStep, .done)

        // 4. Render jawaban tanya-balik
        mediaStore.cleanDynamicAnswerDirectories(
            categories: ClosingCategory.allCases.map(\.rawValue),
            preservedCategories: ClosingCategory.fixedCategories.map(\.rawValue)
        )

        let generatedAnswers = await aiService.generateClosingAnswers(jobDescription: jobDescription)
        let baseAnswerStep = 4 + numQuestions

        for (ci, cat) in ClosingCategory.allCases.enumerated() {
            let stepIndex = baseAnswerStep + ci
            await onStepUpdate(stepIndex, .active)

            let isFixed = cat.isFixed
            let answerDir = mediaStore.answerDirectory(category: cat.rawValue)

            if isFixed, mediaStore.loadSavedSegments(from: answerDir) != nil {
                await onStepUpdate(stepIndex, .done)
                continue
            }

            await onStageUpdate(.rendering("Menyiapkan jawaban: \(cat.rawValue)…"))
            var text: String
            switch cat {
            case .benefit:
                text = InterviewScript.benefitAnswerText
            case .proses:
                text = InterviewScript.prosesAnswerText
            case .posisi, .perusahaan:
                text = generatedAnswers[cat] ?? InterviewScript.defaultAnswer(for: cat)
            }

            text += InterviewScript.answerFollowUpPrompt
            let wav = try await speechSynthesizer.synthesizeSpeech(text: text)
            _ = try await lipSyncRenderer.render(
                request: LipSyncRenderRequest(
                    audioData: wav,
                    imageData: imageData,
                    outputDirectory: answerDir
                )
            )

            await onStepUpdate(stepIndex, .done)
        }

        await onStageUpdate(.ready)
        return questions
    }
}
