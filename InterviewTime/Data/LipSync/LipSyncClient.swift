//
//  LipSyncClient.swift
//  InterviewTime
//

import Foundation

public final class LipSyncClient: LipSyncRenderer, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8810")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func render(request: LipSyncRenderRequest) async throws -> [URL] {
        let dir = request.outputDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let existing = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in existing {
                try? FileManager.default.removeItem(at: f)
            }
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func append(_ s: String) {
            guard let d = s.data(using: .utf8) else { return }
            body.append(d)
        }

        func part(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            append("Content-Type: \(mime)\r\n\r\n")
            body.append(data)
            append("\r\n")
        }

        part("image", "source.png", "image/png", request.imageData)
        part("audio", "audio.wav", "audio/wav", request.audioData)
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"fps\"\r\n\r\n\(request.fps)\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"seg_frames\"\r\n\r\n\(request.segFrames)\r\n")
        append("--\(boundary)--\r\n")

        let streamEndpoint = baseURL.appendingPathComponent("lipsync_stream")
        var urlRequest = URLRequest(url: streamEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 600
        urlRequest.httpBody = body

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "LipSyncClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "LipSync render gagal (8810?)"]
            )
        }

        var urls: [URL] = []
        _ = try await LengthPrefixedStreamParser.parse(bytes: bytes) { chunk, index in
            let segmentURL = dir.appendingPathComponent(String(format: "seg_%04d.mp4", index))
            try chunk.write(to: segmentURL)
            urls.append(segmentURL)
        }

        guard !urls.isEmpty else {
            throw NSError(
                domain: "LipSyncClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "tidak ada video segmen yang dihasilkan"]
            )
        }

        return urls
    }
}
