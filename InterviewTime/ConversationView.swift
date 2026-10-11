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

    @StateObject private var avatar = AvatarPlaybackController()
    @StateObject private var recorder = AudioRecorder()

    @State private var portrait: NSImage?
    @State private var isBusy = false
    @State private var currentQ = 0
    @State private var followUpsUsed = 0
    @State private var followUpText = ""
    @State private var awaitingFollowUpAnswer = false
    @State private var activeQuestionIndex: Int? = nil
    @State private var transcripts: [String] = []
    @State private var started = false

    // UI video-call (dekoratif, ala Zoom)
    @State private var micOn = true
    @State private var cameraOn = false
    @State private var pipOffset: CGSize = .zero
    @State private var atClosing = false          // sedang di pertanyaan penutup
    @State private var closingQACount = 0         // berapa kali kandidat bertanya balik

    // Typed Feedbacks
    @State private var overallFB: OverallFeedback? = nil
    @State private var questionFBs: [QuestionFeedback] = []
    @State private var noQuestionsFB: String = ""
    @State private var declinedAtClosing = false
    @State private var showFeedback = false
    @State private var noQFBDone = false      // bagian 1 selesai
    @State private var overallDone = false    // bagian 2 selesai
    @State private var questionsDoneCount = 0 // berapa per-question sudah masuk

    private var isRecording: Bool { recorder.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            callTopBar

            ZStack {
                VideoStageView(
                    player: avatar.player,
                    idleLoopPlayer: avatar.idleLoopPlayer,
                    previousIdleLoopPlayer: avatar.previousIdleLoopPlayer,
                    idleLoopVisible: avatar.idleLoopVisible,
                    portrait: portrait,
                    isTalking: avatar.isTalking,
                    isBusy: isBusy
                )

                // Self-view PiP kamera user — pojok kanan bawah
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        selfViewPiP
                            .padding(.trailing, 16)
                            .padding(.bottom, 14)
                            .offset(pipOffset)
                            .gesture(DragGesture().onChanged { v in pipOffset = v.translation })
                    }
                }

                // Feedback overlay (tampilan vertikal terpusat, tidak terpotong ke kanan)
                if showFeedback {
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    VStack(spacing: 0) {
                        FeedbackPanelView(
                            declinedAtClosing: declinedAtClosing,
                            noQFBDone: noQFBDone,
                            noQuestionsFB: noQuestionsFB,
                            overallDone: overallDone,
                            overallFB: overallFB,
                            questionFBs: questionFBs,
                            transcripts: transcripts,
                            questionsDoneCount: questionsDoneCount,
                            totalQuestions: prep.questions.count,
                            onExit: { leaveSession() }
                        )
                        .frame(maxWidth: 860)
                        .frame(maxHeight: .infinity)
                        .background(Color(hex: "16161A"))
                        .overlay(
                            Rectangle()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 10)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !showFeedback {
                CallControlBar(
                    micOn: $micOn,
                    cameraOn: $cameraOn,
                    isRecording: isRecording,
                    controlDisabled: isBusy || avatar.isTalking,
                    onRecordToggled: { Task { await answerThenNext() } },
                    onLeave: { leaveSession() }
                )
            }
        }
        .background(Color.black)
        .frame(minWidth: 900, minHeight: 640)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.4), value: avatar.isTalking)
        .animation(.easeInOut(duration: 0.35), value: showFeedback)
        .task {
            guard !started else { return }
            started = true
            transcripts = Array(repeating: "", count: prep.questions.count)
            portrait = InterviewPrep.loadInterviewerImage()
            avatar.startInitialIdleLoop(outputsRoot: prep.outputsRoot)
            await playOpening()
        }
        .onDisappear {
            avatar.stopAndCleanUp()
        }
    }

    // MARK: - Top bar

    private var callTopBar: some View {
        HStack {
            Button(action: { leaveSession() }) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Leave").font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.black.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    private func leaveSession() {
        avatar.stopAndCleanUp()
        onExit()
    }

    // MARK: - Self-view PiP

    private var selfViewPiP: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: "141820"))
            CameraPreview(isActive: cameraOn)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(cameraOn ? 1 : 0)
            if !cameraOn {
                VStack(spacing: 5) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 20)).foregroundColor(.white.opacity(0.4))
                    Text("Camera off")
                        .font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.3))
                }
            }
            RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .frame(width: 112, height: 82)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }

    // MARK: - Alur Interview

    private func playOpening() async {
        isBusy = true
        if let urls = prep.loadSaved(prep.openingDir) {
            avatar.playItems(urls)
        }
        isBusy = false
    }

    private func answerThenNext() async {
        if recorder.isRecording {
            guard let url = recorder.stop() else { return }
            isBusy = true
            defer { isBusy = false }
            var answer = ""
            do {
                let stt = try await prep.whisper.transcribe(url: url)
                answer = stt.text
            } catch {
                answer = ""
            }

            if awaitingFollowUpAnswer {
                awaitingFollowUpAnswer = false
                if let qIdx = activeQuestionIndex, qIdx < transcripts.count {
                    transcripts[qIdx] += " " + answer
                }
                await playNextQuestion()
            } else if atClosing {
                await handleClosingAnswer(answer)
            } else {
                if let qIdx = activeQuestionIndex, qIdx < transcripts.count {
                    transcripts[qIdx] = answer
                }
                // Follow-up (maks 2, hanya jika RunPod aktif)
                if prep.followUpEnabled, followUpsUsed < prep.maxFollowUps,
                   let qIdx = activeQuestionIndex, qIdx < prep.questions.count {
                    let fu = await prep.generateFollowUp(question: prep.questions[qIdx], answer: answer)
                    if !fu.isEmpty {
                        let urls = await prep.renderFollowUp(text: fu)
                        if let urls, !urls.isEmpty {
                            followUpsUsed += 1
                            followUpText = fu
                            avatar.playItems(urls)
                            awaitingFollowUpAnswer = true
                            return
                        }
                    }
                }
                await playNextQuestion()
            }
        } else {
            guard await recorder.requestPermission() else { return }
            try? recorder.start()
        }
    }

    private func playNextQuestion() async {
        if currentQ >= prep.questions.count {
            atClosing = true
            if let urls = prep.loadSaved(prep.closingDir) {
                avatar.playItems(urls)
            }
            return
        }
        let i = currentQ
        currentQ += 1
        activeQuestionIndex = i
        if let urls = prep.loadSaved(prep.questionDir(i)) {
            avatar.playItems(urls)
        }
    }

    private func handleClosingAnswer(_ answer: String) async {
        if closingQACount >= prep.maxClosingQA {
            await finishAndShowFeedback(declined: false)
            return
        }

        let decline = await prep.classifyDecline(answer)
        if decline {
            await finishAndShowFeedback(declined: closingQACount == 0)
            return
        }

        closingQACount += 1
        let cat = await prep.classifyClosingCategory(answer)
        if let urls = prep.loadSaved(prep.answerDir(cat)) {
            avatar.playItems(urls)
        }
    }

    private func finishAndShowFeedback(declined: Bool) async {
        avatar.returnToIdle()
        showFeedback = true
        prep.interviewCompleted = true
        prep.feedbackCompleted = true
        declinedAtClosing = declined
        noQFBDone = false
        overallDone = false
        questionsDoneCount = 0
        questionFBs = []
        let position = prep.jobDescription

        // 1. Feedback tidak bertanya balik (kalau decline)
        if declined {
            noQuestionsFB = await prep.generateNoQuestionsFeedback(position: position)
        }
        noQFBDone = true

        // 2. Feedback keseluruhan
        let overallRaw = await prep.generateOverallFeedback(
            jobDescription: position,
            questions: prep.questions,
            transcripts: transcripts
        )
        overallFB = OverallFeedback.from(json: overallRaw)
        overallDone = true

        // 3. Feedback per pertanyaan
        for (i, q) in prep.questions.enumerated() {
            let ans = i < transcripts.count ? transcripts[i] : ""
            let qRaw = await prep.generateQuestionFeedback(question: q, answer: ans, position: position)
            if let qTyped = QuestionFeedback.from(json: qRaw) {
                questionFBs.append(qTyped)
            }
            questionsDoneCount = questionFBs.count
        }
    }
}
