//
//  FileInterviewMediaStoreTests.swift
//  InterviewTimeTests
//

import Foundation
import Testing
@testable import InterviewTime

@Suite struct FileInterviewMediaStoreTests {

    @Test func mediaStorePathStructure() {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileInterviewMediaStore(outputsRoot: tempRoot)

        #expect(store.outputsRoot == tempRoot)
        #expect(store.openingDirectory == tempRoot.appendingPathComponent("opening"))
        #expect(store.closingDirectory == tempRoot.appendingPathComponent("closing"))
        #expect(store.questionDirectory(index: 2) == tempRoot.appendingPathComponent("q2"))
        #expect(store.answerDirectory(category: "benefit") == tempRoot.appendingPathComponent("answer_benefit"))

        let followUpDir = store.createFollowUpDirectory()
        #expect(followUpDir.lastPathComponent.hasPrefix("followup_"))

        let closingAnswerDir = store.createClosingAnswerDirectory()
        #expect(closingAnswerDir.lastPathComponent.hasPrefix("closing_answer_"))
    }

    @Test func loadSavedSegmentsFiltersAndSorts() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create mock mp4 files and a non-mp4 file
        let file1 = tempDir.appendingPathComponent("seg_0001.mp4")
        let file0 = tempDir.appendingPathComponent("seg_0000.mp4")
        let fileNonMp4 = tempDir.appendingPathComponent("audio.wav")

        try "mp4_1".write(to: file1, atomically: true, encoding: .utf8)
        try "mp4_0".write(to: file0, atomically: true, encoding: .utf8)
        try "wav".write(to: fileNonMp4, atomically: true, encoding: .utf8)

        let store = FileInterviewMediaStore(outputsRoot: tempDir.deletingLastPathComponent())
        let loaded = store.loadSavedSegments(from: tempDir)

        #expect(loaded != nil)
        #expect(loaded?.count == 2)
        #expect(loaded?[0].lastPathComponent == "seg_0000.mp4")
        #expect(loaded?[1].lastPathComponent == "seg_0001.mp4")
    }

    @Test func cleanQuestionAndDynamicAnswerDirectories() throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileInterviewMediaStore(outputsRoot: tempRoot)

        let q0 = store.questionDirectory(index: 0)
        let q1 = store.questionDirectory(index: 1)
        let ansPosisi = store.answerDirectory(category: "posisi")
        let ansBenefit = store.answerDirectory(category: "benefit")

        try FileManager.default.createDirectory(at: q0, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: q1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ansPosisi, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ansBenefit, withIntermediateDirectories: true)

        #expect(FileManager.default.fileExists(atPath: q0.path))
        #expect(FileManager.default.fileExists(atPath: q1.path))
        #expect(FileManager.default.fileExists(atPath: ansPosisi.path))
        #expect(FileManager.default.fileExists(atPath: ansBenefit.path))

        store.cleanQuestionDirectories(count: 2)
        #expect(!FileManager.default.fileExists(atPath: q0.path))
        #expect(!FileManager.default.fileExists(atPath: q1.path))

        store.cleanDynamicAnswerDirectories(
            categories: ["posisi", "perusahaan", "benefit", "proses"],
            preservedCategories: ["benefit", "proses"]
        )

        // "posisi" should be deleted, but "benefit" should be preserved!
        #expect(!FileManager.default.fileExists(atPath: ansPosisi.path))
        #expect(FileManager.default.fileExists(atPath: ansBenefit.path))

        try? FileManager.default.removeItem(at: tempRoot)
    }
}
