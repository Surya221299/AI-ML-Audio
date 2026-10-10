//
//  AvatarView.swift
//  InterviewTime
//
//  Live "video call" avatar. Crossfades closed/open-mouth images by TTS loudness,
//  and adds continuous head sway + breathing (more motion while speaking) so the
//  whole head feels alive — not just a moving mouth on a frozen face.
//

import SwiftUI

struct AmplitudeAvatarView: View {
    let closedURL: URL
    let openURL: URL
    var openness: Double                 // 0…1 from live audio loudness

    @State private var closedImg: NSImage?
    @State private var openImg: NSImage?

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // baseline "alive" + extra motion while speaking
            let speak = 0.35 + openness              // 0.35 idle … 1.35 loud
            let breath = 1.0 + sin(t * 0.9) * 0.005  // gentle breathing, no crop
            let swayX = sin(t * 1.1) * 3.0 * speak
            let swayY = cos(t * 0.8) * 2.0 * speak
            let tilt = sin(t * 0.9) * 0.9 * speak

            // NOTE: synthetic open-mouth crossfade removed — it distorted the face.
            // Real lip motion needs a real open-mouth photo or neural/3D lip-sync.
            ZStack {
                if let closedImg {
                    Image(nsImage: closedImg).resizable().scaledToFit()
                }
            }
            .scaleEffect(breath)
            .rotationEffect(.degrees(tilt))
            .offset(x: swayX, y: swayY)
        }
        .onAppear {
            closedImg = NSImage(contentsOf: closedURL)
            openImg = NSImage(contentsOf: openURL)
        }
    }
}
