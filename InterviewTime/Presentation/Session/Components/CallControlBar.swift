//
//  CallControlBar.swift
//  InterviewTime
//

import SwiftUI

struct CallControlBar: View {
    @Binding var micOn: Bool
    @Binding var cameraOn: Bool
    let isRecording: Bool
    let controlDisabled: Bool
    let onRecordToggled: () -> Void
    let onLeave: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                callControlButton(
                    icon: micOn ? "mic.fill" : "mic.slash.fill",
                    label: micOn ? "Mute" : "Unmute",
                    tint: micOn ? .white : .red,
                    highlighted: !micOn
                ) {
                    micOn.toggle()
                }

                callControlButton(
                    icon: cameraOn ? "video.fill" : "video.slash.fill",
                    label: "Camera",
                    tint: cameraOn ? .white : .red,
                    highlighted: !cameraOn
                ) {
                    cameraOn.toggle()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Tombol utama: Rekam & Jawab
            Button(action: onRecordToggled) {
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
                Button(action: onLeave) {
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
                    .font(.system(size: 15)).foregroundColor(tint)
                    .frame(width: 44, height: 44)
                    .background(highlighted ? Color.white.opacity(0.18) : Color.white.opacity(0.08), in: Circle())
                Text(label).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
