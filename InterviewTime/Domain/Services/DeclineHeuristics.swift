//
//  DeclineHeuristics.swift
//  InterviewTime
//

import Foundation

public struct DeclineHeuristics: Sendable {
    public static let questionKeywords = [
        "?", "apa", "apakah", "bagaimana", "gimana", "berapa", "kapan",
        "kenapa", "mengapa", "siapa", "boleh saya tahu", "bisa dijelaskan",
        "ingin tahu", "mau tanya", "izin bertanya"
    ]

    public static let declineKeywords = [
        "tidak ada", "gak ada", "nggak ada", "cukup", "sudah cukup",
        "tidak", "sekian", "terima kasih saja", "no", "sudah jelas"
    ]

    /// Returns `true` if text clearly looks like a question, `false` otherwise.
    public static func hasQuestionIndicators(_ text: String) -> Bool {
        let lower = text.lowercased()
        return questionKeywords.contains(where: { lower.contains($0) })
    }

    /// Returns `true` if text matches common decline / closing phrases.
    public static func hasDeclineIndicators(_ text: String) -> Bool {
        let lower = text.lowercased()
        return declineKeywords.contains(where: { lower.contains($0) })
    }
}
