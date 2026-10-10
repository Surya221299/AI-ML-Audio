//
//  DomainTests.swift
//  InterviewTimeTests
//

import Foundation
import Testing
@testable import InterviewTime

@Suite struct DomainTests {

    @Test func questionValidatorAcceptsFocusedQuestions() {
        let q1 = "Jelaskan bagaimana cara kerja garbage collector pada Go?"
        let q2 = "Apa perbedaan antara buffered channel dan unbuffered channel?"
        let q3 = "Bagaimana Anda mengoptimasi query database yang lambat?"

        #expect(QuestionValidator.isFocusedQuestion(q1))
        #expect(QuestionValidator.isFocusedQuestion(q2))
        #expect(QuestionValidator.isFocusedQuestion(q3))
    }

    @Test func questionValidatorRejectsOverloadedQuestions() {
        // Overloaded with 3 concepts or multiple connectors
        let q1 = "Jelaskan goroutine, channel, serta mutex pada sistem distributed?"
        let q2 = "Bagaimana Anda menggunakan Docker dan Kubernetes dan CI/CD?"
        let q3 = "Jelaskan arsitektur microservices, REST API, maupun gRPC?"
        let q4 = ""

        #expect(!QuestionValidator.isFocusedQuestion(q1))
        #expect(!QuestionValidator.isFocusedQuestion(q2))
        #expect(!QuestionValidator.isFocusedQuestion(q3))
        #expect(!QuestionValidator.isFocusedQuestion(q4))
    }

    @Test func declineHeuristicsDetection() {
        let questionInput1 = "Apakah ada asuransi kesehatan untuk keluarga?"
        let questionInput2 = "Bagaimana budaya kerja di tim backend?"
        let questionInput3 = "Boleh saya tahu jenjang karir untuk posisi ini?"

        #expect(DeclineHeuristics.hasQuestionIndicators(questionInput1))
        #expect(DeclineHeuristics.hasQuestionIndicators(questionInput2))
        #expect(DeclineHeuristics.hasQuestionIndicators(questionInput3))

        let declineInput1 = "Sudah cukup, tidak ada pertanyaan lagi."
        let declineInput2 = "Tidak ada, terima kasih."
        let declineInput3 = "Sekian dari saya, sudah jelas."

        #expect(DeclineHeuristics.hasDeclineIndicators(declineInput1))
        #expect(DeclineHeuristics.hasDeclineIndicators(declineInput2))
        #expect(DeclineHeuristics.hasDeclineIndicators(declineInput3))
    }

    @Test func overallFeedbackMappingFromJSONValue() {
        let json: JSONValue = .object([
            "overall_score": .number(8.5),
            "recommendation": .string("Hire"),
            "strengths": .array([.string("Deep Golang knowledge"), .string("Clear communication")]),
            "weaknesses_or_gaps": .array([.string("Needs more cloud experience")]),
            "red_flags": .array([]),
            "fit_vs_jd": .string("High alignment"),
            "feedback_for_candidate": .array([.string("Learn Kubernetes basics")])
        ])

        let fb = OverallFeedback.from(json: json)
        #expect(fb != nil)
        #expect(fb?.overallScore == 8.5)
        #expect(fb?.recommendation == "Hire")
        #expect(fb?.strengths.count == 2)
        #expect(fb?.weaknessesOrGaps.count == 1)
        #expect(fb?.fitVsJD == "High alignment")
        #expect(fb?.feedbackForCandidate.first == "Learn Kubernetes basics")
    }

    @Test func questionFeedbackMappingFromJSONValue() {
        let json: JSONValue = .object([
            "question": .string("Apa perbedaan buffered vs unbuffered channel?"),
            "plus_points": .array([.string("Menjelaskan deadlock dengan tepat")]),
            "improvements": .array([.string("Sertakan contoh kasus nyata")])
        ])

        let qfb = QuestionFeedback.from(json: json)
        #expect(qfb != nil)
        #expect(qfb?.question == "Apa perbedaan buffered vs unbuffered channel?")
        #expect(qfb?.plusPoints.first == "Menjelaskan deadlock dengan tepat")
        #expect(qfb?.improvements.first == "Sertakan contoh kasus nyata")
    }
}
