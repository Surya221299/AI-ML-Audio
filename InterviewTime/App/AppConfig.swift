//
//  AppConfig.swift
//  InterviewTime
//

import Foundation

public enum AppConfig {
    public static let llmModel = "llama3.1:8b"
    public static let ollamaURL = URL(string: "http://127.0.0.1:11434")!
    public static let ttsURL = "http://127.0.0.1:8808/speak"
    public static let lipsyncURL = "http://127.0.0.1:8810/lipsync_stream"
    
    public static let numQuestions = 4
    public static let maxFollowUps = 2
    public static let maxClosingQA = 3
    
    public static let defaultVoice = "male_40s"
    public static let defaultEmotion = "calm, professional"

    /// Menemukan root direktori proyek secara andal dengan mencari folder `InterviewTime.xcodeproj`
    public static var projectRoot: URL {
        var current = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            current.deleteLastPathComponent()
            let xcodeProj = current.appendingPathComponent("InterviewTime.xcodeproj")
            if FileManager.default.fileExists(atPath: xcodeProj.path) {
                return current
            }
        }
        // Fallback default
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static var outputsRoot: URL {
        projectRoot.appendingPathComponent("outputs")
    }
}
