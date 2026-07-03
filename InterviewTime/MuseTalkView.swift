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
import Security

// ponytail: plain SecItem wrapper, no framework — enough for one secret string
enum Keychain {
    static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// Lip-sync render server status. Always relevant regardless of TTS backend
// (CPU or RunPod) — rendering itself always runs locally.
struct ServerStatusBanner: View {
    let status: MuseTalkView.ServerStatus
    let onStart: () -> Void
    let onViewLog: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(status.color)
            Spacer()
            if status == .offline {
                Button("Start", action: onStart)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.orange)
                Button("Log", action: onViewLog)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if status == .starting {
                Button("Log", action: onViewLog)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if status != .starting {
                Button("Retry", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.indigo)
            }
        }
        .padding(12)
        .background(status.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(status.color.opacity(0.18)))
    }
}

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

    // TTS backend: local MLX server (CPU) vs a RunPod serverless VoxCPM2 endpoint
    @AppStorage("museTalkUseCloudTTS") private var useCloudTTS = false
    @AppStorage("museTalkRunpodEndpoint") private var runpodEndpoint = ""
    @State private var runpodKey = ""
    @State private var logLines: [String] = []

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
    @State private var idleLoopVisible = false
    @State private var previousIdleLoopPlayer: AVQueuePlayer?
    @State private var idleLooper: AVPlayerLooper?
    @State private var currentIdleLoopURL: URL?
    @State private var idleRotationTask: Task<Void, Never>?
    @State private var idleReadyObserver: NSKeyValueObservation?

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
            case .online:    return "Lip-sync server online"
            case .offline:   return "Lip-sync server offline"
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
            runpodKey = Keychain.get(account: "museTalkRunpodKey")
            portrait = NSImage(named: "Interviewer").map { cappedImage($0, maxSide: 384) }
            startInitialIdleLoop()
            await checkServer()
            if useCloudTTS { warmUpRunpod() }
        }
        .onChange(of: runpodKey) { _, newValue in
            Keychain.set(newValue, account: "museTalkRunpodKey")
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
            // Outgoing idle player stays underneath, fading out, while the incoming one fades in on top —
            // otherwise switching between idle_loop1/2 is an instant hard cut.
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
        .animation(.easeInOut(duration: 0.3), value: isTalking)
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
                    ServerStatusBanner(
                        status: serverStatus,
                        onStart: { Task { @MainActor in await launchAndWaitForServer() } },
                        onViewLog: { NSWorkspace.shared.open(cacheDir.appendingPathComponent("musetalk_server.log")) },
                        onRetry: { Task { @MainActor in await checkServer() } }
                    )

                    Divider().background(Color.white.opacity(0.07))

                    // TTS backend
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TTS BACKEND")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(1.5)
                        Picker("", selection: $useCloudTTS) {
                            Text("CPU (local)").tag(false)
                            Text("RunPod (cloud)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if useCloudTTS {
                            TextField("RunPod endpoint ID", text: $runpodEndpoint)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                            SecureField("RunPod API key", text: $runpodKey)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(10)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                        }
                    }

                    Divider().background(Color.white.opacity(0.07))

                    // Log
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LOG")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .tracking(1.5)
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    if logLines.isEmpty {
                                        Text("—").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                    }
                                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Color.clear.frame(height: 1).id("bottom")
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 120)
                            .onChange(of: logLines.count) { _, _ in
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.09)))
                    }

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
        if startedPlayback, player?.currentItem == nil { returnToIdle() }
    }

    /// Leaves the talking state and always hands the screen back to an idle
    /// loop — the two call sites (playback drains before generation finishes,
    /// or generation finishes before playback drains) must never skip this.
    private func returnToIdle() {
        isTalking = false
        // the idle player keeps running in the background while hidden behind the
        // talking video, so if switchIdleLoop() below keeps the same clip (the
        // common case) it would reappear mid-loop instead of at frame one
        idleLoopPlayer?.seek(to: .zero)
        switchIdleLoop()
    }

    private struct TTSPayload: Encodable {
        let text, emotion, voice: String
        let cfg_value: Double
        let inference_timesteps, max_tokens, warmup_patches: Int
    }

    private func fetchTTSWav(text: String, emotion: String,
                              cfg: Double, steps: Int, maxTok: Int, warmup: Int) async throws -> Data {
        let payload = TTSPayload(
            text: text, emotion: emotion, voice: "male_40s", cfg_value: cfg,
            inference_timesteps: steps, max_tokens: maxTok, warmup_patches: warmup
        )
        if useCloudTTS {
            return try await fetchRunpodWav(payload: payload)
        }

        // Local MLX server on 8808 — returns raw WAV bytes from /speak.
        guard let url = URL(string: "http://127.0.0.1:8808/speak") else {
            throw err("Invalid TTS backend URL")
        }
        log("TTS → CPU \(url.absoluteString)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(payload)
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let elapsed = Date().timeIntervalSince(t0)
        let status = (resp as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            log("TTS ✗ status \(status.map(String.init) ?? "?") after \(String(format: "%.1f", elapsed))s")
            throw err("TTS server error (is server_mlx.py running on 8808?)")
        }
        log("TTS ✓ \(data.count) bytes in \(String(format: "%.1f", elapsed))s")
        return data
    }

    /// Fire-and-forget: enqueue a tiny job so RunPod boots a worker and loads the
    /// 2B model into VRAM before the first real line. We don't await the result —
    /// just triggering /run is enough to spin up the worker.
    private func warmUpRunpod() {
        let ep = runpodEndpoint.trimmingCharacters(in: .whitespaces)
        let key = runpodKey.trimmingCharacters(in: .whitespaces)
        guard !ep.isEmpty, !key.isEmpty else { return }
        Task {
            struct Body: Encodable { let input: [String: String] }
            var req = URLRequest(url: URL(string: "https://api.runpod.ai/v2/\(ep)/run")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(Body(input: ["text": "warmup"]))
            log("TTS → RunPod warmup")
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// RunPod serverless: POST /run to enqueue, poll /status/{id} until COMPLETED,
    /// then base64-decode the handler's audio_b64 back into WAV bytes. Polling (not
    /// /runsync) so a long cold start doesn't hit the ~90s sync cap.
    private func fetchRunpodWav(payload: TTSPayload) async throws -> Data {
        struct Body: Encodable { let input: TTSPayload }
        struct RunResp: Decodable { let id: String }
        struct StatusResp: Decodable {
            let status: String
            let output: Output?
            struct Output: Decodable { let audio_b64: String?; let error: String? }
        }
        let ep = runpodEndpoint.trimmingCharacters(in: .whitespaces)
        let key = runpodKey.trimmingCharacters(in: .whitespaces)
        guard !ep.isEmpty, !key.isEmpty else {
            log("TTS ✗ RunPod endpoint/key not set")
            throw err("Set the RunPod endpoint ID and API key in Settings first")
        }
        let base = "https://api.runpod.ai/v2/\(ep)"

        var req = URLRequest(url: URL(string: "\(base)/run")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(input: payload))
        log("TTS → RunPod \(base)/run")
        let t0 = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("RunPod /run failed (status \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        let job = try JSONDecoder().decode(RunResp.self, from: data)

        let statusURL = URL(string: "\(base)/status/\(job.id)")!
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            var sreq = URLRequest(url: statusURL)
            sreq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (sdata, _) = try await URLSession.shared.data(for: sreq)
            let s = try JSONDecoder().decode(StatusResp.self, from: sdata)
            switch s.status {
            case "COMPLETED":
                guard let b64 = s.output?.audio_b64, let wav = Data(base64Encoded: b64) else {
                    throw err(s.output?.error ?? "RunPod returned no audio")
                }
                log("TTS ✓ RunPod \(wav.count) bytes in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                return wav
            case "FAILED", "CANCELLED", "TIMED_OUT":
                throw err("RunPod job \(s.status)")
            default:  // IN_QUEUE / IN_PROGRESS
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw err("RunPod TTS timed out")
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

        log("Lip-sync → local http://127.0.0.1:8810/lipsync_stream")
        let t0 = Date()
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            log("Lip-sync ✗ request failed")
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
        var segCount = 0
        while true {
            guard let header = try await read(4), header.count == 4 else { break }
            let len = header.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            if len == 0 { break }
            guard let mp4 = try await read(len), mp4.count == len else { break }

            let url = tmpDir.appendingPathComponent("seg_\(UUID().uuidString).mp4")
            try mp4.write(to: url)
            enqueue(AVPlayerItem(url: url))
            segCount += 1
        }
        log("Lip-sync ✓ \(segCount) segments in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
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
            ) { note in
                // object: nil means this also fires for the idle-loop background
                // repeating underneath — only react to our own talking segments
                // (named seg_*.mp4) or an unrelated idle-loop repeat can trigger
                // returnToIdle() mid-sentence instead of at the real end.
                guard let endedItem = note.object as? AVPlayerItem,
                      let url = (endedItem.asset as? AVURLAsset)?.url,
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
        // ponytail: idle_loop2 is favored 6:1 over the others — bump the count if it needs more/less airtime.
        let weighted = candidates.flatMap { url in
            Array(repeating: url, count: url.lastPathComponent.contains("loop2") ? 6 : 1)
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

    /// Builds the next idle player off-screen and only swaps it in once it has
    /// a decoded frame ready — otherwise the layer briefly shows the dark
    /// background behind it while the new video loads.
    private func playIdleLoop(_ url: URL) {
        let player = AVQueuePlayer()
        player.isMuted = true  // silence — visual only
        let template = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: player, templateItem: template)

        // ponytail: observe the player's actual enqueued item, not the template —
        // the looper plays copies of the template, so template.status can stay
        // .unknown forever and the swap-in never fires (static portrait instead).
        idleReadyObserver?.invalidate()
        idleReadyObserver = player.observe(\.currentItem?.status, options: [.new, .initial]) { p, _ in
            guard p.currentItem?.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                previousIdleLoopPlayer = idleLoopPlayer
                currentIdleLoopURL = url
                idleLooper = looper
                idleLoopVisible = false
                idleLoopPlayer = player
                player.play()
                // flip on the next tick so the opacity animation actually fades in
                // rather than snapping straight to 1 alongside the player swap above
                DispatchQueue.main.async { idleLoopVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    previousIdleLoopPlayer = nil
                }
            }
        }
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

    private func log(_ msg: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logLines.append("\(ts)  \(msg)")
        if logLines.count > 100 { logLines.removeFirst(logLines.count - 100) }
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
