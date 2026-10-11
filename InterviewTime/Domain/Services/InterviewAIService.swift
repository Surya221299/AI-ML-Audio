//
//  InterviewAIService.swift
//  InterviewTime
//

import Foundation

public protocol InterviewAIServiceProtocol: Sendable {
    func generateQuestions(jobDescription: String) async -> [String]
    func generateClosingAnswers(jobDescription: String) async -> [ClosingCategory: String]
    func classifyClosingCategory(_ question: String) async -> ClosingCategory
    func classifyDecline(_ answer: String) async -> Bool
    func generateClosingAnswer(candidateQuestion: String, remaining: Int) async -> String
    func generateFollowUp(question: String, answer: String) async -> String
    func generateOverallFeedback(jobDescription: String, questions: [String], transcripts: [String]) async -> OverallFeedback?
    func generateQuestionFeedback(question: String, answer: String, position: String) async -> QuestionFeedback?
    func generateNoQuestionsFeedback(position: String) async -> String
}

public final class InterviewAIService: InterviewAIServiceProtocol, Sendable {
    private let ollama: OllamaClient
    private let llmModel: String
    private let numQuestions: Int

    init(
        ollama: OllamaClient = OllamaClient(baseURL: AppConfig.ollamaURL),
        llmModel: String = AppConfig.llmModel,
        numQuestions: Int = AppConfig.numQuestions
    ) {
        self.ollama = ollama
        self.llmModel = llmModel
        self.numQuestions = numQuestions
    }

    // MARK: - Questions Generation

    public func generateQuestions(jobDescription: String) async -> [String] {
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

        for _ in 0..<3 {
            guard let json = await ollama.chatJSON(
                model: llmModel,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]
                ],
                temperature: 0.2,
                numPredict: 500
            ),
            let arr = json["questions"]?.arrayValue else { continue }

            let raw = arr.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let valid = raw.filter { QuestionValidator.isFocusedQuestion($0) }

