//
//  MuseTalkView.swift
//  InterviewTime
//
//  MuseTalk CoreML lip-sync view.
//  Backend: musetalk_server.py (ONNX + CoreML MLProgram, port 8810)
//

import SwiftUI
import AVKit
import AVFoundation

struct MuseTalkView: View {
    let onBack: () -> Void

    @StateObject private var tts = SimpleTTSService()
    @State private var text = "Selamat datang dan terimakasih sudah datang di interview, kita mulai, bisa jelaskan tentang background diri anda?"
    @State private var emotion = "male, mature, serious, curious"
    @State private var serverStatus: ServerStatus = .unknown
    @State private var serverProcess: Process?

    @State private var renderState: RenderState = .idle
    @State private var player: AVQueuePlayer?
    @State private var renderInfo: String?

    // Idle presence + streaming-overlap session state
    @State private var portrait: NSImage?
    @State private var isTalking = false
    @State private var startedPlayback = false
    @State private var generationDone = false
    @State private var sessionStart = Date()
    @State private var firstWord: Double?
    @State private var endObserver: NSObjectProtocol?

    // TTS generation params
    @State private var cfgValue        = SimpleTTSGenerationOptions.museTalkDefault.cfgValue
    @State private var inferenceSteps  = Double(SimpleTTSGenerationOptions.museTalkDefault.inferenceTimesteps)
    @State private var maxTokens       = Double(SimpleTTSGenerationOptions.museTalkDefault.maxTokens)
    @State private var warmupPatches   = Double(SimpleTTSGenerationOptions.museTalkDefault.warmupPatches)

    // Timing
    @State private var lastFirstWord: Double?
    @State private var lastTotalTime: Double?

    // Video call UI state
    @State private var showSettings = false
    @State private var micOn = true
    @State private var cameraOn = false
    @State private var pipOffset: CGSize = .zero
    @GestureState private var pipDragTranslation: CGSize = .zero

    // Idle loop
    @State private var idleLoopPlayer: AVQueuePlayer?
    @State private var idleLooper: AVPlayerLooper?
    @State private var currentIdleLoopURL: URL?
    @State private var idleRotationTask: Task<Void, Never>?

    private var projectRoot: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    private var cacheDir: URL { projectRoot.appendingPathComponent("outputs") }

