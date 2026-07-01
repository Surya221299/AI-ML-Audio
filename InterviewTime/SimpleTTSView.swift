//
//  SimpleTTSView.swift
//  InterviewTime
//
//  Simple TTS without lip-sync - just text input and audio playback
//

import SwiftUI

struct SimpleTTSView: View {
    @StateObject private var tts = SimpleTTSService()
    let onBack: () -> Void
    
    @State private var text = "Halo, ummm, nama saya Nina. Jadi... ehh... terkait XGBoost, itu adalah model machine learning."
    @State private var emotion = "Young woman, very nervous, anxious, shaky voice, scared"
    @State private var cfgValue = SimpleTTSGenerationOptions.fastBalanced.cfgValue
    @State private var inferenceTimesteps = Double(SimpleTTSGenerationOptions.fastBalanced.inferenceTimesteps)
    @State private var maxTokens = Double(SimpleTTSGenerationOptions.fastBalanced.maxTokens)
    @State private var warmupPatches = Double(SimpleTTSGenerationOptions.fastBalanced.warmupPatches)
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0d0f14"), Color(hex: "111827")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 24) {
                // Header with back button
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color.white.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.indigo)
                    Text("InterviewTime TTS")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("MLX · VoxCPM2-8bit")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                // Input
                VStack(alignment: .leading, spacing: 12) {
                    Text("TEXT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(1.5)
                    TextEditor(text: $text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 120)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                        .disabled(!canEdit)
                    
                    Text("EMOTION")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(1.5)
                    TextField("e.g. nervous, confident", text: $emotion)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                        .disabled(!canEdit)
                }

                parameterSection
                
                // Status
                statusCard
                
                Spacer()
                
                // Actions
                HStack(spacing: 10) {
                    if isGenerating {
                        // Generating in progress
                        Button(action: {}) {
                            actionLabel("Generating...", icon: "hourglass", color: Color(hex: "374151"))
                        }
                        .buttonStyle(.plain)
                        .disabled(true)
                    } else if hasAudio {
                        // Audio exists — show Regenerate + Replay/Stop
                        Button(action: generateAndPlay) {
                            actionLabel("Regenerate", icon: "arrow.clockwise", color: Color(hex: "374151"))
                        }
                        .buttonStyle(.plain)
                        .disabled(text.isEmpty)

                        if isPlaying {
                            Button(action: stopPlaying) {
                                actionLabel("Stop", icon: "stop.fill", color: .red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: replayAudio) {
                                actionLabel("Replay", icon: "play.fill", color: .indigo)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // No audio yet
                        Button(action: generateAndPlay) {
                            actionLabel("Generate & Play", icon: "play.fill", color: .indigo)
                        }
                        .buttonStyle(.plain)
                        .disabled(text.isEmpty)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 520)
        }
        .frame(minWidth: 600, minHeight: 720)
        .preferredColorScheme(.dark)
    }
    
    // MARK: - Status Card
    
    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
            }
            
            HStack(spacing: 0) {
                metricCell("ELAPSED", value: elapsedString)
                divider
                metricCell("DURATION", value: durationString)
                divider
                metricCell("RTF", value: rtfString)
            }
            
            if case .error(let msg) = tts.state {
                Text(msg)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
    }
    
    private func metricCell(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(1)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 1, height: 36)
    }

    // MARK: - Parameters

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GENERATION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .tracking(1.5)

            VStack(spacing: 10) {
                parameterSlider(
                    "CFG",
                    valueText: String(format: "%.1f", cfgValue),
                    value: $cfgValue,
                    range: 2.0...3.5,
                    step: 0.1
                )
                parameterSlider(
                    "STEPS",
                    valueText: "\(Int(inferenceTimesteps))",
                    value: $inferenceTimesteps,
                    range: 4...20,
                    step: 1
                )
                parameterSlider(
                    "MAX TOKENS",
                    valueText: "\(Int(maxTokens))",
                    value: $maxTokens,
                    range: 300...2000,
                    step: 100
                )
                parameterSlider(
                    "WARMUP",
                    valueText: "\(Int(warmupPatches))",
                    value: $warmupPatches,
                    range: 0...4,
                    step: 1
                )
            }
            .padding(12)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
            .disabled(!canEdit)
        }
    }

    private func parameterSlider(
        _ title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }

            Slider(value: value, in: range, step: step)
                .tint(.indigo)
        }
    }
    
    // MARK: - Helpers
    
    private func actionLabel(_ text: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color, in: RoundedRectangle(cornerRadius: 8))
        .foregroundColor(.white)
    }
    
    private var isGenerating: Bool {
        if case .generating = tts.state { return true }
        return false
    }

    private var canEdit: Bool {
        switch tts.state {
        case .generating, .generatingVideo, .playing: return false
        default: return true
        }
    }

    private var generationOptions: SimpleTTSGenerationOptions {
        SimpleTTSGenerationOptions(
            cfgValue: cfgValue,
            inferenceTimesteps: Int(inferenceTimesteps),
            maxTokens: Int(maxTokens),
            warmupPatches: Int(warmupPatches)
        )
    }
    
    private var isPlaying: Bool {
        if case .playing = tts.state { return true }
        return false
    }
    
    /// True once audio has been generated at least once (ready or playing)
    private var hasAudio: Bool {
        switch tts.state {
        case .ready, .playing: return true
        default: return false
        }
    }
    
    private var statusIcon: String {
        switch tts.state {
        case .idle: return "circle"
        case .generating, .generatingVideo: return "arrow.down.circle"
        case .ready: return "checkmark.circle"
        case .playing: return "speaker.wave.3"
        case .error: return "exclamationmark.triangle"
        }
    }
    
    private var statusColor: Color {
        switch tts.state {
        case .idle: return .gray
        case .generating, .generatingVideo: return .indigo
        case .ready: return .green
        case .playing: return .blue
        case .error: return .red
        }
    }
    
    private var statusTitle: String {
        switch tts.state {
        case .idle: return "Ready"
        case .generating, .generatingVideo: return "Generating..."
        case .ready: return "Ready to Play"
        case .playing: return "Playing"
        case .error: return "Error"
        }
    }
    
    private var elapsedString: String {
        switch tts.state {
        case .generating, .generatingVideo: return String(format: "%.2fs", tts.elapsedSeconds)
        case .ready(let elapsed, _), .playing(let elapsed, _):
            return String(format: "%.2fs", elapsed)
        default: return "—"
        }
    }
    
    private var durationString: String {
        switch tts.state {
        case .ready(_, let duration), .playing(_, let duration):
            return String(format: "%.2fs", duration)
        default: return "—"
        }
    }
    
    private var rtfString: String {
        switch tts.state {
        case .ready(let elapsed, let duration), .playing(let elapsed, let duration):
            guard duration > 0 else { return "—" }
            return String(format: "%.3f", elapsed / duration)
        default: return "—"
        }
    }
    
    // MARK: - Actions
    
    private func generateAndPlay() {
        Task {
            await tts.generate(
                text: text,
                emotion: emotion,
                withVideo: false,
                options: generationOptions
            )
            // Auto-play after generation completes
            if case .ready = tts.state {
                tts.play()
            }
        }
    }
    
    private func replayAudio() {
        tts.play()
    }
    
    private func stopPlaying() {
        tts.stop()
    }
}

#Preview {
    SimpleTTSView(onBack: {})
}
