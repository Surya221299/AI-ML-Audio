//
//  LipSyncRenderer.swift
//  InterviewTime
//

import Foundation

public struct LipSyncRenderRequest: Sendable {
    public let audioData: Data
    public let imageData: Data
    public let outputDirectory: URL
    public let fps: Int
    public let segFrames: Int

    public init(
        audioData: Data,
        imageData: Data,
        outputDirectory: URL,
        fps: Int = 10,
        segFrames: Int = 5
    ) {
        self.audioData = audioData
        self.imageData = imageData
        self.outputDirectory = outputDirectory
        self.fps = fps
        self.segFrames = segFrames
    }
}

public protocol LipSyncRenderer: Sendable {
    func render(request: LipSyncRenderRequest) async throws -> [URL]
}
