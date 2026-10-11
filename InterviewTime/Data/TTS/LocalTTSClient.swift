//
//  LocalTTSClient.swift
//  InterviewTime
//

import Foundation

public final class LocalTTSClient: SpeechSynthesizer, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    private struct InternalPayload: Encodable {
        let text: String
        let emotion: String
        let voice: String
        let cfg_value: Double
        let inference_timesteps: Int
        let max_tokens: Int
        let warmup_patches: Int
    }

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8808")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func synthesizeSpeech(request: SpeechSynthesisRequest) async throws -> Data {
        let endpoint = baseURL.appendingPathComponent("speak")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 300

        let payload = InternalPayload(
            text: request.text,
            emotion: request.emotion,
            voice: request.voice,
            cfg_value: request.cfgValue,
            inference_timesteps: request.inferenceTimesteps,
            max_tokens: request.maxTokens,
            warmup_patches: request.warmupPatches
        )

        urlRequest.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(
                domain: "LocalTTSClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "TTS error (8808?)"]
            )
        }

        return data
    }
}
