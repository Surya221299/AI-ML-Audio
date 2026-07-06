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
    @State private var followUpsUsed = 0
    @State private var followUpText = ""
    @State private var awaitingFollowUpAnswer = false
    @State private var activeQuestionIndex: Int? = nil
    @State private var transcripts: [String] = []
    @State private var started = false
    // Idle loop (adopsi dari MuseTalkView teman)
    @State private var idleLoopPlayer: AVQueuePlayer?
    @State private var idleLoopVisible = false
    @State private var previousIdleLoopPlayer: AVQueuePlayer?
    @State private var idleLooper: AVPlayerLooper?
    @State private var currentIdleLoopURL: URL?
    @State private var idleReadyObserver: NSKeyValueObservation?
    // Streaming/session
    @State private var startedPlayback = false
    @State private var generationDone = false
    // UI video-call (dekoratif, ala Zoom)
    @State private var micOn = true
    @State private var cameraOn = false
    @State private var showSettings = false
    @State private var pipOffset: CGSize = .zero
    @State private var atClosing = false          // sedang di pertanyaan penutup
    @State private var closingQACount = 0         // berapa kali kandidat bertanya balik
    @State private var overallFB: JSONValue? = nil
    @State private var questionFBs: [JSONValue] = []
    @State private var noQuestionsFB: String = ""
    @State private var declinedAtClosing = false
    @State private var showFeedback = false
    @State private var noQFBDone = false      // bagian 1 selesai
    @State private var overallDone = false    // bagian 2 selesai
    @State private var questionsDoneCount = 0 // berapa per-question sudah masuk

    var body: some View {
        VStack(spacing: 0) {
            callTopBar

            ZStack {
                videoArea

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

                // Feedback overlay (dim + panel kanan 50%)
                if showFeedback {
                    Rectangle().fill(.black.opacity(0.6))
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea().transition(.opacity)
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
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !showFeedback { callControlBar }
        }
        .background(Color.black)
        .overlay(alignment: .trailing) {
            if showSettings {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.22)) { showSettings = false } }
                    settingsSidebar
                        .frame(width: 320).frame(maxHeight: .infinity)
                        .background(Color(hex: "0e1117"))
                        .transition(.move(edge: .trailing))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showSettings)
        .frame(minWidth: 900, minHeight: 640)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.4), value: isTalking)
        .animation(.easeInOut(duration: 0.35), value: showFeedback)
        .task {
            guard !started else { return }
            started = true
            portrait = NSImage(named: "Interviewer")
            startInitialIdleLoop()
            await playOpening()
        }
    }

    // MARK: - Top bar

    private var callTopBar: some View {
        HStack {
            Button(action: { onExit() }) {
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

    // MARK: - Video area (idle loop + talking + name tag)

    private var videoArea: some View {
        ZStack {
            Color(hex: "050709").frame(maxWidth: .infinity, maxHeight: .infinity)

            if let previousIdleLoopPlayer {
                FullScreenVideoPlayer(player: previousIdleLoopPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let idleLoopPlayer {
                FullScreenVideoPlayer(player: idleLoopPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(idleLoopVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: idleLoopVisible)
            } else if let portrait {
                Image(nsImage: portrait)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
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
                        Text("Gemala").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                        Text("AI/ML Engineer Manager").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 16).padding(.bottom, 14)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.3), value: isTalking)
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

    // MARK: - Control bar (mic/camera dekoratif + Rekam & Jawab + settings/leave)

    private var callControlBar: some View {
        let controlDisabled = isBusy || isTalking
        return HStack(spacing: 0) {
            HStack(spacing: 14) {
                callControlButton(icon: micOn ? "mic.fill" : "mic.slash.fill",
                                  label: micOn ? "Mute" : "Unmute",
                                  tint: micOn ? .white : .red, highlighted: !micOn) { micOn.toggle() }
                callControlButton(icon: cameraOn ? "video.fill" : "video.slash.fill",
                                  label: "Camera",
                                  tint: cameraOn ? .white : .red, highlighted: !cameraOn) { cameraOn.toggle() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Tombol utama: Rekam & Jawab
            Button(action: { Task { await answerThenNext() } }) {
                HStack(spacing: 8) {
                    Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text(isRecording ? "Selesai" : "Rekam & Jawab")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background(isRecording ? Color.red.opacity(0.9) : Color.green.opacity(0.9), in: Capsule())
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(controlDisabled)
            .opacity(controlDisabled ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: controlDisabled)

            HStack(spacing: 14) {
                callControlButton(icon: "gearshape.fill", label: "Settings",
                                  tint: showSettings ? .white : .secondary, highlighted: showSettings) {
                    withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
                }
                Button(action: { onExit() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 15)).foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red, in: Circle())
                        Text("Leave").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .background(.black.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func callControlButton(icon: String, label: String, tint: Color,
                                   highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundColor(tint)
                    .frame(width: 44, height: 44)
                    .background(highlighted ? Color.white.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
                Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
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
            } catch { answer = "" }

            if awaitingFollowUpAnswer {
                // Jawaban atas follow-up: catat sebagai lanjutan jawaban pertanyaan aktif, lalu lanjut
                awaitingFollowUpAnswer = false
                if let qIdx = activeQuestionIndex, qIdx < transcripts.count {
                    transcripts[qIdx] += " " + answer
                }
                await playNextQuestion()
            } else if atClosing {
                await handleClosingAnswer(answer)
            } else {
                // Jawaban interview → simpan transkrip
                transcripts.append(answer)
                // Follow-up (maks 2, hanya jika RunPod aktif) — pertanyaan yang barusan dijawab
                if prep.followUpEnabled, followUpsUsed < prep.maxFollowUps,
                   let qIdx = activeQuestionIndex, qIdx < prep.questions.count {
                    let fu = await prep.generateFollowUp(question: prep.questions[qIdx], answer: answer)
                    if !fu.isEmpty {
                        // Render dulu; kuota hanya naik kalau BERHASIL.
                        let urls = await prep.renderFollowUp(text: fu)
                        if let urls, !urls.isEmpty {
                            followUpsUsed += 1        // sukses → baru pakai kuota
                            followUpText = fu
                            await playItems(urls)
                            awaitingFollowUpAnswer = true
                            return
                        }
                        // Render gagal (mis. RunPod error) → kuota TIDAK terpakai, lanjut normal.
                    }
                }
                await playNextQuestion()
            }
        } else {
            guard await recorder.requestPermission() else { return }
            try? recorder.start()
        }
    }

    /// Menangani fase penutup: kandidat bertanya balik (maks 3) atau decline → feedback.
    private func handleClosingAnswer(_ answer: String) async {
        // Sudah mencapai batas → apa pun jawabannya, tutup + feedback (sudah pernah bertanya)
        if closingQACount >= prep.maxClosingQA {
            await finishAndShowFeedback(declined: false)
            return
        }

        let decline = await prep.classifyDecline(answer)
        if decline {
            // Kalau BELUM pernah bertanya sama sekali → feedback "tidak bertanya balik".
            // Kalau sudah pernah bertanya lalu sekarang bilang cukup → bukan "tidak bertanya".
            await finishAndShowFeedback(declined: closingQACount == 0)
            return
        }

        // Kandidat bertanya balik → classify → putar video jawaban yang sudah siap
        closingQACount += 1
        let cat = await prep.classifyClosingCategory(answer)
        if let urls = prep.loadSaved(prep.answerDir(cat)) {
            await playItems(urls)
        }
        // Tidak langsung tutup — setelah video selesai, tombol aktif lagi.
        // Kandidat boleh bertanya lagi; kalau sudah 3x, giliran berikutnya otomatis tutup
        // (dicegat oleh guard closingQACount >= maxClosingQA di atas).
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

    // MARK: - Settings sidebar (RunPod / follow-up)

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Settings").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Button(action: { withAnimation(.easeInOut(duration: 0.22)) { showSettings = false } }) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary).padding(7)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }.buttonStyle(.plain)
                }

                Divider().background(Color.white.opacity(0.08))

                // Follow-up via RunPod
                VStack(alignment: .leading, spacing: 8) {
                    Text("FOLLOW-UP QUESTION (RUNPOD)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary).tracking(1.2)
                    Text(prep.followUpEnabled
                         ? "Aktif — maks \(prep.maxFollowUps) follow-up. Isi RunPod untuk TTS cepat."
                         : "Nonaktif — isi endpoint & API key untuk mengaktifkan follow-up.")
                        .font(.system(size: 11)).foregroundColor(prep.followUpEnabled ? .green : .secondary)

                    TextField("RunPod endpoint ID", text: $prep.runpodEndpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        .padding(10).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    SecureField("RunPod API key", text: $prep.runpodKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(.white)
                        .padding(10).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))

                    Text("Follow-up dipakai: \(followUpsUsed) / \(prep.maxFollowUps)")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.5))
                }

                Divider().background(Color.white.opacity(0.08))

                Text("Catatan: RunPod mempercepat TTS. Render lip-sync tetap lokal, jadi tetap ada jeda beberapa detik.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
            }
            .padding(20)
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

    /// Menunggu sampai video yang sedang diputar selesai (isTalking jadi false).
    private func waitTalkingEnd() async {
        while isTalking {
            try? await Task.sleep(nanoseconds: 200_000_000)
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
        activeQuestionIndex = i
        if let urls = prep.loadSaved(prep.questionDir(i)) {
            await playItems(urls)
        }
    }

    @State private var endObserver: NSObjectProtocol?

    @MainActor private func playItems(_ urls: [URL]) {
        // Sistem streaming enqueue + idle (adopsi MuseTalkView teman):
        // segmen pertama memulai playback & isTalking; sisanya di-antre.
        // Saat semua segmen habis, kembali ke idle loop.
        beginTalkingSession()
        let tmpItems = urls.map { AVPlayerItem(url: $0) }
        for it in tmpItems { enqueue(it) }
        generationDone = true
        // Kalau tak ada video, langsung kembali idle
        if !startedPlayback { returnToIdle() }
    }

    // MARK: - Talking session + streaming enqueue

    private func beginTalkingSession() {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        player?.pause()
        player = nil
        startedPlayback = false
        generationDone = false
    }

    private func enqueue(_ item: AVPlayerItem) {
        if !startedPlayback {
            let q = AVQueuePlayer(playerItem: item)
            q.actionAtItemEnd = .advance
            player = q
            startedPlayback = true
            isTalking = true
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { note in
                // hanya bereaksi ke segmen kita (seg_*.mp4), bukan idle loop di belakang
                guard let ended = note.object as? AVPlayerItem,
                      let url = (ended.asset as? AVURLAsset)?.url,
                      url.lastPathComponent.hasPrefix("seg_") else { return }
                if generationDone, (player?.items().count ?? 0) <= 1 {
                    returnToIdle()
                }
            }
            q.play()
        } else {
            player?.insert(item, after: nil)
        }
    }

    private func returnToIdle() {
        isTalking = false
        idleLoopPlayer?.seek(to: .zero)
        switchIdleLoop()
    }

    // MARK: - Idle loop (avatar diam bergerak)

    private func idleLoopURLs() -> [URL] {
        let dir = prep.outputsRoot
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("idle_loop") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func switchIdleLoop() {
        let candidates = idleLoopURLs()
        guard !candidates.isEmpty else { return }
        // idle_loop2 difavoritkan 6:1
        let weighted = candidates.flatMap { url in
            Array(repeating: url, count: url.lastPathComponent.contains("loop2") ? 6 : 1)
        }
        guard let next = weighted.randomElement() else { return }
        guard next != currentIdleLoopURL || idleLoopPlayer == nil else { return }
        playIdleLoop(next)
    }

    private func startInitialIdleLoop() {
        if let loop2 = idleLoopURLs().first(where: { $0.lastPathComponent.contains("loop2") }) {
            playIdleLoop(loop2)
        } else {
            switchIdleLoop()
        }
    }

    private func playIdleLoop(_ url: URL) {
        let p = AVQueuePlayer()
        p.isMuted = true
        let template = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: p, templateItem: template)
        idleReadyObserver?.invalidate()
        idleReadyObserver = p.observe(\.currentItem?.status, options: [.new, .initial]) { pl, _ in
            guard pl.currentItem?.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                previousIdleLoopPlayer = idleLoopPlayer
                currentIdleLoopURL = url
                idleLooper = looper
                idleLoopVisible = false
                idleLoopPlayer = p
                p.play()
                DispatchQueue.main.async { idleLoopVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    previousIdleLoopPlayer = nil
                }
            }
        }
    }
}
