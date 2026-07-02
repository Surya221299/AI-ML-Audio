//
//  InterviewPrep.swift
//  InterviewTime
//
//  "Otak" persiapan wawancara — dijalankan di layar Start:
//  muat STT + generate 4 pertanyaan + render (opening, pertanyaan, closing) ke folder.
//  Setelah selesai (isReady), ConversationView tinggal memutar dari folder.
//

import Foundation
import AppKit
import Combine

@MainActor
final class InterviewPrep: ObservableObject {

    enum Stage: Equatable {
        case idle
        case loadingSTT
        case analyzing
        case rendering(String)   // pesan progres
        case ready
        case failed(String)
    }

    @Published var stage: Stage = .idle
    @Published var questions: [String] = []
    @Published var jobDescription = ""

    let whisper = WhisperService()
    private let ollama = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)

    private let llmModel = "llama3.1:8b"
    private let ttsURL = "http://127.0.0.1:8808/speak"
    private let lipsyncURL = "http://127.0.0.1:8810/lipsync_stream"
    let numQuestions = 4

    let openingText = "Sebelum kita masuk ke sesi utama, boleh ceritakan sedikit tentang diri Anda? Termasuk background Anda, alasan tertarik dengan posisi ini, dan project atau pengalaman kerja yang pernah Anda kerjakan."
    let closingText = "Baik terimakasih, Sebelum kita mengakhiri sesi interview ini. Apakah dari anda ada pertanyaan untuk kami?"

    // MARK: Folder tetap
    var outputsRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("outputs")
    }
    var openingDir: URL { outputsRoot.appendingPathComponent("opening") }
    var closingDir: URL { outputsRoot.appendingPathComponent("closing") }
    func questionDir(_ i: Int) -> URL { outputsRoot.appendingPathComponent("q\(i)") }

    var isReady: Bool { if case .ready = stage { return true }; return false }
    var isWorking: Bool {
        switch stage { case .idle, .ready, .failed: return false; default: return true }
    }

    // MARK: - Persiapan lengkap

    func prepare(jobDescription: String) async {
        self.jobDescription = jobDescription
        // 1. STT
        if !whisper.isReady {
            stage = .loadingSTT
            await whisper.loadModel()
            if !whisper.isReady { stage = .failed("STT gagal: \(whisper.status)"); return }
        }

        // 2. Generate pertanyaan
        stage = .analyzing
        let qs = await generateQuestions(jobDescription: jobDescription)
        guard qs.count == numQuestions else { stage = .failed("Gagal membuat pertanyaan"); return }
        questions = qs

        // 3. Render semua ke folder.
        //    Pertanyaan SELALU dirender ulang (beda JD = beda pertanyaan),
        //    jadi hapus cache pertanyaan lama dulu. Opening/closing tetap di-cache.
        for i in 0..<numQuestions {
            try? FileManager.default.removeItem(at: questionDir(i))
        }
        do {
            if loadSaved(openingDir) == nil {
                stage = .rendering("Menyiapkan opening…")
                let wav = try await fetchTTSWav(text: openingText)
                _ = try await renderToFiles(audio: wav, dir: openingDir)
            }
            for (i, q) in qs.enumerated() {
                if loadSaved(questionDir(i)) == nil {
                    stage = .rendering("Menyiapkan pertanyaan \(i+1) dari \(qs.count)…")
                    let wav = try await fetchTTSWav(text: q)
                    _ = try await renderToFiles(audio: wav, dir: questionDir(i))
                }
            }
            if loadSaved(closingDir) == nil {
                stage = .rendering("Menyiapkan closing…")
                let wav = try await fetchTTSWav(text: closingText)
                _ = try await renderToFiles(audio: wav, dir: closingDir)
            }
        } catch {
            stage = .failed("Gagal render: \(error.localizedDescription)"); return
        }

        stage = .ready
    }

    // MARK: - LLM generate pertanyaan

    private func generateQuestions(jobDescription: String) async -> [String] {
        let system = """
        Kamu pewawancara teknis. Buat tepat \(numQuestions) pertanyaan wawancara Bahasa Indonesia dari job description.

        ATURAN KETAT (WAJIB dipatuhi untuk SETIAP pertanyaan):
        1. Satu pertanyaan = SATU topik saja. Boleh membandingkan DUA hal terkait, TIDAK BOLEH LEBIH.
        2. DILARANG KERAS menyebut 3 istilah/konsep atau lebih dalam satu pertanyaan.
        3. DILARANG memakai kata sambung penumpuk seperti "serta", "dan juga", "atau", ",", untuk menambahkan konsep ketiga.
        4. Satu kalimat, singkat, satu tanda tanya.
        5. Ambil topik HANYA dari job description. Jangan menambah teknologi di luar itu.

        Bentuk yang DITERIMA: "Jelaskan bagaimana X bekerja." atau "Apa perbedaan X dan Y?"
        Bentuk yang DITOLAK: pertanyaan yang menyebut X, Y, Z (tiga konsep) sekaligus.

        Output HANYA JSON valid: {"questions":["...","...","...","..."]}
        """
        // Coba sampai 3 kali; validasi tiap hasil, buang pertanyaan yang menumpuk konsep.
        for _ in 0..<3 {
            guard let json = await ollama.chatJSON(
                    model: llmModel,
                    messages: [["role": "system", "content": system],
                               ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]],
                    temperature: 0.2, numPredict: 500),
                  let arr = json["questions"]?.arrayValue else { continue }

            let raw = arr.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let valid = raw.filter { isFocusedQuestion($0) }

            if valid.count >= numQuestions {
                return Array(valid.prefix(numQuestions))
            }
            // kalau sebagian valid tapi kurang, gabung dulu; kalau cukup di iterasi berikut dipakai
            if valid.count > 0 && raw.count == numQuestions {
                // masih ada yang ditolak → coba regenerasi sekali lagi
                continue
            }
        }
        // Fallback terakhir: ambil apa adanya (jangan sampai app mati)
        if let json = await ollama.chatJSON(
                model: llmModel,
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]],
                temperature: 0.2, numPredict: 500),
           let arr = json["questions"]?.arrayValue {
            let raw = arr.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(raw.prefix(numQuestions))
        }
        return []
    }

    /// Tolak pertanyaan yang menumpuk >=3 konsep atau terlalu banyak penghubung.
    private func isFocusedQuestion(_ q: String) -> Bool {
        let lower = q.lowercased()
        // Hitung penghubung penumpuk
        let connectors = [", ", " serta ", " dan juga ", " maupun "]
        var connectorCount = 0
        for c in connectors { connectorCount += lower.components(separatedBy: c).count - 1 }
        // "dan" satu kali (untuk perbandingan dua hal) masih boleh; dua "dan" mencurigakan
        let andCount = lower.components(separatedBy: " dan ").count - 1
        // Terlalu banyak koma/penghubung → menumpuk konsep
        if connectorCount >= 2 { return false }
        if andCount >= 2 { return false }
        if connectorCount >= 1 && andCount >= 1 { return false }
        return true
    }

    // MARK: - Closing intent + Feedback

    /// true = kandidat "sudah cukup / tidak ada pertanyaan" (decline)
    func classifyDecline(_ answer: String) async -> Bool {
        let system = "Classifier intent satu kata. \"decline\" jika tidak ada pertanyaan / sudah cukup. \"question\" jika ada pertanyaan. Jawab HANYA satu kata."
        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": "Teks: \"\(answer)\""]],
                temperature: 0.0, numPredict: 10)
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("decline")
        } catch { return false }
    }

    /// Feedback keseluruhan: overall_score, recommendation, strengths, dll.
    func generateOverallFeedback(jobDescription: String, questions: [String], transcripts: [String]) async -> JSONValue {
        let qa = zip(questions, transcripts).enumerated()
            .map { "Pertanyaan \($0.offset+1): \($0.element.0)\nJawaban: \($0.element.1)" }
            .joined(separator: "\n\n")
        let system = """
        Anda Hiring Panel Lead. Berikan DEEP FEEDBACK paska-interview: jujur, berbasis bukti, actionable.
        WAJIB keluarkan HANYA JSON (tanpa teks lain). Setiap string maksimal 15 kata.
        Format:
        {"overall_score":number(1-10),"recommendation":"Strong Hire"|"Hire"|"Lean Hire"|"No Hire"|"Strong No Hire","strengths":[string],"weaknesses_or_gaps":[string],"red_flags":[string],"fit_vs_jd":string,"feedback_for_candidate":[string]}
        Batasi strengths, weaknesses_or_gaps, feedback_for_candidate masing-masing max 3. Bahasa Indonesia.
        """
        let user = "Posisi berdasarkan JD:\n\(jobDescription)\n\nTanya-jawab interview:\n\(qa)"
        return await ollama.chatJSON(
            model: llmModel,
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            temperature: 0.4, numPredict: 800) ?? .null
    }

    /// Feedback untuk SATU pasangan pertanyaan-jawaban.
    func generateQuestionFeedback(question: String, answer: String, position: String) async -> JSONValue {
        let system = """
        Anda interviewer profesional yang memberi feedback untuk SATU pertanyaan interview.
        WAJIB keluarkan HANYA JSON object (bukan array), tanpa teks lain, tanpa markdown.
        Format: {"question":string,"plus_points":[string],"improvements":[string]}
        plus_points: hal spesifik yang sudah bagus (berbasis bukti). improvements: hal konkret & actionable.
        Jika jawaban kosong: plus_points: [], improvements: ["Kandidat tidak memberikan jawaban."]. Bahasa Indonesia.
        """
        let user = "Posisi: \(position)\n\nPertanyaan: \(question)\n\nJawaban kandidat: \(answer.isEmpty ? "(kosong)" : answer)"
        var fb = await ollama.chatJSON(
            model: llmModel,
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            temperature: 0.4, numPredict: 400)
        if let arr = fb?.arrayValue, let first = arr.first { fb = first }
        return fb ?? .null
    }

    /// Feedback ketika kandidat tidak mengajukan pertanyaan balik di penutup.
    func generateNoQuestionsFeedback(position: String) async -> String {
        let system = """
        Anda career coach & hiring consultant. Kandidat baru menyelesaikan interview untuk posisi \(position),
        namun saat diberi kesempatan bertanya balik di akhir, menjawab tidak ada pertanyaan.
        Tulis feedback Bahasa Indonesia yang: (1) jelaskan mengapa bertanya balik penting;
        (2) beri 3-4 contoh konkret pertanyaan balik (kultur tim, alur pengembangan, growth path);
        (3) jelaskan dampak psikologis ke interviewer; (4) tutup dengan motivasi.
        Gaya empatik, coaching, 200-260 kata, paragraf mengalir tanpa bullet/header. Langsung isi.
        """
        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": "Tulis feedback."]],
                temperature: 0.6, numPredict: 450)
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return "" }
    }

    // MARK: - Helpers (dipakai bersama ConversationView)

    func loadSaved(_ dir: URL) -> [URL]? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil) else { return nil }
        let mp4s = files.filter { $0.pathExtension == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return mp4s.isEmpty ? nil : mp4s
    }

    private func fetchTTSWav(text: String) async throws -> Data {
        struct Payload: Encodable {
            let text, emotion, voice: String
            let cfg_value: Double
            let inference_timesteps, max_tokens, warmup_patches: Int
        }
        var req = URLRequest(url: URL(string: ttsURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Payload(
            text: text, emotion: "calm, professional", voice: "male_40s",
            cfg_value: 2.5, inference_timesteps: 10, max_tokens: 1200, warmup_patches: 2))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "TTS error (8808?)"])
        }
        return data
    }

    private func renderToFiles(audio: Data, dir: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old { try? FileManager.default.removeItem(at: f) }
        }
        let image = try sourceImageData()
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        func part(_ name: String, _ filename: String, _ mime: String, _ data: Data) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
            append("Content-Type: \(mime)\r\n\r\n"); body.append(data); append("\r\n")
        }
        part("image", "source.png", "image/png", image)
        part("audio", "audio.wav", "audio/wav", audio)
        append("--\(boundary)\r\n"); append("Content-Disposition: form-data; name=\"fps\"\r\n\r\n10\r\n")
        append("--\(boundary)\r\n"); append("Content-Disposition: form-data; name=\"seg_frames\"\r\n\r\n5\r\n")
        append("--\(boundary)--\r\n")

        var req = URLRequest(url: URL(string: lipsyncURL)!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = body

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "LipSync", code: 1, userInfo: [NSLocalizedDescriptionKey: "render gagal (8810?)"])
        }
        var it = bytes.makeAsyncIterator()
        func read(_ n: Int) async throws -> Data? {
            var out = Data(); out.reserveCapacity(n)
            for _ in 0..<n { guard let b = try await it.next() else { return out.isEmpty ? nil : out }; out.append(b) }
            return out
        }
        var urls: [URL] = []; var idx = 0
        while true {
            guard let h = try await read(4), h.count == 4 else { break }
            let len = h.withUnsafeBytes { Int($0.load(as: UInt32.self).bigEndian) }
            if len == 0 { break }
            guard let mp4 = try await read(len), mp4.count == len else { break }
            let url = dir.appendingPathComponent(String(format: "seg_%04d.mp4", idx))
            try mp4.write(to: url); urls.append(url); idx += 1
        }
        guard !urls.isEmpty else {
            throw NSError(domain: "LipSync", code: 2, userInfo: [NSLocalizedDescriptionKey: "tidak ada video"])
        }
        return urls
    }

    private func sourceImageData() throws -> Data {
        guard let img = NSImage(named: "Interviewer"),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "Image", code: 1, userInfo: [NSLocalizedDescriptionKey: "gagal load Interviewer"])
        }
        return png
    }
}
