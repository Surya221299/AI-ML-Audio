//
//  InterviewTimeApp.swift
//  InterviewTime
//

import SwiftUI

@main
struct InterviewTimeApp: App {
    var body: some Scene {
        WindowGroup {
            InterviewTimeStartView()
        }
    }
}

struct RootView: View {
    @State private var selectedMethod: LipSyncMethod? = nil

    // All screens are laid out at this fixed canvas size, then scaled to fit
    // the window — resizing changes scale, not layout, so nothing ever overlaps.
    private let designSize = CGSize(width: 1280, height: 800)

    var body: some View {
        GeometryReader { geo in
            screens
                .frame(width: designSize.width, height: designSize.height)
                .scaleEffect(scale(for: geo.size))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        // minWidth matches the design aspect ratio so the window can't be
        // shrunk into a portrait shape.
        .frame(minWidth: 300 * designSize.width / designSize.height, minHeight: 300)
    }

    private var screens: some View {
        Group {
            if let method = selectedMethod {
                methodView(for: method)
            } else {
                LipSyncSelectorView(onSelect: { selectedMethod = $0 })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedMethod)
    }

    private func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(size.width / designSize.width, size.height / designSize.height)
    }

    @ViewBuilder
    private func methodView(for method: LipSyncMethod) -> some View {
        switch method {
        case .simpleTTS:
            SimpleTTSView(onBack: { selectedMethod = nil })
        case .museTalkCoreML:
            MuseTalkView(onBack: { selectedMethod = nil })
        }
    }
}
