//
//  VideoStageView.swift
//  InterviewTime
//

import SwiftUI
import AVFoundation

struct VideoStageView: View {
    let player: AVQueuePlayer?
    let idleLoopPlayer: AVQueuePlayer?
    let previousIdleLoopPlayer: AVQueuePlayer?
    let idleLoopVisible: Bool
    let portrait: NSImage?
    let isTalking: Bool
    let isBusy: Bool

    var body: some View {
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
}