    private func sourceImageData() throws -> Data {
        guard let img = NSImage(named: "Interviewer"),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw err("could not load Interviewer image")
        }
        return png
    }

    enum RenderState: Equatable {
        case idle, generatingAudio, rendering, ready, error(String)
    }

    enum ServerStatus {
        case unknown, checking, online, offline, starting
        var label: String {
            switch self {
            case .unknown:   return "Not checked"
            case .checking:  return "Checking…"
            case .online:    return "Server online"
            case .offline:   return "Server offline"
            case .starting:  return "Loading models… (~30s)"
            }
        }
        var color: Color {
            switch self {
            case .unknown, .checking: return .gray
            case .online:             return .green
            case .offline:            return .red
            case .starting:           return .orange
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            callTopBar

            ZStack {
                mainVideoArea

                // Self-view PiP — bottom-trailing, above control bar
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        selfViewPiP
                            .padding(.trailing, 16)
                            .padding(.bottom, 14)
                            .offset(x: pipOffset.width + pipDragTranslation.width,
                                    y: pipOffset.height + pipDragTranslation.height)
                            .gesture(
                                DragGesture()
                                    .updating($pipDragTranslation) { value, state, _ in
                                        state = value.translation
                                    }
                                    .onEnded { value in
                                        pipOffset.width += value.translation.width
                                        pipOffset.height += value.translation.height
                                    }
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            callControlBar
        }
        .background(Color.black)
        // Settings sidebar slides in as a trailing overlay
        .overlay(alignment: .trailing) {
            if showSettings {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.22)) { showSettings = false }
                        }

                    settingsSidebar
                        .frame(width: 310)
                        .frame(maxHeight: .infinity)
                        .background(Color(hex: "0e1117"))
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                        }
                        .transition(.move(edge: .trailing))
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.22), value: showSettings)
        .task {
            portrait = NSImage(named: "Interviewer").map { cappedImage($0, maxSide: 384) }
            startInitialIdleLoop()
            await checkServer()
        }
    }

    // MARK: - Top bar

    private var callTopBar: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Leave")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    // MARK: - Main video

    private var mainVideoArea: some View {
        ZStack {
            Color(hex: "050709")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Background: idle loop or portrait always visible (prevents black flicker between segments)
            if let idleLoopPlayer {
                FullScreenVideoPlayer(player: idleLoopPlayer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let portrait {
                Image(nsImage: portrait)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                previewPlaceholder
            }

            // Talking video overlaid on top when active — cross-fades in/out
            if isTalking, let player {
                FullScreenVideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            // Loading spinner — centered, shown while generating/rendering
            if isRendering {
                ProgressView()
                    .controlSize(.large)
            }

            // Interviewer name tag — bottom-left
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gemala")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("AI/ML Engineer Manager")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 16)
                    .padding(.bottom, 14)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.4), value: isTalking)
    }

    // MARK: - Self-view PiP

    private var selfViewPiP: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(hex: "141820"))
            CameraPreview(isActive: cameraOn)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(cameraOn ? 1 : 0)
            if !cameraOn {
                VStack(spacing: 5) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Camera off")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
        .frame(width: 112, height: 82)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }

    // MARK: - Bottom control bar

    private var callControlBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                callControlButton(
                    icon: micOn ? "mic.fill" : "mic.slash.fill",
                    label: micOn ? "Mute" : "Unmute",
                    tint: micOn ? .white : .red,
                    highlighted: !micOn
                ) { micOn.toggle() }
                callControlButton(
                    icon: cameraOn ? "video.fill" : "video.slash.fill",
                    label: "Camera",
                    tint: cameraOn ? .white : .red,
                    highlighted: !cameraOn
                ) { cameraOn.toggle() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Primary: Speak / Generate
            Button(action: { Task { await generateAndLipSync() } }) {
                HStack(spacing: 8) {
                    Image(systemName: isRendering ? "hourglass" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isRendering ? "Working…" : "Start")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 24).padding(.vertical, 11)
                .background(
                    (serverStatus == .online && !isRendering)
                        ? Color.indigo
                        : Color.white.opacity(0.08),
                    in: Capsule()
                )
                .foregroundColor(
                    (serverStatus == .online && !isRendering) ? .white : .secondary
                )
            }
            .buttonStyle(.plain)
            .disabled(serverStatus != .online || isRendering)

            HStack(spacing: 14) {
                callControlButton(
                    icon: "gearshape.fill",
                    label: "Settings",
                    tint: showSettings ? .white : .secondary,
                    highlighted: showSettings
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) { showSettings.toggle() }
                }

                // End call
                Button(action: onBack) {
                    VStack(spacing: 4) {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red, in: Circle())
                        Text("Leave")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.black.opacity(0.72))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func callControlButton(
        icon: String,
        label: String,
        tint: Color,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(tint)
                    .frame(width: 44, height: 44)
                    .background(
                        highlighted
                            ? Color.white.opacity(0.18)
                            : Color.white.opacity(0.08),
                        in: Circle()
                    )
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func sidebarSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, fmt: String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
            Slider(value: value, in: range, step: step).tint(.indigo)
        }
    }

    private func timingCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(1)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Settings sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.22)) { showSettings = false }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.secondary)
                            .padding(7)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Divider().background(Color.white.opacity(0.07))

                VStack(alignment: .leading, spacing: 20) {
                    // Server status
                    serverBanner

                    Divider().background(Color.white.opacity(0.07))

                    // Script
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SCRIPT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(1.5)
                        TextEditor(text: $text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(height: 110)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    }

                    // Emotion
                    VStack(alignment: .leading, spacing: 8) {
                        Text("EMOTION")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(1.5)
                        TextField("e.g. nervous, confident", text: $emotion)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    }

                    // Generation sliders
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GENERATION")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(1.5)
                        VStack(spacing: 10) {
                            sidebarSlider("CFG",       value: $cfgValue,       range: 2.0...3.5, step: 0.1, fmt: "%.1f")
                            sidebarSlider("STEPS",     value: $inferenceSteps, range: 4...20,    step: 1,   fmt: "%.0f")
                            sidebarSlider("MAX TOKENS",value: $maxTokens,      range: 300...2000, step: 100, fmt: "%.0f")
                            sidebarSlider("WARMUP",    value: $warmupPatches,  range: 0...4,     step: 1,   fmt: "%.0f")
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    }

                    // Timing metrics
                    if lastFirstWord != nil || lastTotalTime != nil {
                        HStack(spacing: 0) {
                            timingCell("FIRST WORD", lastFirstWord.map { String(format: "%.1fs", $0) } ?? "—")
                            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1, height: 30)
                            timingCell("TOTAL",      lastTotalTime.map { String(format: "%.1fs", $0) } ?? "—")
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    }

                    Divider().background(Color.white.opacity(0.07))

                    // Actions
                    VStack(spacing: 8) {
                        Button(action: { Task { await generateAndLipSync() } }) {
                            HStack {
                                Image(systemName: isRendering ? "hourglass" : "play.fill")
                                Text(isRendering ? "Working…" : "Generate & Lip-Sync")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                (serverStatus == .online && !isRendering)
                                    ? Color.indigo
                                    : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundColor(
                                (serverStatus == .online && !isRendering) ? .white : .secondary
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(serverStatus != .online || isRendering)

                        if let info = renderInfo {
                            Text(info)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green.opacity(0.85))
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private var previewPlaceholder: some View {
        VStack(spacing: 10) {
            switch renderState {
            case .generatingAudio, .rendering:
                ProgressView().controlSize(.large)
                Text(renderState == .generatingAudio ? "Generating speech…" : "Rendering lip-sync…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.red.opacity(0.7))
                Text(msg)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            default:
                Image(systemName: "cpu.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange.opacity(0.5))
                Text("MuseTalk CoreML")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                Text("Awaiting portrait…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Server banner (used inside sidebar)

    private var serverBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(serverStatus.color)
                .frame(width: 7, height: 7)
            Text(serverStatus.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(serverStatus.color)
            Spacer()
            if serverStatus == .offline {
                Button("Start") { Task { @MainActor in await launchAndWaitForServer() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange)
                Button("Log") {
                    NSWorkspace.shared.open(cacheDir.appendingPathComponent("musetalk_server.log"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }
            if serverStatus == .starting {
                Button("Log") {
                    NSWorkspace.shared.open(cacheDir.appendingPathComponent("musetalk_server.log"))
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            }
            if serverStatus != .starting {
                Button("Retry") { Task { @MainActor in await checkServer() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.indigo)
            }
        }
        .padding(12)
        .background(serverStatus.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(serverStatus.color.opacity(0.18)))
    }


    // MARK: - Generate + lip-sync (sentence-pipelined, idle presence)

    private func generateAndLipSync() async {
        beginSession(label: "TTS+render")

        // ponytail: full text in one TTS call so VoxCPM2 maintains a single speaker
        // identity throughout — per-sentence calls produce voice drift across generations.
        renderState = .rendering
        guard let wav = try? await fetchTTSWav(text: text, emotion: emotion,
                                               cfg: cfgValue, steps: Int(inferenceSteps),
                                               maxTok: Int(maxTokens), warmup: Int(warmupPatches)) else {
            renderState = .error("TTS failed")
            finishSession()
            return
        }
        do { try await streamLipSync(audio: wav) }
        catch { renderState = .error(error.localizedDescription); return }
        finishSession()
    }

    // MARK: Session lifecycle

    private func beginSession(label: String) {
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
        player?.pause()
        player = nil
        isTalking = false
        startedPlayback = false
        generationDone = false
        firstWord = nil
        renderInfo = nil
        sessionStart = Date()
        renderState = .generatingAudio
        sessionLabel = label

        // ponytail: idle loops are ~8s — if TTS/render runs long, cycle to a
        // different loop so the wait doesn't visibly repeat the same clip.
        idleRotationTask?.cancel()
        idleRotationTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                switchIdleLoop()
            }
        }
    }

    @State private var sessionLabel = ""

    private func finishSession() {
        idleRotationTask?.cancel()
        generationDone = true
        let total = Date().timeIntervalSince(sessionStart)
        lastFirstWord = firstWord
        lastTotalTime = total
        let fw = firstWord.map { String(format: "first word %.1fs · ", $0) } ?? ""
        renderInfo = "\(sessionLabel) · \(fw)" + String(format: "done %.1fs", total)
        renderState = startedPlayback ? .ready : .error("no video produced")
        if startedPlayback, player?.currentItem == nil { isTalking = false }
    }

    private func fetchTTSWav(text: String, emotion: String,
                              cfg: Double, steps: Int, maxTok: Int, warmup: Int) async throws -> Data {
        struct Payload: Encodable {
            let text, emotion, voice: String
            let cfg_value: Double
            let inference_timesteps, max_tokens, warmup_patches: Int
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8808/speak")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Payload(
            text: text, emotion: emotion, voice: "male_40s",
            cfg_value: cfg,
            inference_timesteps: steps, max_tokens: maxTok, warmup_patches: warmup
        ))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("TTS server error (is server_mlx.py running on 8808?)")
        }
        return data
    }

    private func streamLipSync(audio: Data) async throws {
        let image = try sourceImageData()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        func filePart(name: String, filename: String, mime: String, data: Data) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            append("Content-Type: \(mime)\r\n\r\n")
            body.append(data)
            append("\r\n")
        }
        filePart(name: "image", filename: "source.png", mime: "image/png", data: image)
        filePart(name: "audio", filename: "audio.wav", mime: "audio/wav", data: audio)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fps\"\r\n\r\n10\r\n")
        // ponytail: 5-frame segments (0.5s) halves starvation risk vs default 10
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"seg_frames\"\r\n\r\n5\r\n")
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: "http://127.0.0.1:8810/lipsync_stream")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = body

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("render failed (is the MuseTalk server running on 8810?)")
        }

        var iterator = bytes.makeAsyncIterator()
        func read(_ n: Int) async throws -> Data? {
            var out = Data(); out.reserveCapacity(n)
            for _ in 0..<n {
                guard let b = try await iterator.next() else { return out.isEmpty ? nil : out }
                out.append(b)
            }
            return out
        }

        let tmpDir = FileManager.default.temporaryDirectory
        while true {
            guard let header = try await read(4), header.count == 4 else { break }
            let len = header.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            if len == 0 { break }
            guard let mp4 = try await read(len), mp4.count == len else { break }

            let url = tmpDir.appendingPathComponent("seg_\(UUID().uuidString).mp4")
            try mp4.write(to: url)
            enqueue(AVPlayerItem(url: url))
        }
    }

    private func enqueue(_ item: AVPlayerItem) {
        if !startedPlayback {
            idleRotationTask?.cancel()
            let q = AVQueuePlayer(playerItem: item)
            q.actionAtItemEnd = .advance
            player = q
            startedPlayback = true
            isTalking = true
            firstWord = Date().timeIntervalSince(sessionStart)
            renderState = .ready
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
            ) { _ in
                if generationDone, (player?.items().count ?? 0) <= 1 {
                    isTalking = false
                    // Hand back to a (possibly different) idle loop
                    switchIdleLoop()
                }
            }
            q.play()
        } else {
            player?.insert(item, after: nil)
        }
    }

    // MARK: - Idle loop

    private func idleLoopURLs() -> [URL] {
        let dir = projectRoot.appendingPathComponent("outputs")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("idle_loop") && $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Swaps the idle background to a (weighted-random) loop file.
    private func switchIdleLoop() {
        let candidates = idleLoopURLs()
        guard !candidates.isEmpty else { return }
        // ponytail: idle_loop2 is favored 3:1 over the others — bump the count if it needs more/less airtime.
        let weighted = candidates.flatMap { url in
            Array(repeating: url, count: url.lastPathComponent.contains("loop2") ? 3 : 1)
        }
        guard let next = weighted.randomElement() else { return }
        guard next != currentIdleLoopURL || idleLoopPlayer == nil else { return }
        playIdleLoop(next)
    }

    /// Starts the very first idle loop, preferring idle_loop2 over the weighted-random pick.
    private func startInitialIdleLoop() {
        if let loop2 = idleLoopURLs().first(where: { $0.lastPathComponent.contains("loop2") }) {
            playIdleLoop(loop2)
        } else {
            switchIdleLoop()
        }
    }

    private func playIdleLoop(_ url: URL) {
        currentIdleLoopURL = url
        let player = AVQueuePlayer()
        player.isMuted = true  // silence — visual only
        let template = AVPlayerItem(url: url)
        idleLooper = AVPlayerLooper(player: player, templateItem: template)
        idleLoopPlayer = player
        player.play()
    }

    // MARK: - Helpers

    private func cappedImage(_ image: NSImage, maxSide: CGFloat = 768) -> NSImage {
        let sz = image.size
        let scale = min(maxSide / max(sz.width, sz.height), 1.0)
        guard scale < 1.0 else { return image }
        let newSize = NSSize(width: (sz.width * scale).rounded(.down),
                            height: (sz.height * scale).rounded(.down))
        let result = NSImage(size: newSize)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .medium
        image.draw(in: NSRect(origin: .zero, size: newSize), from: .zero,
                   operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }

    private func splitSentences(_ text: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?…".contains(ch) {
                let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { parts.append(s) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }

        var merged: [String] = []
        for s in parts {
            if let last = merged.last, last.split(separator: " ").count < 4 {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged.isEmpty ? [text] : merged
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "MuseTalk", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private var isRendering: Bool {
        renderState == .generatingAudio || renderState == .rendering
    }

    // MARK: - Server check

    private func checkServer() async {
        serverStatus = .checking
        guard let url = URL(string: "http://127.0.0.1:8810/health") else { return }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            serverStatus = (resp as? HTTPURLResponse)?.statusCode == 200 ? .online : .offline
        } catch {
            serverStatus = .offline
        }
        if serverStatus == .offline {
            await launchAndWaitForServer()
        }
    }

    private func launchAndWaitForServer() async {
        guard serverProcess == nil || serverProcess?.isRunning == false else { return }
        serverStatus = .starting

        let base = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptDir = base.appendingPathComponent("MuseTalk")
        let python = base.appendingPathComponent("envs/musetalk-env/bin/python")
            .resolvingSymlinksInPath()
        let script = scriptDir.appendingPathComponent("musetalk_server.py")

        let logURL = cacheDir.appendingPathComponent("musetalk_server.log")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let logPipe = Pipe()
        if let logFH = try? FileHandle(forWritingTo: logURL) {
            logPipe.fileHandleForReading.readabilityHandler = { fh in
                let data = fh.availableData
                guard !data.isEmpty else { return }
                logFH.write(data)
            }
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        process.currentDirectoryURL = scriptDir
        process.standardOutput = logPipe
        process.standardError  = logPipe
        serverProcess = process
        do {
            try process.run()
        } catch {
            let msg = "Failed to launch server: \(error)\n"
            try? msg.data(using: .utf8)?.write(to: logURL)
            serverStatus = .offline
            return
        }

        // ponytail: 120s — unet alone takes ~16s, full pipeline ~30-35s; 60 was too tight
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let url = URL(string: "http://127.0.0.1:8810/health") else { break }
            if let (_, resp) = try? await URLSession.shared.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                serverStatus = .online
                return
            }
            // bail early if the process already died
            if let p = serverProcess, !p.isRunning { break }
        }
        serverStatus = .offline
    }
}

#Preview {
    MuseTalkView(onBack: {})
}

// MARK: - Full Screen Video Player

// ponytail: AVPlayerLayer (not AVPlayerView) so backgroundColor=nil makes gaps
// transparent — the idle loop behind shows through instead of solid black.
struct FullScreenVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = nil  // transparent — no black during transitions
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

// MARK: - Live Camera Preview

struct CameraPreview: NSViewRepresentable {
    let isActive: Bool

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        if isActive { view.start() }
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        isActive ? nsView.start() : nsView.stop()
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: ()) {
        nsView.stop()
    }
}

final class CameraPreviewView: NSView {
    private let session = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private var configured = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.session = session
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            DispatchQueue.main.async { self?.beginRunning() }
        }
    }

    func stop() {
        guard session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
    }

    private func beginRunning() {
        if !configured {
            configured = true
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
            session.commitConfiguration()
        }
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
    }
}
