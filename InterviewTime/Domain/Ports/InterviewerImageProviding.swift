//
//  InterviewerImageProviding.swift
//  InterviewTime
//

import AppKit

public protocol InterviewerImageProviding: Sendable {
    func loadInterviewerImage() -> NSImage?
    func loadInterviewerImageData() throws -> Data
}
