//
//  Theme.swift
//  InterviewTime
//

import SwiftUI

enum Theme {
    static let accent      = Color(hex: 0xD97757)
    static let accentInk   = Color(hex: 0x1A120E)   // teks di atas accent

    static let bgWindow    = Color(hex: 0x16161A)
    static let bgSidebar   = Color(hex: 0x191919)
    static let bgTitlebar  = Color(hex: 0x1B1B1F)
    static let bgField     = Color(hex: 0x1A1A1D)
    static let bgSubtle    = Color(hex: 0x26262B)
    static let bgTabActive = Color(hex: 0x2E2E34)
    static let bgTabTrack  = Color(hex: 0x202024)

    static let textPrimary = Color(hex: 0xF2F2F4)
    static let textSecond  = Color(hex: 0x97979F)
    static let textMuted   = Color(hex: 0x6C6C74)
    static let textFaint   = Color(hex: 0x5F5F66)

    static let hairline    = Color.white.opacity(0.09)
    static let hairlineSoft = Color.white.opacity(0.06)
}
