//
//  LipSyncSelectorView.swift
//  InterviewTime
//

import SwiftUI

enum LipSyncMethod: String, CaseIterable {
    case simpleTTS      = "simpletts"
    case museTalkCoreML = "musetalk"
}

struct LipSyncSelectorView: View {
    let onSelect: (LipSyncMethod) -> Void

    struct Option {
        let method: LipSyncMethod
        let icon: String
        let title: String
        let subtitle: String
        let tags: [String]
        let status: Status

        enum Status {
            case available, inProgress, comingSoon
            var label: String {
                switch self {
                case .available:  return "Available"
                case .inProgress: return "In Progress"
                case .comingSoon: return "Coming Soon"
                }
            }
            var color: Color {
                switch self {
                case .available:  return .green
                case .inProgress: return .orange
                case .comingSoon: return .gray
                }
            }
        }
    }

    private let options: [Option] = [
        .init(method: .simpleTTS,
              icon: "speaker.wave.3.fill",
              title: "Simple TTS",
              subtitle: "Audio-only generation without lip-sync or avatar",
              tags: ["Audio-only", "Fast", "Simple"],
              status: .available),
        .init(method: .museTalkCoreML,
              icon: "cpu.fill",
              title: "MuseTalk CoreML",
              subtitle: "Neural mouth inpainting at 20-30 FPS via Apple Neural Engine",
              tags: ["Photoreal", "On-device", "Fast"],
              status: .inProgress)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0d0f14"), Color(hex: "111827")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "face.smiling.inverse")
                        .font(.system(size: 52))
                        .foregroundStyle(.indigo)
                    Text("InterviewTime")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("Choose a lip-sync method")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)

                // Cards
                VStack(spacing: 12) {
                    ForEach(options, id: \.method.rawValue) { option in
                        MethodCard(option: option) {
                            onSelect(option.method)
                        }
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 500, minHeight: 580)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Card

private struct MethodCard: View {
    let option: LipSyncSelectorView.Option
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: {
            guard option.status != .comingSoon else { return }
            onTap()
        }) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconBg)
                        .frame(width: 48, height: 48)
                    Image(systemName: option.icon)
                        .font(.system(size: 22))
                        .foregroundStyle(iconFg)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text(option.subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Tags
                    HStack(spacing: 6) {
                        ForEach(option.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.white.opacity(0.06), in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer()

                // Chevron
                if option.status != .comingSoon {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isHovered && option.status != .comingSoon ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: 1)
            )
            .opacity(option.status == .comingSoon ? 0.55 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(option.status == .comingSoon)
    }

    private var iconBg: Color {
        switch option.status {
        case .available:  return .indigo.opacity(0.18)
        case .inProgress: return .orange.opacity(0.15)
        case .comingSoon: return Color.white.opacity(0.05)
        }
    }

    private var iconFg: Color {
        switch option.status {
        case .available:  return .indigo
        case .inProgress: return .orange
        case .comingSoon: return .secondary
        }
    }

    private var borderColor: Color {
        if isHovered && option.status != .comingSoon {
            return option.status == .inProgress ? .orange.opacity(0.5) : .indigo.opacity(0.5)
        }
        return Color.white.opacity(0.08)
    }
}

// MARK: - Status Badge

private struct StatusBadge: View {
    let status: LipSyncSelectorView.Option.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(status.color)
                .frame(width: 5, height: 5)
            Text(status.label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(status.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.1), in: Capsule())
    }
}

#Preview {
    LipSyncSelectorView(onSelect: { _ in })
}
