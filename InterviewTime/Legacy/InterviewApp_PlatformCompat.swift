//
//  PlatformCompat.swift
//  Interviewer
//
//  Beberapa warna sistem (secondarySystemBackground, separator) hanya ada di
//  UIKit. File ini menyediakan versi `Color` yang aman dipakai di iOS & macOS,
//  supaya ContentView.swift tetap satu kode untuk kedua platform.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

extension Color {
    static var secondarySystemBackgroundCompat: Color { Color(UIColor.secondarySystemBackground) }
    static var separatorCompat: Color { Color(UIColor.separator) }
}
#else
import AppKit

extension Color {
    static var secondarySystemBackgroundCompat: Color { Color(NSColor.controlBackgroundColor) }
    static var separatorCompat: Color { Color(NSColor.separatorColor) }
}
#endif
