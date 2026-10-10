//
//  InterviewTimeStart.swift
//  InterviewTime
//
//  Layar awal aplikasi macOS: tempel deskripsi pekerjaan
//  untuk memulai wawancara dengan AI.
//

import SwiftUI

// MARK: - Root View

struct InterviewTimeStartView: View {
    @State private var jobText: String = ""
    @StateObject private var prep = InterviewPrep()
    @State private var followUpOn = false
    @State private var enterInterview = false      // true → tampilkan ConversationView

    private var canStart: Bool {
        !jobText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if enterInterview {
                ConversationView(prep: prep, onExit: { enterInterview = false })
                    .background(Theme.bgWindow)
            } else {
                setupScreen
            }
        }
    }

    private var setupScreen: some View {
        HStack(spacing: 0) {
            sidebar
            inputPane
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(Theme.bgWindow)
    }

    // MARK: - Sidebar (branding)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // logo
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Theme.accentInk)
                            .frame(width: 11, height: 11)
                    )
                    .shadow(color: Theme.accent.opacity(0.35), radius: 7, y: 4)
                Text("GemalaAI")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: 0xEDEDF0))
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Latihan wawancara,\nditemani AI.")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(Color(hex: 0xF3F3F5))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Paste Job Description, lalu AI pewawancara akan mewawancaraimu lewat video call — dan menilai jawabanmu.")
                    .font(.system(size: 14.5))
                    .foregroundColor(Theme.textSecond)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 52)

            stepsList
                .padding(.top, 40)

            Spacer(minLength: 24)

            // footer badge
            HStack(spacing: 8) {
                Text("ON-DEVICE")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Theme.textFaint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bgSubtle))
                Text("STT lokal · LLM lokal")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textFaint)
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 1)
        }
    }

    // MARK: - Status Langkah

    private enum StepStatus { case completed, active, pending }

    private var step1Status: StepStatus {
        if prep.isReady || prep.isWorking || prep.interviewCompleted {
            return .completed
        } else if !jobText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .active
        }
        return .pending
    }

    private var step2Status: StepStatus {
        if prep.isReady || prep.interviewCompleted {
            return .completed
        } else if prep.isWorking {
            return .active
        }
        return .pending
    }

    private var step3Status: StepStatus {
        if prep.interviewCompleted {
            return .completed
        } else if prep.isReady {
            return .active
        }
        return .pending
    }

    private var step4Status: StepStatus {
        if prep.feedbackCompleted {
            return .completed
        } else if prep.interviewCompleted {
            return .active
        }
        return .pending
    }

    private var stepsList: some View {
        VStack(spacing: 9) {
            stepRow(1, "Paste Job Description", status: step1Status)
            stepRow(2, "AI menyusun & menyiapkan pertanyaan", status: step2Status)
            stepRow(3, "Kamu menjawab lewat video call", status: step3Status)
            stepRow(4, "Dapatkan skor & umpan balik", status: step4Status)
        }
        .animation(.easeInOut(duration: 0.3), value: step1Status)
        .animation(.easeInOut(duration: 0.3), value: step2Status)
        .animation(.easeInOut(duration: 0.3), value: step3Status)
        .animation(.easeInOut(duration: 0.3), value: step4Status)
    }

    private func stepRow(_ n: Int, _ label: String, status: StepStatus) -> some View {
        HStack(spacing: 12) {
            // Nomor / Checkmark badge
            ZStack {
                switch status {
                case .completed:
                    Circle()
                        .fill(Theme.accentInk.opacity(0.18))
                    Text("\(n)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.accentInk)
                case .active:
                    Circle()
                        .fill(Theme.accent)
                    Text("\(n)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Theme.accentInk)
                case .pending:
                    Circle()
                        .fill(Theme.bgSubtle)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    Text("\(n)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: 0x8A8A92))
                }
            }
            .frame(width: 24, height: 24)

            Text(label)
                .font(.system(size: 13, weight: status == .completed ? .semibold : (status == .active ? .medium : .regular)))
                .foregroundColor(
                    status == .completed ? Theme.accentInk :
                    (status == .active ? Color(hex: 0xF0F0F3) : Color(hex: 0x8E8E96))
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            // Indikator kanan
            if status == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accentInk.opacity(0.85))
            } else if status == .active && n == 2 && prep.isWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    status == .completed ? Theme.accent :
                    (status == .active ? Theme.accent.opacity(0.12) : Theme.bgSubtle.opacity(0.35))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    status == .completed ? Theme.accent :
                    (status == .active ? Theme.accent.opacity(0.45) : Theme.hairlineSoft),
                    lineWidth: 1
                )
        )
        .shadow(color: status == .completed ? Theme.accent.opacity(0.28) : .clear, radius: 8, y: 3)
    }

    // MARK: - Input pane

    private var inputPane: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("DESKRIPSI PEKERJAAN")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(1.6)
                        .foregroundColor(Theme.accent)
                    Text("Paste Job Description")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .padding(.top, 12)
                    Text("AI akan menyusun pertanyaan teknis yang relevan dari Job Description ini.")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecond)
                        .padding(.top, 6)

                    pasteArea
                        .padding(.top, 16)

                    if case .failed(let msg) = prep.stage {
                        errorBanner(msg)
                            .padding(.top, 16)
                    }

                    if prep.isWorking || prep.isReady {
                        prepStepsList
                            .padding(.top, 18)
                    }

                    if !prep.isWorking && !prep.isReady {
                        followUpPanel
                            .padding(.top, 18)
                    }

                    startButton
                        .padding(.top, 26)
                }
                .padding(.horizontal, 52)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: geo.size.height, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Paste Area

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.bgField)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1.5))

                if jobText.isEmpty {
                    Text("Paste Job Description di sini — peran, tanggung jawab, dan kualifikasi…")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textFaint)
                        .padding(.horizontal, 22).padding(.vertical, 24)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $jobText)
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: 0xEDEDF0))
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 14).padding(.vertical, 14)
            }
            .frame(height: 236)

            HStack {
                Text(wordCountText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                Button("Coba contoh lowongan") { jobText = Self.sampleJD }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: 0x9A9AA2))
                    .underline()
            }
        }
    }

    private var wordCountText: String {
        let trimmed = jobText.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = trimmed.isEmpty ? 0 : trimmed.split(whereSeparator: { $0.isWhitespace }).count
        return "\(n) kata"
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundColor(Color(hex: 0xE05D52))
            VStack(alignment: .leading, spacing: 2) {
                Text("Persiapan Terhenti")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFD2CF))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0xE8A09B))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: 0x361614).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: 0xE05D52).opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Daftar progres persiapan (shimmer)

    private var prepStepsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(prep.steps) { step in
                HStack(spacing: 10) {
                    switch step.status {
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.accent)
                        Text(step.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.accent)
                    case .active:
                        ProgressView().controlSize(.small)
                        ShimmerText(step.title)
                    case .pending:
                        Image(systemName: "circle")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textMuted.opacity(0.4))
                        Text(step.title)
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textMuted.opacity(0.5))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: prep.steps)
    }

    // MARK: - Follow-up panel

    private var followUpPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $followUpOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aktifkan Follow-up Question")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Maks 2 pertanyaan pendalaman via RunPod (TTS cloud)")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: followUpOn) { _, on in
                if !on { prep.runpodEndpoint = ""; prep.runpodKey = "" }
            }

            if followUpOn {
                VStack(spacing: 8) {
                    TextField("RunPod endpoint ID", text: $prep.runpodEndpoint)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bgSubtle))
                    SecureField("RunPod API key", text: $prep.runpodKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(Theme.textPrimary)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bgSubtle))
                    if prep.followUpEnabled {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundColor(.green)
                            Text("RunPod siap — follow-up akan aktif saat interview")
                                .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                            Spacer()
                        }
                    } else {
                        Text("Isi kedua field untuk mengaktifkan.")
                            .font(.system(size: 11)).foregroundColor(Theme.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bgSubtle.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.textMuted.opacity(0.12)))
    }

    // MARK: - Start Button

    private var startButton: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if prep.isWorking {
                        ProgressView().controlSize(.small).tint(Theme.accentInk)
                        Text(workingLabel).font(.system(size: 15, weight: .semibold))
                    } else {
                        Text(prep.isReady ? "Mulai Sekarang" : "Generate Interview Questions")
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 11).fill(buttonEnabled ? Theme.accent : Theme.bgSubtle))
                .foregroundColor(buttonEnabled ? Theme.accentInk : Color(hex: 0x5C5C63))
                .shadow(color: buttonEnabled ? Theme.accent.opacity(0.28) : .clear, radius: 10, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(!buttonEnabled)

            Text(prep.isReady ? "Semua pertanyaan siap · klik untuk masuk"
                              : "Butuh sekitar 10–15 menit · 4 pertanyaan teknis")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.textMuted)
                .frame(maxWidth: .infinity)
        }
    }

    private var workingLabel: String {
        switch prep.stage {
        case .loadingSTT:        return "Memuat model…"
        case .analyzing:         return "Menganalisis JD…"
        case .rendering(let m):  return m
        default:                 return "Menyiapkan…"
        }
    }

    private var buttonEnabled: Bool {
        if prep.isWorking { return false }
        if prep.isReady { return true }
        return canStart
    }

    private func primaryAction() {
        if prep.isReady {
            enterInterview = true
        } else {
            startPrep()
        }
    }

    private func startPrep() {
        let jd = jobText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jd.isEmpty else { return }
        Task { await prep.prepare(jobDescription: jd) }
    }

    // MARK: - Contoh JD

    static let sampleJD = """
    Backend Engineer (Golang) — Fintech

    Tanggung jawab:
    • Merancang & memelihara layanan pembayaran berlatensi rendah
    • Membangun API REST/gRPC dan integrasi pihak ketiga
    • Menjaga keandalan, observability, dan keamanan sistem

    Kualifikasi:
    • 3+ tahun pengalaman Go/Golang di lingkungan produksi
    • Menguasai PostgreSQL, Redis, message queue (Kafka/NATS)
    • Pengalaman Docker, Kubernetes, dan CI/CD
    • Memahami microservices & distributed systems
    """
}

#Preview {
    InterviewTimeStartView()
        .frame(width: 1180, height: 720)
        .preferredColorScheme(.dark)
}
