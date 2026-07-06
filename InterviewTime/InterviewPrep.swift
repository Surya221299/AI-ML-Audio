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

    struct PrepStep: Identifiable, Equatable {
        let id = UUID()
        let title: String
        var status: Status
        enum Status { case pending, active, done }
    }

    @Published var stage: Stage = .idle
    @Published var steps: [PrepStep] = []
    @Published var questions: [String] = []
    @Published var jobDescription = ""

    let whisper = WhisperService()
    private let ollama = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)

    private let llmModel = "llama3.1:8b"
    private let ttsURL = "http://127.0.0.1:8808/speak"
    private let lipsyncURL = "http://127.0.0.1:8810/lipsync_stream"
    let numQuestions = 4
    let maxFollowUps = 2

    // RunPod TTS (opsional) — kalau endpoint+key terisi, follow-up aktif.
    @Published var runpodEndpoint = ""
    @Published var runpodKey = ""
    var followUpEnabled: Bool {
        !runpodEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
        && !runpodKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    let openingText = "Sebelum kita masuk ke sesi utama, boleh ceritakan sedikit tentang diri Anda? Termasuk background Anda, alasan tertarik dengan posisi ini, dan project atau pengalaman kerja yang pernah Anda kerjakan."
    let closingText = "Baik terimakasih, Sebelum kita mengakhiri sesi interview ini. Apakah dari anda ada pertanyaan untuk kami?"

    // Jawaban tanya-balik yang TETAP (tidak berubah per JD) — di-cache seperti opening/closing.
    let benefitAnswerText = "Terima kasih atas pertanyaannya. Saat ini saya dapat menjelaskan benefit secara umum, seperti BPJS, asuransi kesehatan, cuti tahunan, serta fasilitas kerja. Untuk detail mengenai nominal tunjangan, bonus, maupun benefit lainnya biasanya akan dijelaskan pada tahap offering karena menyesuaikan level dan posisi yang dilamar."
    let prosesAnswerText = "Setelah interview HR ini, kandidat yang lolos akan melanjutkan ke tahap interview teknis dengan tim engineering. Setelah itu akan ada sesi final interview dengan user atau hiring manager. Seluruh proses biasanya memakan waktu sekitar satu hingga dua minggu, tergantung ketersediaan jadwal masing-masing pihak. Kami akan menghubungi Anda untuk setiap perkembangan proses."

    // Kategori yang teksnya tetap (cache permanen) vs yang di-generate dari JD.
    let fixedAnswerCategories = ["benefit", "proses"]

    // Penutup yang ditambahkan di akhir SETIAP jawaban tanya-balik.
    let answerFollowUpPrompt = " Apakah ada pertanyaan lain yang ingin Anda tanyakan?"

    // MARK: Folder tetap
    var outputsRoot: URL {
        // Pakai #file (lokasi file sumber) → naik 2 folder ke root proyek → outputs/.
        // Lebih andal daripada currentDirectoryPath yang tak menentu saat run dari Xcode.
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // InterviewTime/
            .deletingLastPathComponent()   // root proyek
            .appendingPathComponent("outputs")
    }
    var openingDir: URL { outputsRoot.appendingPathComponent("opening") }
    var closingDir: URL { outputsRoot.appendingPathComponent("closing") }
    func questionDir(_ i: Int) -> URL { outputsRoot.appendingPathComponent("q\(i)") }

    // Kategori jawaban tanya-balik (pre-rendered)
    let closingCategories = ["posisi", "perusahaan", "benefit", "proses"]
    func answerDir(_ cat: String) -> URL { outputsRoot.appendingPathComponent("answer_\(cat)") }

    var isReady: Bool { if case .ready = stage { return true }; return false }
    var isWorking: Bool {
        switch stage { case .idle, .ready, .failed: return false; default: return true }
    }

    // MARK: - Step tracking

    private func initSteps(questionCount: Int) {
        var list: [PrepStep] = []
        list.append(.init(title: "Memuat model suara", status: .pending))
        list.append(.init(title: "Menganalisis job description", status: .pending))
        list.append(.init(title: "Menyiapkan pembuka", status: .pending))
        for i in 0..<questionCount {
            list.append(.init(title: "Menyiapkan pertanyaan \(i+1)", status: .pending))
        }
        list.append(.init(title: "Menyiapkan penutup", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: posisi", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: perusahaan", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: benefit", status: .pending))
        list.append(.init(title: "Menyiapkan jawaban: proses", status: .pending))
        steps = list
    }

    private func markStep(_ index: Int, _ status: PrepStep.Status) {
        guard steps.indices.contains(index) else { return }
        steps[index].status = status
    }

    // MARK: - Persiapan lengkap

    func prepare(jobDescription: String) async {
        self.jobDescription = jobDescription
        warmUpRunpodIfNeeded()   // panaskan RunPod di background bila follow-up aktif
        print("PREP outputsRoot =", outputsRoot.path)
        print("PREP openingDir exists? =", FileManager.default.fileExists(atPath: openingDir.path))
        initSteps(questionCount: numQuestions)

        // 1. STT — step 0
        markStep(0, .active)
        if !whisper.isReady {
            stage = .loadingSTT
            await whisper.loadModel()
            if !whisper.isReady { stage = .failed("STT gagal: \(whisper.status)"); return }
        }
        markStep(0, .done)

        // 2. Generate pertanyaan — step 1
        markStep(1, .active)
        stage = .analyzing
        let qs = await generateQuestions(jobDescription: jobDescription)
        guard qs.count == numQuestions else { stage = .failed("Gagal membuat pertanyaan"); return }
        questions = qs
        markStep(1, .done)

        // 3. Render semua ke folder.
        //    Pertanyaan SELALU dirender ulang (beda JD = beda pertanyaan),
        //    jadi hapus cache pertanyaan lama dulu. Opening/closing tetap di-cache.
        for i in 0..<numQuestions {
            try? FileManager.default.removeItem(at: questionDir(i))
        }
        do {
            markStep(2, .active)
            if loadSaved(openingDir) == nil {
                stage = .rendering("Menyiapkan opening…")
                let wav = try await fetchTTSWav(text: openingText)
                _ = try await renderToFiles(audio: wav, dir: openingDir)
            }
            markStep(2, .done)
            for (i, q) in qs.enumerated() {
                markStep(3 + i, .active)
                if loadSaved(questionDir(i)) == nil {
                    stage = .rendering("Menyiapkan pertanyaan \(i+1) dari \(qs.count)…")
                    let wav = try await fetchTTSWav(text: q)
                    _ = try await renderToFiles(audio: wav, dir: questionDir(i))
                }
                markStep(3 + i, .done)
            }
            let closingStep = 3 + numQuestions
            markStep(closingStep, .active)
            if loadSaved(closingDir) == nil {
                stage = .rendering("Menyiapkan closing…")
                let wav = try await fetchTTSWav(text: closingText)
                _ = try await renderToFiles(audio: wav, dir: closingDir)
            }
            markStep(closingStep, .done)
        } catch {
            stage = .failed("Gagal render: \(error.localizedDescription)"); print("PREP RENDER ERROR:", error); return
        }

        // 4. Render jawaban tanya-balik.
        //    benefit & proses = teks TETAP → cache permanen (tidak dihapus, tidak generate ulang).
        //    posisi & perusahaan = generate dari JD → render ulang tiap prepare.
        for cat in closingCategories where !fixedAnswerCategories.contains(cat) {
            try? FileManager.default.removeItem(at: answerDir(cat))
        }
        do {
            let answers = await generateClosingAnswers(jobDescription: jobDescription)
            let baseStep = 4 + numQuestions
            for (ci, cat) in closingCategories.enumerated() {
                markStep(baseStep + ci, .active)
                // benefit & proses: pakai teks tetap, dan lewati kalau sudah ada di cache
                let isFixed = fixedAnswerCategories.contains(cat)
                if isFixed, loadSaved(answerDir(cat)) != nil {
                    markStep(baseStep + ci, .done); continue
                }
                stage = .rendering("Menyiapkan jawaban: \(cat)…")
                var text: String
                switch cat {
                case "benefit": text = benefitAnswerText
                case "proses":  text = prosesAnswerText
                default:        text = answers[cat] ?? defaultAnswer(cat)
                }
                text += answerFollowUpPrompt   // penutup: tawarkan bertanya lagi
                let wav = try await fetchTTSWav(text: text)
                _ = try await renderToFiles(audio: wav, dir: answerDir(cat))
                markStep(baseStep + ci, .done)
            }
        } catch {
            stage = .failed("Gagal render jawaban: \(error.localizedDescription)"); return
        }

        stage = .ready
    }

    // MARK: - Jawaban tanya-balik (pre-render)

    /// Generate 4 jawaban tanya-balik sekaligus dari JD (satu panggilan LLM).
    private func generateClosingAnswers(jobDescription: String) async -> [String: String] {
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
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": "JOB DESCRIPTION:\n\(jobDescription)"]],
                temperature: 0.5, numPredict: 700) else { return [:] }
        var out: [String: String] = [:]
        for cat in closingCategories {
            if let t = json[cat]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                out[cat] = t
            }
        }
        return out
    }

    private func defaultAnswer(_ cat: String) -> String {
        switch cat {
        case "posisi":     return "Posisi ini fokus pada tanggung jawab inti sesuai deskripsi pekerjaan, dan kami mencari kandidat yang antusias berkembang bersama tim."
        case "perusahaan": return "Kami menjunjung budaya kerja kolaboratif, saling mendukung, dan terbuka pada ide baru dari setiap anggota tim."
        case "benefit":    return "Kami menyediakan paket kompensasi yang kompetitif beserta tunjangan kesehatan dan kesempatan pengembangan diri."
        case "proses":     return "Setelah sesi ini, tim kami akan meninjau dan menghubungi Anda mengenai tahap berikutnya dalam beberapa hari ke depan."
        default:           return "Terima kasih atas pertanyaannya."
        }
    }

    /// Classify pertanyaan kandidat ke salah satu kategori.
    func classifyClosingCategory(_ question: String) async -> String {
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
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": question]],
                temperature: 0.0, numPredict: 10)
            let c = content.lowercased()
            for cat in closingCategories where c.contains(cat) { return cat }
            return "proses"   // default terdekat kalau tidak jelas
        } catch { return "proses" }
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

    /// Panaskan worker RunPod di background (tanpa blokir) supaya follow-up pertama tak kena cold start.
    func warmUpRunpodIfNeeded() {
        guard followUpEnabled else { return }
        // Task biasa (tetap di MainActor, tapi URLSession async → tak memblokir UI).
        Task { [weak self] in
            guard let self else { return }
            let payload = TTSPayload(
                text: "Halo", emotion: "calm", voice: "male_40s",
                cfg_value: 2.5, inference_timesteps: 6, max_tokens: 200, warmup_patches: 2)
            _ = try? await self.fetchRunpodWav(payload: payload)
        }
    }

        // MARK: - Follow-up question (on-demand, hanya jika followUpEnabled)

    /// Buat 1 pertanyaan pendalaman SINGKAT dari jawaban user. Kosong = tak perlu follow-up.
    func generateFollowUp(question: String, answer: String) async -> String {
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
                messages: [["role": "system", "content": system], ["role": "user", "content": user]],
                temperature: 0.4, numPredict: 80)
            let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.uppercased().contains("SKIP") || t.isEmpty { return "" }
            return t
        } catch { return "" }
    }

    /// Render follow-up jadi video (TTS via RunPod bila aktif + lip-sync lokal).
    func renderFollowUp(text: String) async -> [URL]? {
        let dir = outputsRoot.appendingPathComponent("followup_\(UUID().uuidString.prefix(8))")
        do {
            let wav = try await fetchTTSWav(text: text, useCloud: followUpEnabled)
            return try await renderToFiles(audio: wav, dir: dir)
        } catch { return nil }
    }

    // MARK: - Closing intent + Feedback

    /// true = kandidat "sudah cukup / tidak ada pertanyaan" (decline)
    func classifyDecline(_ answer: String) async -> Bool {
        // Heuristik cepat dulu: kalau ada tanda tanya atau kata tanya, hampir pasti BERTANYA.
        let a = answer.lowercased()
        let tanya = ["?", "apa", "apakah", "bagaimana", "gimana", "berapa", "kapan",
                     "kenapa", "mengapa", "siapa", "boleh saya tahu", "bisa dijelaskan",
                     "ingin tahu", "mau tanya", "izin bertanya"]
        if tanya.contains(where: { a.contains($0) }) { return false }

        // Heuristik decline: frasa penutup yang jelas.
        let cukup = ["tidak ada", "gak ada", "nggak ada", "cukup", "sudah cukup",
                     "tidak", "sekian", "terima kasih saja", "no", "sudah jelas"]
        let looksDecline = cukup.contains(where: { a.contains($0) })

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
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": answer]],
                temperature: 0.0, numPredict: 5)
            let out = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Decline HANYA kalau LLM tegas bilang decline. Ragu → bertanya (lebih aman).
            if out.hasPrefix("decline") { return true }
            if out.hasPrefix("question") { return false }
            // Output tak jelas → pakai heuristik frasa.
            return looksDecline
        } catch { return looksDecline }
    }

    let maxClosingQA = 3

    /// Interviewer menjawab pertanyaan balik kandidat (teks).
    func generateClosingAnswer(candidateQuestion: String, remaining: Int) async -> String {
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
                messages: [["role": "system", "content": system],
                           ["role": "user", "content": "Pertanyaan kandidat: \(candidateQuestion)"]],
                temperature: 0.5, numPredict: 150)
            let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "Terima kasih atas pertanyaannya! Kami akan menjelaskan lebih lanjut saat onboarding." : t
        } catch {
            return "Terima kasih atas pertanyaannya! Kami akan menjelaskan lebih lanjut saat onboarding."
        }
    }

    /// Render sebuah teks jadi video+audio ke folder sementara (untuk jawaban tanya-balik).
    func renderAnswer(text: String) async -> [URL]? {
        let dir = outputsRoot.appendingPathComponent("closing_answer_\(UUID().uuidString.prefix(8))")
        do {
            let wav = try await fetchTTSWav(text: text)
            return try await renderToFiles(audio: wav, dir: dir)
        } catch { return nil }
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

    struct TTSPayload: Encodable {
        let text, emotion, voice: String
        let cfg_value: Double
        let inference_timesteps, max_tokens, warmup_patches: Int
    }

    /// TTS lokal (8808). useCloud=true → lewat RunPod (untuk follow-up cepat).
    private func fetchTTSWav(text: String, useCloud: Bool = false) async throws -> Data {
        let payload = TTSPayload(
            text: text, emotion: "calm, professional", voice: "male_40s",
            cfg_value: 2.5, inference_timesteps: 10, max_tokens: 1200, warmup_patches: 2)
        if useCloud { return try await fetchRunpodWav(payload: payload) }

        var req = URLRequest(url: URL(string: ttsURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: "TTS error (8808?)"])
        }
        return data
    }

    /// RunPod serverless VoxCPM2: enqueue → poll status → decode base64 WAV.
    private func fetchRunpodWav(payload: TTSPayload) async throws -> Data {
        struct Body: Encodable { let input: TTSPayload }
        struct RunResp: Decodable { let id: String }
        struct StatusResp: Decodable {
            let status: String
            let output: Output?
            struct Output: Decodable { let audio_b64: String?; let error: String? }
        }
        let ep = runpodEndpoint.trimmingCharacters(in: .whitespaces)
        let key = runpodKey.trimmingCharacters(in: .whitespaces)
        guard !ep.isEmpty, !key.isEmpty else {
            throw NSError(domain: "RunPod", code: 1, userInfo: [NSLocalizedDescriptionKey: "RunPod endpoint/key kosong"])
        }
        let base = "https://api.runpod.ai/v2/\(ep)"
        var req = URLRequest(url: URL(string: "\(base)/run")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(input: payload))
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "RunPod", code: 2, userInfo: [NSLocalizedDescriptionKey: "RunPod /run gagal"])
        }
        print("RUNPOD /run response:", String(data: data, encoding: .utf8) ?? "nil")
        let job = try JSONDecoder().decode(RunResp.self, from: data)
        print("RUNPOD job id:", job.id)
        let statusURL = URL(string: "\(base)/status/\(job.id)")!
        let deadline = Date().addingTimeInterval(300)
        var pollCount = 0
        while Date() < deadline {
            var sreq = URLRequest(url: statusURL)
            sreq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (sdata, _) = try await URLSession.shared.data(for: sreq)
            pollCount += 1
            print("RUNPOD poll #\(pollCount):", String(data: sdata, encoding: .utf8)?.prefix(300) ?? "nil")
            let st = try JSONDecoder().decode(StatusResp.self, from: sdata)
            switch st.status {
            case "COMPLETED":
                guard let b64 = st.output?.audio_b64, let wav = Data(base64Encoded: b64) else {
                    throw NSError(domain: "RunPod", code: 3, userInfo: [NSLocalizedDescriptionKey: st.output?.error ?? "RunPod tanpa audio"])
                }
                return wav
            case "FAILED", "CANCELLED", "TIMED_OUT":
                throw NSError(domain: "RunPod", code: 4, userInfo: [NSLocalizedDescriptionKey: "RunPod job \(st.status)"])
            default:
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw NSError(domain: "RunPod", code: 5, userInfo: [NSLocalizedDescriptionKey: "RunPod timeout"])
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