            if valid.count >= numQuestions {
                return Array(valid.prefix(numQuestions))
            }
            if valid.count > 0 && raw.count == numQuestions {
                continue
            }
        }

        // Fallback terakhir: ambil apa adanya
        if let json = await ollama.chatJSON(
            model: llmModel,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]
            ],
            temperature: 0.2,
            numPredict: 500
        ),
        let arr = json["questions"]?.arrayValue {
            let raw = arr.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Array(raw.prefix(numQuestions))
        }

        return []
    }

    // MARK: - Closing Answers

    public func generateClosingAnswers(jobDescription: String) async -> [ClosingCategory: String] {
        let system = """
        Kamu HRD/interviewer profesional yang MEWAKILI perusahaan. Berdasarkan job description, tulis
        jawaban untuk 4 pertanyaan yang MUNGKIN ditanyakan kandidat di akhir interview.
        PERSPEKTIF WAJIB: gunakan "kami/perusahaan kami" untuk pihakmu, dan "Anda" untuk kandidat.
        Contoh benar: "Di perusahaan kami, Anda akan mendapat kesempatan berkembang..."
        JANGAN tertukar (jangan sebut kandidat "kami" atau perusahaan "Anda").
        Tiap jawaban 2-3 kalimat, Bahasa Indonesia, hangat & informatif, JANGAN balik bertanya.
        Kategori:
        - posisi: tentang peran, tanggung jawab, ekspektasi di posisi ini.
        - perusahaan: tentang budaya kerja, tim, lingkungan.
        - benefit: tentang gaji/tunjangan/asuransi/cuti/pengembangan diri (jawab umum bila tak disebut JD).
        - proses: tentang tahap selanjutnya & kapan hasil interview diinformasikan.
        Output HANYA JSON: {"posisi":"...","perusahaan":"...","benefit":"...","proses":"..."}
        """

        guard let json = await ollama.chatJSON(
            model: llmModel,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]
            ],
            temperature: 0.5,
            numPredict: 700
        ) else { return [:] }

        var out: [ClosingCategory: String] = [:]
        for cat in ClosingCategory.allCases {
            if let t = json[cat.rawValue]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                out[cat] = t
            }
        }
        return out
    }

    public func classifyClosingCategory(_ question: String) async -> ClosingCategory {
        let system = """
        Klasifikasikan pertanyaan kandidat ke SATU kategori: posisi, perusahaan, benefit, atau proses.
        - posisi: peran, tugas, tanggung jawab, skill, tech stack.
        - perusahaan: budaya, tim, lingkungan kerja, nilai perusahaan.
        - benefit: gaji, tunjangan, asuransi, cuti, remote, jam kerja, fasilitas.
        - proses: tahap selanjutnya, kapan pengumuman, timeline rekrutmen.
        Jawab HANYA satu kata dari empat itu.
        """
        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": question]
                ],
                temperature: 0.0,
                numPredict: 10
            )
            let c = content.lowercased()
            for cat in ClosingCategory.allCases where c.contains(cat.rawValue) {
                return cat
            }
            return .proses
        } catch {
            return .proses
        }
    }

    // MARK: - Decline Classification

    public func classifyDecline(_ answer: String) async -> Bool {
        if DeclineHeuristics.hasQuestionIndicators(answer) {
            return false
        }
        let looksDecline = DeclineHeuristics.hasDeclineIndicators(answer)

        let system = """
        Tugasmu klasifikasi apakah kandidat MENGAJUKAN PERTANYAAN atau TIDAK, di akhir interview.
        Jawab HANYA satu kata: "question" atau "decline".
        - "question" = kandidat menanyakan sesuatu (tentang posisi, perusahaan, gaji, proses, dll).
        - "decline" = kandidat menyatakan tidak ada pertanyaan / sudah cukup.
        Contoh:
        "Bagaimana budaya kerjanya?" -> question
        "Apakah ada asuransi?" -> question
        "Tidak ada, terima kasih" -> decline
        "Sudah cukup" -> decline
        Jika ragu, jawab "question".
        """

        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": answer]
                ],
                temperature: 0.0,
                numPredict: 5
            )
            let out = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if out.hasPrefix("decline") { return true }
            if out.hasPrefix("question") { return false }
            return looksDecline
        } catch {
            return looksDecline
        }
    }

    public func generateClosingAnswer(candidateQuestion: String, remaining: Int) async -> String {
        let isLast = remaining <= 1
        let tail = isLast
            ? "Ini kesempatan terakhir. Setelah menjawab, tutup dengan kalimat hangat dan nyatakan interview selesai."
            : "Setelah menjawab, tanyakan singkat apakah ada lagi yang ingin ditanyakan. JANGAN sebutkan angka/jumlah pertanyaan tersisa."

        let system = """
        Anda "Gemala", AI Interviewer profesional di perusahaan teknologi. Sesi interview sudah selesai
        dan kandidat sedang bertanya kepada Anda tentang posisi/perusahaan.
        TUGAS:
        - Jawab pertanyaan kandidat: informatif, hangat, jujur.
        - JANGAN balik bertanya. JANGAN akhiri jawaban dengan pertanyaan.
        - Jika di luar konteks, jawab general namun masuk akal sebagai perusahaan tech profesional.
        - Bahasa Indonesia formal-hangat, SINGKAT 2-3 kalimat saja.
        \(tail)
        """

        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": "Pertanyaan kandidat: \(candidateQuestion)"]
                ],
                temperature: 0.5,
                numPredict: 150
            )
            let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Terima kasih atas pertanyaannya! Kami akan menjelaskan lebih lanjut saat onboarding." : t
        } catch {
            return "Terima kasih atas pertanyaannya! Kami akan menjelaskan lebih lanjut saat onboarding."
        }
    }

    // MARK: - Follow-up

    public func generateFollowUp(question: String, answer: String) async -> String {
        if answer.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        let system = """
        Kamu pewawancara teknis. Berdasarkan pertanyaan dan jawaban kandidat, buat SATU pertanyaan
        pendalaman (follow-up) yang singkat — maksimal satu kalimat, menggali lebih dalam dari jawaban.
        Fokus satu hal. Bahasa Indonesia. Jika jawaban sudah lengkap/tidak perlu digali, balas "SKIP".
        """
        let user = "Pertanyaan: \(question)\nJawaban kandidat: \(answer)"

        do {
            let (content, _) = try await ollama.chat(
                model: llmModel,
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                temperature: 0.4,
                numPredict: 80
            )
            let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.uppercased().contains("SKIP") || t.isEmpty { return "" }
            return t
        } catch {
            return ""
        }
    }

    // MARK: - Feedbacks

    public func generateOverallFeedback(
        jobDescription: String,
        questions: [String],
        transcripts: [String]
    ) async -> OverallFeedback? {
        let qa = zip(questions, transcripts).enumerated()
            .map { "Pertanyaan \($0.offset + 1): \($0.element.0)\nJawaban: \($0.element.1)" }
            .joined(separator: "\n\n")

        let system = """
        Anda Hiring Panel Lead. Berikan DEEP FEEDBACK paska-interview: jujur, berbasis bukti, actionable.
        WAJIB keluarkan HANYA JSON (tanpa teks lain). Setiap string maksimal 15 kata.
        Format:
        {"overall_score":number(1-10),"recommendation":"Strong Hire"|"Hire"|"Lean Hire"|"No Hire"|"Strong No Hire","strengths":[string],"weaknesses_or_gaps":[string],"red_flags":[string],"fit_vs_jd":string,"feedback_for_candidate":[string]}
        Batasi strengths, weaknesses_or_gaps, feedback_for_candidate masing-masing max 3. Bahasa Indonesia.
        """
        let user = "Posisi berdasarkan JD:\n\(jobDescription)\n\nTanya-jawab interview:\n\(qa)"

        guard let json = await ollama.chatJSON(
            model: llmModel,
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            temperature: 0.4,
            numPredict: 800
        ) else { return nil }

        return OverallFeedback.from(json: json)
    }

    public func generateQuestionFeedback(
        question: String,
        answer: String,
        position: String
    ) async -> QuestionFeedback? {
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
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            temperature: 0.4,
            numPredict: 400
        )
        if let arr = fb?.arrayValue, let first = arr.first {
            fb = first
        }
        guard let json = fb else { return nil }
        return QuestionFeedback.from(json: json)
    }

    public func generateNoQuestionsFeedback(position: String) async -> String {
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
                messages: [
                    ["role": "system", "content": system],
                    ["role": "user", "content": "Tulis feedback."]
                ],
                temperature: 0.6,
                numPredict: 450
            )
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }
}
