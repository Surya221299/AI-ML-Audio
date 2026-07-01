//
//  SimpleContentView.swift
//  InterviewTime
//

import SwiftUI

struct SimpleContentView: View {
    @StateObject private var tts = SimpleTTSService()
    @State private var text = "Halo, ummm, nama saya Nina. Jadi... ehh... terkait XGBoost, itu adalah model machine learning."
    @State private var emotion = "Young woman, very nervous, anxious, shaky voice, scared"

    // Live "video call" avatar images — mouth crossfades with TTS loudness.
    // Replace mouth_open.png with a real open-mouth photo of the person (same framing).
    private let avatarClosedURL = URL(fileURLWithPath:
        "/Users/nizikai/Documents/AIML/Audio/InterviewTime/avatar/mouth_closed.png")
    private let avatarOpenURL = URL(fileURLWithPath:
        "/Users/nizikai/Documents/AIML/Audio/InterviewTime/avatar/mouth_open.png")

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0d0f14"), Color(hex: "111827")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
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
                        .frame(height: 100)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                        .disabled(!isIdle)

                    Text("EMOTION")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .tracking(1.5)
                    TextField("e.g. Young woman, nervous", text: $emotion)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
                        .disabled(!isIdle)
                }

                // Status card
                statusCard

                // Live avatar
                videoSection

                // Actions — the avatar talks automatically while TTS audio plays
                if hasAudio {
                    HStack(spacing: 10) {
                        Button(action: { isPlaying ? tts.stop() : tts.play() }) {
                            actionLabel(
                                isPlaying ? "Stop" : "Play",
                                icon: isPlaying ? "stop.fill" : "play.fill",
                                color: isPlaying ? .red.opacity(0.8) : .indigo
                            )
                        }
                        .buttonStyle(.plain)

                        Button(action: { Task { await tts.generate(text: text, emotion: emotion) } }) {
                            actionLabel("Regenerate", icon: "arrow.triangle.2.circlepath",
                                        color: Color(hex: "374151"))
                        }
                        .buttonStyle(.plain)
                        .disabled(isPlaying)
                    }
                } else {
                    Button(action: { Task { await tts.generate(text: text, emotion: emotion) } }) {
                        actionLabel(buttonLabel, icon: buttonIcon, color: buttonColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(text.isEmpty && isIdle)
                }
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 460, minHeight: 620)
        .preferredColorScheme(.dark)
    }

    // MARK: - Video section

    @ViewBuilder
    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("INTERVIEWER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .tracking(1.5)
                Spacer()
                // Live "on a call" indicator
                HStack(spacing: 5) {
                    Circle()
                        .fill(isPlaying ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(isPlaying ? String(format: "SPEAKING %.2f", tts.mouthOpenness) : "LIVE")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            ZStack {
                if avatarClipsExist {
                    AmplitudeAvatarView(closedURL: avatarClosedURL,
                                        openURL: avatarOpenURL,
                                        openness: tts.mouthOpenness)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.03))
                        .overlay(
                            VStack(spacing: 6) {
                                Image(systemName: "person.crop.square.badge.video")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text("Add avatar/mouth_closed.png + avatar/mouth_open.png")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))
        }
    }

    private var avatarClipsExist: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: avatarClosedURL.path)
            && fm.fileExists(atPath: avatarOpenURL.path)
    }

    // MARK: - Status card

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

            Divider().background(Color.white.opacity(0.06))

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

    // MARK: - Computed

    private func actionLabel(_ text: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color, in: RoundedRectangle(cornerRadius: 8))
        .foregroundColor(.white)
    }

    private var isIdle: Bool {
        if case .idle = tts.state { return true }
        return false
    }

    private var hasAudio: Bool {
        switch tts.state {
        case .ready, .playing: return true
        default: return false
        }
    }

    private var isPlaying: Bool {
        if case .playing = tts.state { return true }
        return false
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
        case .generating, .generatingVideo: return "Generating Audio..."
        case .ready: return "Audio Ready"
        case .playing: return "Playing"
        case .error: return "Error"
        }
    }

    private var elapsedString: String {
        switch tts.state {
        case .generating: return String(format: "%.2fs", tts.elapsedSeconds)
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

    private var buttonLabel: String {
        switch tts.state {
        case .idle: return "Generate Speech"
        case .generating, .generatingVideo: return "Generating..."
        case .ready: return "Play Audio"
        case .playing: return "Stop"
        case .error: return "Try Again"
        }
    }

    private var buttonIcon: String {
        switch tts.state {
        case .idle, .error: return "play.fill"
        case .generating, .generatingVideo: return "hourglass"
        case .ready: return "speaker.wave.3"
        case .playing: return "stop.fill"
        }
    }

    private var buttonColor: Color {
        switch tts.state {
        case .generating: return Color(hex: "374151")
        case .playing: return .red.opacity(0.8)
        default: return .indigo
        }
    }

    private func mainAction() {
        switch tts.state {
        case .idle, .error:
            Task { await tts.generate(text: text, emotion: emotion) }
        case .ready:
            tts.play()
        case .playing:
            tts.stop()
        default:
            break
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: (r, g, b) = (1, 1, 1)
        }
        self.init(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }
}

#Preview {
    SimpleContentView()
}
