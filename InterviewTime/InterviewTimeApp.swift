//
//  InterviewTimeApp.swift
//  InterviewTime
//

import SwiftUI

@main
struct InterviewTimeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var selectedMethod: LipSyncMethod? = nil

    var body: some View {
        Group {
            if let method = selectedMethod {
                methodView(for: method)
            } else {
                LipSyncSelectorView(onSelect: { selectedMethod = $0 })
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selectedMethod)
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
