//
//  AssessmentTypes.swift
//  InterviewTime
//
//  Tipe pendukung + jembatan agar Assessment.swift, FillerDetector.swift,
//  AudioAnalysis.swift (dari app analisis) kompatibel dengan Models kita.
//

import Foundation

// Assessment.swift memakai tipe `Word` dengan properti `.prob`,
// sedangkan Models kita punya `TranscriptWord` dengan `.probability`.
typealias Word = TranscriptWord

extension TranscriptWord {
    /// Alias agar cocok dengan Assessment.swift yang mengakses `.prob`.
    var prob: Double { probability }
}

// Hasil assessment kuantitatif.
struct CategoryScore: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let score: Double                    // 0–100
    let metrics: [(String, String)]      // pasangan (nama, nilai) untuk detail
}

struct AssessmentReport {
    let overall: Double                  // 0–100
    let categories: [CategoryScore]
}
