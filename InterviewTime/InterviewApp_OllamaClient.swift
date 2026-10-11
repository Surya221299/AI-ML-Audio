//
//  OllamaClient.swift
//  Interviewer
//
//  Port dari class `LLM` di interviewer.py. Memanggil Ollama REST API
//  (http://<host>:11434/api/chat) yang menjalankan model on-device,
//  contoh: llama3.2:8b / llama3.1:8b. Ollama tetap perlu jalan di mesin
//  yang sama (atau di jaringan lokal) — SwiftUI ini cuma front-end-nya.
//

import Foundation

struct ToolCallResult {
    let name: String
    let arguments: [String: JSONValue]
}

struct OllamaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// `actor` supaya properti adaptif (supportsThink/supportsKeepAlive) aman
/// dipakai dari banyak Task sekaligus (mirip flag _supports_think di Python).
actor OllamaClient {
    let baseURL: URL
    private var supportsThink = true
    private var supportsKeepAlive = true
    var debugTiming = true
    var onDebugLine: ((String) -> Void)?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func setDebugHandler(_ handler: @escaping (String) -> Void) {
        onDebugLine = handler
    }

    /// Setara LLM.chat(): return (content_bersih, tool_calls)
    func chat(
        model: String,
        messages: [[String: String]],
        tools: [[String: Any]]? = nil,
        temperature: Double = 0.4,
        numPredict: Int? = nil,
        keepAlive: String = "30m",
        disableThinking: Bool = true
    ) async throws -> (content: String, toolCalls: [ToolCallResult]) {
        try await callWithFallback(
            model: model, messages: messages, tools: tools,
            temperature: temperature, numPredict: numPredict,
            keepAlive: keepAlive, disableThinking: disableThinking
        )
    }

    /// Setara LLM.chat_json(): retry otomatis kalau output bukan JSON valid.
    func chatJSON(
        model: String,
        messages: [[String: String]],
        temperature: Double = 0.3,
        numPredict: Int? = nil,
        maxRetry: Int = 2
    ) async -> JSONValue? {
        var msgs = messages
        var lastRaw = ""
        for _ in 0...maxRetry {
            do {
                let (content, _) = try await chat(
                    model: model, messages: msgs, temperature: temperature, numPredict: numPredict
                )
                if let parsed = TextUtils.extractJSON(content) {
                    return parsed
                }
                lastRaw = content
                msgs.append(["role": "assistant", "content": content])
                msgs.append([
                    "role": "user",
                    "content": "Output di atas BUKAN JSON valid. ULANGI jawabanmu HANYA dalam bentuk JSON valid, tanpa teks tambahan, tanpa markdown fence, tanpa penjelasan."
                ])
            } catch {
                onDebugLine?("Gagal memanggil model '\(model)': \(error.localizedDescription)")
                return nil
            }
        }
        if !lastRaw.isEmpty {
            onDebugLine?("Gagal mendapat JSON valid. Raw terakhir: \(String(lastRaw.prefix(300)))")
        }
        return nil
    }

    // MARK: - Internal

    private func callWithFallback(
        model: String,
        messages: [[String: String]],
        tools: [[String: Any]]?,
        temperature: Double,
        numPredict: Int?,
        keepAlive: String,
        disableThinking: Bool
    ) async throws -> (content: String, toolCalls: [ToolCallResult]) {

        var options: [String: Any] = ["temperature": temperature]
        if let numPredict { options["num_predict"] = numPredict }

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": false,
            "options": options
        ]
        if let tools { body["tools"] = tools }
        if supportsKeepAlive { body["keep_alive"] = keepAlive }
        if supportsThink && disableThinking { body["think"] = false }

        let url = baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 180

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError(message: "Tidak bisa menghubungi Ollama di \(baseURL.absoluteString). Pastikan 'ollama serve' berjalan & model '\(model)' sudah di-pull. (\(error.localizedDescription))")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Mirip retry adaptif Python: kalau server menolak parameter 'think' / 'keep_alive'
        // (versi Ollama lama), lepas parameter itu lalu ulangi sekali.
        if status == 400 {
            let raw = String(data: data, encoding: .utf8) ?? ""
            if supportsThink, body["think"] != nil, raw.lowercased().contains("think") {
                supportsThink = false
                return try await callWithFallback(model: model, messages: messages, tools: tools,
                                                    temperature: temperature, numPredict: numPredict,
                                                    keepAlive: keepAlive, disableThinking: disableThinking)
            }
            if supportsKeepAlive, body["keep_alive"] != nil, raw.lowercased().contains("keep_alive") {
                supportsKeepAlive = false
                return try await callWithFallback(model: model, messages: messages, tools: tools,
                                                    temperature: temperature, numPredict: numPredict,
                                                    keepAlive: keepAlive, disableThinking: disableThinking)
            }
        }

        guard (200..<300).contains(status) else {
            let raw = String(data: data, encoding: .utf8) ?? "(tidak ada body)"
            throw OllamaError(message: "Ollama mengembalikan error (\(status)): \(raw)")
        }

        guard let json = JSONValue.parse(data), let obj = json.objectValue else {
            throw OllamaError(message: "Respons Ollama tidak bisa diparse sebagai JSON.")
        }

        let message = obj["message"]?.objectValue ?? [:]
        let rawContent = message["content"]?.stringValue ?? ""
        let toolCallsRaw = message["tool_calls"]?.arrayValue ?? []

        if debugTiming {
            let totalNs = obj["total_duration"]?.doubleValue ?? 0
            let loadNs = obj["load_duration"]?.doubleValue ?? 0
            let promptNs = obj["prompt_eval_duration"]?.doubleValue ?? 0
            let evalNs = obj["eval_duration"]?.doubleValue ?? 0
            let promptTok = obj["prompt_eval_count"]?.doubleValue ?? 0
            let outputTok = obj["eval_count"]?.doubleValue ?? 0
            let evalS = evalNs / 1e9
            let tokPerS = evalS > 0 ? outputTok / evalS : 0
            let hasThink = rawContent.contains("<think>")
            onDebugLine?(String(
                format: "⏱ [%@] total=%.1fs (load=%.1fs, prefill=%.1fs, gen=%.1fs) | prompt_tok=%.0f | output_tok=%.0f (%.1f tok/s) | think_tag=%@",
                model, totalNs / 1e9, loadNs / 1e9, promptNs / 1e9, evalS,
                promptTok, outputTok, tokPerS, hasThink ? "YA <- biang latency" : "tidak"
            ))
        }

        var toolCalls: [ToolCallResult] = []
        for tc in toolCallsRaw {
            guard let fn = tc["function"]?.objectValue else { continue }
            let name = fn["name"]?.stringValue ?? ""
            let args = fn["arguments"]?.objectValue ?? [:]
            toolCalls.append(ToolCallResult(name: name, arguments: args))
        }

        return (TextUtils.stripThink(rawContent), toolCalls)
    }
}

// ============================================================
// TOOL DEFINITION (Ollama function calling) — port dari RECORD_NOTE_TOOL
// ============================================================
enum OllamaTools {
    static let recordNote: [String: Any] = [
        "type": "function",
        "function": [
            "name": "record_note",
            "description": "Catat satu observasi terstruktur tentang kandidat berdasarkan jawaban terakhirnya. Panggil 0 kali jika jawaban tidak mengandung hal penting, atau beberapa kali jika ada beberapa observasi berbeda.",
            "parameters": [
                "type": "object",
                "properties": [
                    "topic": [
                        "type": "string",
                        "description": "Kompetensi/topik terkait, mis. 'Swift', 'Komunikasi', 'Arsitektur'."
                    ],
                    "note": [
                        "type": "string",
                        "description": "Observasi singkat & spesifik tentang kandidat (1-2 kalimat)."
                    ],
                    "sentiment": [
                        "type": "string",
                        "enum": ["strength", "weakness", "gap", "red_flag", "neutral"],
                        "description": "Klasifikasi observasi."
                    ]
                ],
                "required": ["topic", "note", "sentiment"]
            ]
        ]
    ]
}
