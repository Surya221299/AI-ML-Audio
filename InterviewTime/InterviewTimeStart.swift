//
//  InterviewTimeStart.swift
//  InterviewTime
//
//  Layar awal aplikasi macOS: tempel / unggah deskripsi pekerjaan
//  untuk memulai wawancara dengan AI.
//
//  SwiftUI · macOS 13+ · drop file ini ke project Xcode kamu.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Palet & Konstanta Desain

private enum Theme {
    static let accent      = Color(hex: 0xD97757)
    static let accentInk   = Color(hex: 0x1A120E)   // teks di atas accent

    static let bgWindow    = Color(hex: 0x16161A)
    static let bgSidebar   = Color(hex: 0x191919)
    static let bgTitlebar  = Color(hex: 0x1B1B1F)
    static let bgField     = Color(hex: 0x1A1A1D)
    static let bgSubtle    = Color(hex: 0x26262B)
    static let bgTabActive = Color(hex: 0x2E2E34)
    static let bgTabTrack  = Color(hex: 0x202024)

    static let textPrimary = Color(hex: 0xF2F2F4)
    static let textSecond  = Color(hex: 0x97979F)
    static let textMuted   = Color(hex: 0x6C6C74)
    static let textFaint   = Color(hex: 0x5F5F66)

    static let hairline    = Color.white.opacity(0.09)
    static let hairlineSoft = Color.white.opacity(0.06)
}

private enum InputMode { case paste, upload }

// MARK: - Root View

struct InterviewTimeStartView: View {
    @State private var mode: InputMode = .paste
    @State private var jobText: String = ""
    @State private var fileName: String? = nil
    @State private var isTargetedForDrop = false
    @State private var isStarting = false
    @State private var showFileImporter = false
    @StateObject private var prep = InterviewPrep()
    @State private var followUpOn = false
    @State private var enterInterview = false      // true → tampilkan ConversationView

    private var canStart: Bool {
        switch mode {
        case .paste:  return !jobText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .upload: return fileName != nil
        }
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
        .frame(minWidth: 1000, minHeight: 680)
        .background(Theme.bgWindow)
        .overlay(alignment: .center) { if isStarting { startingOverlay } }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "docx") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                fileName = url.lastPathComponent
            }
        }
    }

    // MARK: Sidebar (branding)

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
                Text("InterviewTime")
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
                    .tracking(1)
                    .foregroundColor(Theme.textFaint)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline, lineWidth: 1))
                Text("Semua proses berjalan lokal di perangkat.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 44)
        .frame(width: 384)
        .background(Theme.bgSidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairlineSoft).frame(width: 1)
        }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepRow(1, "Paste Job Description", active: !prep.isWorking && !prep.isReady, isLast: false)
            stepRow(2, "AI menyusun & menyiapkan pertanyaan", active: prep.isWorking, isLast: false)
            stepRow(3, "Kamu menjawab lewat video call", active: prep.isReady, isLast: false)
            stepRow(4, "Dapatkan skor & umpan balik", active: false, isLast: true)
        }
    }

    private func stepRow(_ n: Int, _ label: String, active: Bool, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(active ? Theme.accent : Theme.bgSubtle)
                        .overlay(Circle().stroke(active ? .clear : Theme.hairline, lineWidth: 1))
                    Text("\(n)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(active ? Theme.accentInk : Color(hex: 0x8A8A92))
                }
                .frame(width: 26, height: 26)
                if !isLast {
                    Rectangle().fill(Theme.hairline).frame(width: 1.5)
                }
            }
            Text(label)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(active ? Color(hex: 0xE6E6EA) : Color(hex: 0x9A9AA2))
                .padding(.bottom, isLast ? 0 : 20)
                .padding(.top, 3)
        }
    }

    // MARK: Input pane

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

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

//            segmentedControl
//                .padding(.top, 22)

            Group {
                switch mode {
                case .paste:  pasteArea
                case .upload: uploadArea
                }
            }
            .padding(.top, 16)

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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

//    private var segmentedControl: some View {
//        HStack(spacing: 3) {
//            tabButton("Tempel teks", isActive: mode == .paste) { mode = .paste }
//            tabButton("Unggah file", isActive: mode == .upload) { mode = .upload }
//        }
//        .padding(3)
//        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgTabTrack))
//        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline, lineWidth: 1))
//    }

    private func tabButton(_ title: String, isActive: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isActive ? Color(hex: 0xF0F0F2) : Color(hex: 0x88888F))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? Theme.bgTabActive : .clear)
                        .shadow(color: .black.opacity(isActive ? 0.35 : 0), radius: 2, y: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Paste

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

    // MARK: Upload

    private var uploadArea: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isTargetedForDrop ? Theme.accent.opacity(0.08) : Theme.bgField)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isTargetedForDrop ? Theme.accent : Color.white.opacity(0.14),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .frame(height: 236)
            .overlay {
                if let name = fileName { fileChip(name) } else { dropPrompt }
            }
            .contentShape(Rectangle())
            .onTapGesture { showFileImporter = true }
            .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                providers.first?.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { fileName = url.lastPathComponent } }
                }
                return true
            }
    }

    private var dropPrompt: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 11)
                .fill(Theme.bgSubtle)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).foregroundColor(Color(hex: 0xB5B5BD)))
                .padding(.bottom, 8)
            Text("Seret & lepas file di sini")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(Color(hex: 0xE6E6EA))
            Text("atau klik untuk memilih · PDF, DOCX, TXT")
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: 0x7C7C84))
        }
    }

    private func fileChip(_ name: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent)
                .frame(width: 34, height: 34)
                .overlay(Text("DOC").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(Theme.accentInk))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundColor(Color(hex: 0xEDEDF0))
                    .lineLimit(1)
                Text("Siap dianalisis")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: 0x7C7C84))
            }
            Spacer()
            Button { fileName = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: 0x9A9AA2))
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bgSubtle))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        .padding(20)
    }

    // MARK: CTA

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

        private var startButton: some View {
        VStack(spacing: 10) {
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if prep.isWorking {
                        ProgressView().controlSize(.small).tint(Theme.accentInk)
                        Text(workingLabel).font(.system(size: 15, weight: .semibold))
                    } else {
                        Text(prep.isReady ? "Mulai Sekarang" : "Mulai wawancara")
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

    private var startingOverlay: some View {
        ZStack {
            Theme.bgWindow.opacity(0.86).ignoresSafeArea()
            VStack(spacing: 18) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Menyiapkan ruang wawancara…")
                    .font(.system(size: 14.5))
                    .foregroundColor(Color(hex: 0xCFCFD4))
            }
        }
    }



    // MARK: Contoh JD

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

// MARK: - Utilitas Warna

extension Color {
    /// Warna dari hex 0xRRGGBB.
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF)         / 255,
            opacity: alpha
        )
    }
}

// MARK: - Preview



// MARK: - Shimmer Text (teks abu-abu dengan kilau bergerak, ala loading scraping)

struct ShimmerText: View {
    let text: String
    @State private var phase: CGFloat = -1

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(hex: 0x8A8A90))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.75), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: phase * geo.size.width * 1.5)
                    .blendMode(.screen)
                }
                .mask(
                    Text(text).font(.system(size: 14, weight: .medium))
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

#Preview {
    InterviewTimeStartView()
        .frame(width: 1180, height: 720)
        .preferredColorScheme(.dark)
}
