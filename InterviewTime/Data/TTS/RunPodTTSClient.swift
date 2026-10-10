//
//  RunPodTTSClient.swift
//  InterviewTime
//

import Foundation

public final class RunPodTTSClient: SpeechSynthesizer, @unchecked Sendable {
    private let endpointId: String
    private let apiKey: String
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

    private struct Body: Encodable {
        let input: InternalPayload
    }

    private struct RunResp: Decodable {
        let id: String
    }

    private struct StatusResp: Decodable {
        let status: String
        let output: Output?
        struct Output: Decodable {
            let audio_b64: String?
            let error: String?
        }
    }

    public init(
        endpointId: String,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.endpointId = endpointId.trimmingCharacters(in: .whitespaces)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        self.session = session
    }

    public var isConfigured: Bool {
        !endpointId.isEmpty && !apiKey.isEmpty
    }

    public func warmUp() {
        guard isConfigured else { return }
        Task { [weak self] in
            guard let self else { return }
            let req = SpeechSynthesisRequest(
                text: "Halo",
                emotion: "calm",
                voice: "male_40s",
                cfgValue: 2.5,
                inferenceTimesteps: 6,
                maxTokens: 200,
                warmupPatches: 2
            )
            _ = try? await self.synthesizeSpeech(request: req)
        }
    }

    public func synthesizeSpeech(request: SpeechSynthesisRequest) async throws -> Data {
        guard isConfigured else {
            throw NSError(
                domain: "RunPodTTSClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "RunPod endpoint/key kosong"]
            )
        }

        let base = "https://api.runpod.ai/v2/\(endpointId)"
        guard let runURL = URL(string: "\(base)/run") else {
            throw NSError(
                domain: "RunPodTTSClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid RunPod URL"]
            )
        }

        var runRequest = URLRequest(url: runURL)
        runRequest.httpMethod = "POST"
        runRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        runRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let internalPayload = InternalPayload(
            text: request.text,
            emotion: request.emotion,
            voice: request.voice,
            cfg_value: request.cfgValue,
            inference_timesteps: request.inferenceTimesteps,
            max_tokens: request.maxTokens,
            warmup_patches: request.warmupPatches
        )

        runRequest.httpBody = try JSONEncoder().encode(Body(input: internalPayload))
        let (data, resp) = try await session.data(for: runRequest)

        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(
                domain: "RunPodTTSClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "RunPod /run gagal"]
            )
        }

        let job = try JSONDecoder().decode(RunResp.self, from: data)
        guard let statusURL = URL(string: "\(base)/status/\(job.id)") else {
            throw NSError(
                domain: "RunPodTTSClient",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid RunPod status URL"]
            )
        }

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            var sreq = URLRequest(url: statusURL)
            sreq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (sdata, _) = try await session.data(for: sreq)
            let st = try JSONDecoder().decode(StatusResp.self, from: sdata)

            switch st.status {
            case "COMPLETED":
                guard let b64 = st.output?.audio_b64, let wav = Data(base64Encoded: b64) else {
                    throw NSError(
                        domain: "RunPodTTSClient",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: st.output?.error ?? "RunPod tanpa audio"]
                    )
                }
                return wav
            case "FAILED", "CANCELLED", "TIMED_OUT":
                throw NSError(
                    domain: "RunPodTTSClient",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "RunPod job \(st.status)"]
                )
            default:
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }

        throw NSError(
            domain: "RunPodTTSClient",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "RunPod timeout"]
        )
    }
}
