//
//  InterviewMediaStore.swift
//  InterviewTime
//

import Foundation

public protocol InterviewMediaStore: Sendable {
    var outputsRoot: URL { get }
    var openingDirectory: URL { get }
    var closingDirectory: URL { get }
    func questionDirectory(index: Int) -> URL
    func answerDirectory(category: String) -> URL
    func createFollowUpDirectory() -> URL
    func createClosingAnswerDirectory() -> URL
    func loadSavedSegments(from directory: URL) -> [URL]?
    func cleanQuestionDirectories(count: Int)
    func cleanDynamicAnswerDirectories(categories: [String], preservedCategories: [String])
}
