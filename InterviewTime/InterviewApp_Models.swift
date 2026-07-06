//
//  Models.swift
//  AudioCombineApp
//
//  Shared data models used across LLM, TTS, and STT layers.
//

import Foundation

// ─────────────────────────────────────────────
// MARK: - Interview / LLM models
// ─────────────────────────────────────────────

struct Question: Identifiable, Codable, Equatable {
    let id: Int
    var competency: String
    var qtype: String
    var question: String
    var asked: Bool = false
}

struct Note: Codable, Identifiable {
    var id = UUID()
    var topic: String
    var note: String
    var sentiment: String
    var questionId: Int?

    enum CodingKeys: String, CodingKey {
        case topic, note, sentiment, questionId
    }
}

enum Speaker: String, Codable, Equatable {
    case interviewer
    case candidate
    case system
}

struct TranscriptTurn: Identifiable, Codable, Equatable {
    var id = UUID()
    var speaker: Speaker
    var text: String
    // Filler stats for candidate answers (nil for interviewer/system turns)
    var fillerCount: Int? = nil
    var fillerRatioPercent: Double? = nil

    enum CodingKeys: String, CodingKey {
        case speaker, text, fillerCount, fillerRatioPercent
    }
}

enum InterviewPhase: Equatable {
    case idle
    case generatingQuestions
    case readyToStart
    case awaitingAnswer
    case awaitingClosingAnswer
    case processingAnswer
    case recording
    case transcribing
    case playingAudio
    case summarizing
    case deepFeedback
    case noQuestionsFeedback
    case questionFeedbacks
    case done
    case failed(String)

    var label: String {
        switch self {
        case .idle:                  return "Belum dimulai"
        case .generatingQuestions:   return "Menyusun pertanyaan…"
        case .readyToStart:          return "Siap memulai"
        case .awaitingAnswer:        return "Menunggu jawaban"
        case .awaitingClosingAnswer: return "Menunggu pertanyaan balik"
        case .processingAnswer:      return "Memproses jawaban…"
        case .recording:             return "Merekam…"
        case .transcribing:          return "Mentranskrip…"
        case .playingAudio:          return "Nova berbicara…"
        case .summarizing:           return "Merangkum sesi…"
        case .deepFeedback:          return "Menyusun feedback keseluruhan…"
        case .noQuestionsFeedback:   return "Menyusun feedback pertanyaan balik…"
        case .questionFeedbacks:     return "Menyusun feedback per pertanyaan…"
        case .done:                  return "Selesai"
        case .failed(let m):         return "Error: \(m)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .generatingQuestions, .processingAnswer, .transcribing,
             .summarizing, .deepFeedback, .noQuestionsFeedback, .questionFeedbacks:
            return true
        default:
            return false
        }
    }
}

struct QuestionAnswerPair {
    var questionId: Int
    var competency: String
    var question: String
    var candidateAnswers: [String]
}

// ─────────────────────────────────────────────
// MARK: - TTS models
// ─────────────────────────────────────────────

/// Response from POST /speak — Python server generates AND plays audio
/// (blocking, via afplay) before responding. Swift never touches the
/// output audio device directly.
struct TTSSpeakResponse: Codable {
    let path: String?
    let playbackSeconds: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case path
        case playbackSeconds = "playback_seconds"
        case error
    }
}

// ─────────────────────────────────────────────
// MARK: - STT models
// ─────────────────────────────────────────────

struct TranscriptWord: Codable {
    var text: String
    var start: Double
    var end: Double
    var probability: Double
}

struct STTResult {
    var text: String
    var language: String
    var words: [TranscriptWord]
    var audioSeconds: Double
    var inferSeconds: Double
    var realTimeFactor: Double
    var model: String
}

// ─────────────────────────────────────────────
// MARK: - Filler detection models
// ─────────────────────────────────────────────

struct FillerHit: Identifiable {
    let id = UUID()
    var word: String
    var start: Double
    var norm: String
    var type: String     // "non-leksikal" | "leksikal-id" | "leksikal-en"
}

struct FillerPhraseHit: Identifiable {
    let id = UUID()
    var phrase: String
    var start: Double
}

struct FillerAnalysis {
    var totalWords: Int
    var fillerCount: Int
    var fillerRatioPercent: Double
    var perWord: [String: Int]
    var singles: [FillerHit]
    var phrases: [FillerPhraseHit]
    /// Word start-times (rounded to 2dp) flagged as fillers — used for marking.
    var markedStarts: Set<Double>

    static let empty = FillerAnalysis(totalWords: 0, fillerCount: 0,
                                       fillerRatioPercent: 0, perWord: [:],
                                       singles: [], phrases: [], markedStarts: [])
}

// ─────────────────────────────────────────────
// MARK: - Feedback panel models
// ─────────────────────────────────────────────

enum FeedbackState {
    case pending
    case generating(elapsed: Double)
    case done(text: String, elapsed: Double)
    case failed
}

struct FeedbackItem: Identifiable {
    let id = UUID()
    let title: String
    var state: FeedbackState = .pending
}

// ─────────────────────────────────────────────
// MARK: - Default Job Description (placeholder)
// ─────────────────────────────────────────────

let defaultJobDescription = """
Requirements:
Bachelor's Degree in IT, Computer Science, Information Systems, or related field.
Minimum 2 years of experience as an iOS Developer.
Proficient in Swift and native iOS development (UIKit/SwiftUI).
Strong understanding of iOS architectures (MVC, MVVM, VIPER, Clean Architecture).
Experience with RESTful APIs, JSON, OAuth/JWT, and local storage (Core Data, UserDefaults, SQLite).
Familiar with Git, Xcode, Swift Package Manager/CocoaPods, and iOS debugging tools.
Understanding of concurrency (GCD, async/await).
Experience with App Store deployment and application lifecycle.
"""
