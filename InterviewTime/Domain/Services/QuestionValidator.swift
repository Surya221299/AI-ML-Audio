//
//  QuestionValidator.swift
//  InterviewTime
//

import Foundation

public struct QuestionValidator: Sendable {
    /// Tolak pertanyaan yang menumpuk >=3 konsep atau terlalu banyak penghubung.
    public static func isFocusedQuestion(_ q: String) -> Bool {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        // Hitung penghubung penumpuk
        let connectors = [", ", " serta ", " dan juga ", " maupun "]
        var connectorCount = 0
        for c in connectors {
            connectorCount += lower.components(separatedBy: c).count - 1
        }
        // "dan" satu kali (untuk perbandingan dua hal) masih boleh; dua "dan" mencurigakan
        let andCount = lower.components(separatedBy: " dan ").count - 1
        // Terlalu banyak koma/penghubung → menumpuk konsep
        if connectorCount >= 2 { return false }
        if andCount >= 2 { return false }
        if connectorCount >= 1 && andCount >= 1 { return false }
        return true
    }
}
