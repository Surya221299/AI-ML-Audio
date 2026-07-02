//
//  ConversationView.swift
//  InterviewTime
//
//  Tampilan interview fullscreen (UI ala Nico, tanpa teks). Semua video sudah
//  disiapkan oleh InterviewPrep di layar Start — view ini hanya MEMUTAR:
//  opening → jawab → pertanyaan 1-4 (dari folder) → closing.
//

import SwiftUI
import AVFoundation
import AppKit

struct ConversationView: View {

    @ObservedObject var prep: InterviewPrep
    var onExit: () -> Void = {}

    @State private var player: AVQueuePlayer?
    @State private var portrait: NSImage?
    @State private var isTalking = false
    @State private var isBusy = false
    @State private var currentQ = 0
    @State private var transcripts: [String] = []
    @State private var started = false
    @State private var atClosing = false          // sedang di pertanyaan penutup
    @State private var overallFB: JSONValue? = nil
    @State private var questionFBs: [JSONValue] = []
    @State private var noQuestionsFB: String = ""
    @State private var declinedAtClosing = false
    @State private var showFeedback = false
    @State private var noQFBDone = false      // bagian 1 selesai
    @State private var overallDone = false    // bagian 2 selesai
    @State private var questionsDoneCount = 0 // berapa per-question sudah masuk

