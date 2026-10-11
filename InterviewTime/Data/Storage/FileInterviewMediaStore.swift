//
//  FileInterviewMediaStore.swift
//  InterviewTime
//

import Foundation

public final class FileInterviewMediaStore: InterviewMediaStore, Sendable {
    public let outputsRoot: URL
    private let fileManager = FileManager.default

    public init(outputsRoot: URL = AppConfig.outputsRoot) {
        self.outputsRoot = outputsRoot
    }

    public var openingDirectory: URL {
        outputsRoot.appendingPathComponent("opening")
    }

    public var closingDirectory: URL {
        outputsRoot.appendingPathComponent("closing")
    }

    public func questionDirectory(index: Int) -> URL {
        outputsRoot.appendingPathComponent("q\(index)")
    }

    public func answerDirectory(category: String) -> URL {
        outputsRoot.appendingPathComponent("answer_\(category)")
    }

    public func createFollowUpDirectory() -> URL {
        outputsRoot.appendingPathComponent("followup_\(UUID().uuidString.prefix(8))")
    }

    public func createClosingAnswerDirectory() -> URL {
        outputsRoot.appendingPathComponent("closing_answer_\(UUID().uuidString.prefix(8))")
    }

    public func loadSavedSegments(from directory: URL) -> [URL]? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let mp4s = files.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return mp4s.isEmpty ? nil : mp4s
    }

    public func cleanQuestionDirectories(count: Int) {
        for i in 0..<count {
            try? fileManager.removeItem(at: questionDirectory(index: i))
        }
    }

    public func cleanDynamicAnswerDirectories(categories: [String], preservedCategories: [String]) {
        for cat in categories where !preservedCategories.contains(cat) {
            try? fileManager.removeItem(at: answerDirectory(category: cat))
        }
    }
}
