//
//  FeedbackPanelView.swift
//  InterviewTime
//

import SwiftUI

struct FeedbackPanelView: View {
    let declinedAtClosing: Bool
    let noQFBDone: Bool
    let noQuestionsFB: String
    let overallDone: Bool
    let overallFB: OverallFeedback?
    let questionFBs: [QuestionFeedback]
    let transcripts: [String]
    let questionsDoneCount: Int
    let totalQuestions: Int
    let onExit: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Hasil Interview")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)

                // ── Bagian 1: Tidak bertanya balik (kalau decline) ──
                if declinedAtClosing {
                    if noQFBDone {
                        if !noQuestionsFB.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.red)
                                    Text("Tidak Bertanya Balik")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.red)
                                }
                                Text(noQuestionsFB)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.red.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.red.opacity(0.4), lineWidth: 1)
                            )
                        }
                    } else {
                        loadingRow("Menganalisis sesi tanya-jawab penutup…")
                    }
                }

                // ── Bagian 2: Keseluruhan ──
                if noQFBDone {
                    if overallDone, let fb = overallFB {
                        Divider().background(Color.white.opacity(0.15))
                        if !fb.recommendation.isEmpty {
                            Text(fb.recommendation)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !fb.fitVsJD.isEmpty {
                            Text(fb.fitVsJD)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        feedbackBlock(title: "Kekuatan", items: fb.strengths, type: .positive)
                        feedbackBlock(title: "Perlu Ditingkatkan", items: fb.weaknessesOrGaps, type: .improvement)
                        feedbackBlock(title: "Saran untuk Kamu", items: fb.feedbackForCandidate, type: .neutral)
                    } else {
                        loadingRow("Menyusun feedback keseluruhan…")
                    }
                }

                // ── Bagian 3: Per pertanyaan (muncul satu per satu) ──
                if overallDone {
                    Divider().background(Color.white.opacity(0.15))
                    sectionTitle("Feedback per Pertanyaan")
                    ForEach(Array(questionFBs.enumerated()), id: \.offset) { idx, fb in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pertanyaan \(idx + 1)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(hex: 0xD97757))
                            if !fb.question.isEmpty {
                                Text(fb.question)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Transkrip jawaban kandidat
                            let ans = idx < transcripts.count ? transcripts[idx] : ""
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Jawaban kamu")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.5))
                                Text(ans.isEmpty ? "(tidak ada jawaban)" : ans)
                                    .font(.system(size: 12))
                                    .italic()
                                    .foregroundColor(.white.opacity(0.7))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(6)
                            .padding(.vertical, 2)

                            feedbackBlock(title: "Bagus", items: fb.plusPoints, type: .positive)
                            feedbackBlock(title: "Perlu Ditingkatkan", items: fb.improvements, type: .improvement)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(8)
                    }
                    if questionsDoneCount < totalQuestions {
                        loadingRow("Menilai pertanyaan \(questionsDoneCount + 1) dari \(totalQuestions)…")
                    }
                }

                // Tombol selesai hanya saat semua rampung
                if overallDone && questionsDoneCount >= totalQuestions {
                    Button("Selesai") { onExit() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.easeInOut(duration: 0.3), value: noQFBDone)
            .animation(.easeInOut(duration: 0.3), value: overallDone)
            .animation(.easeInOut(duration: 0.3), value: questionsDoneCount)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
    }

    private func loadingRow(_ msg: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(msg)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private enum FeedbackBlockType {
        case positive
        case improvement
        case neutral
    }

    @ViewBuilder
    private func feedbackBlock(title: String, items: [String]?, type: FeedbackBlockType) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    switch type {
                    case .positive:
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.green)
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                    case .improvement:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.yellow)
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)
                    case .neutral:
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Color(hex: 0x64B5F6))
                        Text(title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(Color(hex: 0x64B5F6))
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items, id: \.self) { it in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(accentColor(for: type))
                            Text(it)
                                .font(.system(size: 13))
                                .foregroundColor(itemTextColor(for: type))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(blockBackgroundColor(for: type))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(blockBorderColor(for: type), lineWidth: 1)
            )
        }
    }

    private func accentColor(for type: FeedbackBlockType) -> Color {
        switch type {
        case .positive: return .green
        case .improvement: return .yellow
        case .neutral: return Color(hex: 0x64B5F6)
        }
    }

    private func itemTextColor(for type: FeedbackBlockType) -> Color {
        switch type {
        case .positive: return Color.green.opacity(0.92)
        case .improvement: return Color.yellow.opacity(0.92)
        case .neutral: return Color.white.opacity(0.85)
        }
    }

    private func blockBackgroundColor(for type: FeedbackBlockType) -> Color {
        switch type {
        case .positive: return Color.green.opacity(0.12)
        case .improvement: return Color.yellow.opacity(0.12)
        case .neutral: return Color.blue.opacity(0.08)
        }
    }

    private func blockBorderColor(for type: FeedbackBlockType) -> Color {
        switch type {
        case .positive: return Color.green.opacity(0.3)
        case .improvement: return Color.yellow.opacity(0.3)
        case .neutral: return Color.blue.opacity(0.2)
        }
    }
}