    var body: some View {
        ZStack {
            Color(hex: "050709").ignoresSafeArea()

            if let portrait {
                Image(nsImage: portrait)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            if isTalking, let player {
                FullScreenVideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            if isBusy {
                ProgressView().controlSize(.large).tint(.white)
            }

            // Name tag
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemala").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("AI/ML Engineer Manager").font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 16).padding(.bottom, 14)
                    Spacer()
                }
            }

            // Kontrol: bar hitam full-width + tombol Rekam & Jawab / Selesai
            if !showFeedback {
                VStack(spacing: 0) {
                    Spacer()
                    let controlDisabled = isBusy || isTalking
                    Button(action: { Task { await answerThenNext() } }) {
                        HStack(spacing: 8) {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 15, weight: .semibold))
                            Text(isRecording ? "Selesai" : "Rekam & Jawab")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isRecording ? Color.red.opacity(0.9) : Color.green.opacity(0.9))
                        )
                        .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(controlDisabled)
                    .opacity(controlDisabled ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.2), value: controlDisabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.9))
                }
            }
            // Dim + blur gelap seperti panggilan terputus
            if showFeedback {
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // Overlay feedback dari kanan (50% width)
            if showFeedback {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Spacer()
                        feedbackPanel
                            .frame(width: geo.size.width * 0.5)
                            .frame(maxHeight: .infinity)
                            .background(Color(hex: "16161A"))
                            .transition(.move(edge: .trailing))
                    }
                }
                .ignoresSafeArea()
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .animation(.easeInOut(duration: 0.4), value: isTalking)
        .animation(.easeInOut(duration: 0.35), value: showFeedback)
        .task {
            guard !started else { return }
            started = true
            portrait = NSImage(named: "Interviewer")
            await playOpening()
        }
    }

    // Recorder milik prep tidak ada; buat sendiri di sini
    @StateObject private var recorder = AudioRecorder()
    private var isRecording: Bool { recorder.isRecording }

    // MARK: - Alur

    private func playOpening() async {
        isBusy = true
        if let urls = prep.loadSaved(prep.openingDir) {
            await playItems(urls)
        }
        isBusy = false
    }

    private func answerThenNext() async {
        if recorder.isRecording {
            guard let url = recorder.stop() else { return }
            isBusy = true; defer { isBusy = false }
            var answer = ""
            do {
                let stt = try await prep.whisper.transcribe(url: url)
                answer = stt.text
                transcripts.append(stt.text)
            } catch { transcripts.append("") }

            if atClosing {
                let decline = await prep.classifyDecline(answer)
                await finishAndShowFeedback(declined: decline)
            } else {
                await playNextQuestion()
            }
        } else {
            guard await recorder.requestPermission() else { return }
            try? recorder.start()
        }
    }

    private func finishAndShowFeedback(declined: Bool) async {
        isTalking = false
        showFeedback = true
        declinedAtClosing = declined
        // reset progres
        noQFBDone = false; overallDone = false; questionsDoneCount = 0
        questionFBs = []
        let position = prep.jobDescription

        // ── 1. Feedback tidak bertanya balik (kalau decline) — tampil PERTAMA ──
        if declined {
            noQuestionsFB = await prep.generateNoQuestionsFeedback(position: position)
        }
        noQFBDone = true   // walau tidak decline, tandai selesai agar bagian berikut tampil

        // ── 2. Feedback keseluruhan ──
        overallFB = await prep.generateOverallFeedback(
            jobDescription: position, questions: prep.questions, transcripts: transcripts)
        overallDone = true

        // ── 3. Feedback per pertanyaan — satu per satu ──
        for (i, q) in prep.questions.enumerated() {
            let ans = i < transcripts.count ? transcripts[i] : ""
            let fb = await prep.generateQuestionFeedback(question: q, answer: ans, position: position)
            questionFBs.append(fb)
            questionsDoneCount = questionFBs.count
        }
    }

    // MARK: - Feedback panel

    private var feedbackPanel: some View {
        ScrollView {
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
                        if let score = fb["overall_score"]?.doubleValue {
                            Text("Skor Keseluruhan: \(Int(score))/10")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundColor(Color(hex: 0xD97757))
                        }
                        if let rec = fb["recommendation"]?.stringValue {
                            Text(rec).font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        if let fit = fb["fit_vs_jd"]?.stringValue, !fit.isEmpty {
                            Text(fit).font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        feedbackList("✅ Kekuatan", fb["strengths"]?.stringArray())
                        feedbackList("🔧 Perlu Ditingkatkan", fb["weaknesses_or_gaps"]?.stringArray())
                        feedbackList("⚠️ Red Flags", fb["red_flags"]?.stringArray())
                        feedbackList("💡 Saran untuk Kamu", fb["feedback_for_candidate"]?.stringArray())
                    } else {
                        loadingRow("Menyusun feedback keseluruhan…")
                    }
                }

                // ── Bagian 3: Per pertanyaan (muncul satu per satu) ──
                if overallDone {
                    Divider().background(Color.white.opacity(0.15))
                    sectionTitle("Feedback per Pertanyaan")
                    ForEach(Array(questionFBs.enumerated()), id: \.offset) { idx, fb in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pertanyaan \(idx+1)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(hex: 0xD97757))
                            if let q = fb["question"]?.stringValue {
                                Text(q).font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            feedbackList("Bagus", fb["plus_points"]?.stringArray())
                            feedbackList("Perbaikan", fb["improvements"]?.stringArray())
                        }
                        .padding(12).background(Color.white.opacity(0.04)).cornerRadius(8)
                    }
                    if questionsDoneCount < prep.questions.count {
                        loadingRow("Menilai pertanyaan \(questionsDoneCount + 1) dari \(prep.questions.count)…")
                    }
                }

                // Tombol selesai hanya saat semua rampung
                if overallDone && questionsDoneCount >= prep.questions.count {
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
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 16, weight: .bold)).foregroundColor(.white)
    }

    private func loadingRow(_ msg: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(.white)
            Text(msg).font(.system(size: 13)).foregroundColor(.white.opacity(0.65))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func feedbackList(_ title: String, _ items: [String]?) -> some View {
        if let items, !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                ForEach(items, id: \.self) { it in
                    Text("• \(it)").font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func playNextQuestion() async {
        if currentQ >= prep.questions.count {
            // Semua pertanyaan selesai → putar closing, lalu tunggu jawaban penutup
            atClosing = true
            if let urls = prep.loadSaved(prep.closingDir) { await playItems(urls) }
            return
        }
        let i = currentQ
        currentQ += 1
        if let urls = prep.loadSaved(prep.questionDir(i)) {
            await playItems(urls)
        }
    }

    @MainActor private func playItems(_ urls: [URL]) {
        let items = urls.map { AVPlayerItem(url: $0) }
        let q = AVQueuePlayer()
        for it in items { q.insert(it, after: nil) }
        if let last = items.last {
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: last, queue: .main
            ) { _ in self.isTalking = false }
        }
        player = q
        isTalking = true
        q.play()
    }
}
