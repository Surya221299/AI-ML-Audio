//
//  WhisperService.swift
//  AudioCombineApp
//
//  Thin wrapper around WhisperKit (on-device Whisper via Core ML).
//  Loads the model once, transcribes verbatim with word timestamps.
//
//  Requires the WhisperKit Swift package:
//      https://github.com/argmaxinc/WhisperKit
//
//  NOTE on the "empty second transcription" bug: it was caused by the
//  biasing prompt (Config.useBiasingPrompt). On the first transcribe call
//  pipe.tokenizer is still nil (just-prewarmed), so the prompt block is
//  skipped and transcription works. On later calls the tokenizer exists,
//  promptTokens get injected, and the decoder is biased into returning an
//  empty result. Fix: Config.useBiasingPrompt = false. Technical-term
//  corrections still run via Config.applyCorrections (post-processing).
//

import Foundation
import WhisperKit
import Combine

@MainActor
final class WhisperService: ObservableObject {

    @Published var status: String = "Model belum dimuat"
    @Published var isLoading = false
    @Published var isReady = false

    private var pipe: WhisperKit?
    private var loadedModelName = Config.model

    // MARK: - Load model

    func loadModel() async {
        guard pipe == nil else { isReady = true; return }
        isLoading = true

        let candidates = await resolveCandidates()
        print("[Whisper] Candidates: \(candidates.joined(separator: ", "))")

        for name in candidates {
            status = "Memuat model '\(shortName(name))'…"
            do {
                pipe = try await WhisperKit(WhisperKitConfig(model: name, prewarm: false))
                loadedModelName = shortName(name)
                isReady = true
                status = "Model siap (\(shortName(name)))."
                isLoading = false
                print("[Whisper] Loaded: \(name)")
                return
            } catch {
                print("[Whisper] Failed to load \(name): \(error.localizedDescription)")
                status = "Gagal memuat '\(shortName(name))': \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    private func resolveCandidates() async -> [String] {
        let pref = Config.model.lowercased()
        let available = (try? await WhisperKit.fetchAvailableModels()) ?? []

        func firstContaining(_ needle: String, excluding: String? = nil) -> String? {
            available.first {
                $0.lowercased().contains(needle)
                && (excluding == nil || !$0.lowercased().contains(excluding!))
            }
        }

        var list: [String] = []

        // Prefer large-v3 non-distil for best multilingual (ID/EN) accuracy.
        if pref.contains("large-v3") || pref.contains("large") {
            if let lv3 = firstContaining("large-v3", excluding: "distil") {
                list.append(lv3)
            }
            if let lv3any = firstContaining("large-v3"), !list.contains(lv3any) {
                list.append(lv3any)
            }
        } else if pref.contains("turbo") {
            if let turboClean = firstContaining("turbo", excluding: "distil") {
                list.append(turboClean)
            }
            if let turboAny = firstContaining("turbo"), !list.contains(turboAny) {
                list.append(turboAny)
            }
        } else if let exact = available.first(where: { $0.lowercased().contains(pref) }) {
            list.append(exact)
        }

        if let lv3 = firstContaining("large-v3", excluding: "distil"), !list.contains(lv3) {
            list.append(lv3)
        }
        if let lv3any = firstContaining("large-v3"), !list.contains(lv3any) {
            list.append(lv3any)
        }
        for alias in ["small", "base"] where !list.contains(alias) {
            list.append(alias)
        }
        return list
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "openai_whisper-", with: "")
    }

    // MARK: - Transcribe

    func transcribe(url: URL) async throws -> STTResult {
        if pipe == nil { await loadModel() }
        guard let pipe else {
            throw NSError(domain: "WhisperService", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model tidak tersedia"])
        }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "id"
        options.detectLanguage = false
        options.usePrefillPrompt = true
        options.temperature = 0.0
        options.wordTimestamps = true

        if Config.verbatim {
            options.suppressBlank = false
        }

        if Config.verbatim, Config.useBiasingPrompt, let tokenizer = pipe.tokenizer {
            let promptText = " " + Config.initialPrompt.trimmingCharacters(in: .whitespaces)
            let promptTokens = tokenizer.encode(text: promptText)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !promptTokens.isEmpty {
                options.promptTokens = promptTokens
                options.usePrefillPrompt = true
            }
        }

        let t0 = Date()
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let infer = Date().timeIntervalSince(t0)

        var words: [TranscriptWord] = []
        var fullText = ""
        var detectedLanguage = "id"
        for r in results {
            fullText += r.text
            if !r.language.isEmpty { detectedLanguage = r.language }
            for seg in r.segments {
                guard let segWords = seg.words else { continue }
                for w in segWords {
                    let token = w.word.trimmingCharacters(in: .whitespaces)
                    words.append(TranscriptWord(text: token,
                                                 start: Double(w.start),
                                                 end: Double(w.end),
                                                 probability: Double(w.probability)))
                }
            }
        }

        let text = Config.applyCorrections(fullText.trimmingCharacters(in: .whitespacesAndNewlines))
        let duration = words.last?.end ?? 0
        let rtf = duration > 0 ? infer / duration : 0

        print("[Whisper] \"\(text.prefix(60))\(text.count > 60 ? "…" : "")\" — \(words.count) words, \(String(format: "%.2f", infer))s")

        return STTResult(text: text,
                          language: detectedLanguage,
                          words: words,
                          audioSeconds: duration,
                          inferSeconds: infer,
                          realTimeFactor: rtf,
                          model: loadedModelName)
    }
}
