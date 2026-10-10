//
//  InterviewerImageProvider.swift
//  InterviewTime
//

import AppKit

public final class InterviewerImageProvider: InterviewerImageProviding, @unchecked Sendable {
    public static let shared = InterviewerImageProvider()

    public init() {}

    public func loadInterviewerImage() -> NSImage? {
        if let img = NSImage(named: "Interviewer") ?? NSImage(named: "interviewer") {
            return img
        }

        let assetDirs = [
            AppConfig.projectRoot.appendingPathComponent("InterviewTime/Assets.xcassets/Interviewer.imageset"),
            AppConfig.projectRoot.appendingPathComponent("InterviewTime/Assets.xcassets/interviewer.imageset")
        ]

        let fm = FileManager.default
        for dir in assetDirs {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files {
                    let ext = f.pathExtension.lowercased()
                    if ["png", "jpg", "jpeg", "webp"].contains(ext) {
                        if let img = NSImage(contentsOf: f) {
                            return img
                        }
                    }
                }
            }
        }
        return nil
    }

    public func loadInterviewerImageData() throws -> Data {
        guard let img = loadInterviewerImage(),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "InterviewerImageProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "gagal memuat data gambar Interviewer"]
            )
        }
        return png
    }
}
