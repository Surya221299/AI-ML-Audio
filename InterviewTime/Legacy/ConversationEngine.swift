//
//  ConversationEngine.swift
//  InterviewTime
//
//  Orkestrasi: rekam → STT (WhisperKit) → LLM (Ollama) → set text → avatar bicara.
//  Avatar (TTS 8808 + lip-sync 8810) tetap ditangani MuseTalkView lewat closure.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ConversationEngine: ObservableObject {
    @Published var status = "Siap"
    @Published var userText = ""
    @Published var aiText = ""
    @Published var isBusy = false
    @Published var modelReady = false

    private let whisper = WhisperService()
    private let recorder = AudioRecorder()
    private let ollama = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!)

    private let model = "llama3.1:8b"
    private var history: [[String: String]] = [
        ["role": "system",
         "content": "Kamu pewawancara kerja profesional berbahasa Indonesia. "
         + "Ajukan satu pertanyaan wawancara singkat dan jelas setiap giliran. "
         + "Tanggapi jawaban kandidat lalu lanjut ke pertanyaan berikutnya. Jawab ringkas."]
    ]

    /// Dipanggil MuseTalkView; menyerahkan teks AI untuk diucapkan avatar.
    var onSpeak: ((String) async -> Void)?

    func prepare() async {
        status = "Memuat model STT…"
        await whisper.loadModel()
        modelReady = whisper.isReady
        status = whisper.isReady ? "Model siap. Tekan Mulai Bicara." : "STT gagal: \(whisper.status)"
    }

    func toggleRecording() async {
        if recorder.isRecording {
            await stopAndProcess()
        } else {
            guard await recorder.requestPermission() else { status = "Izin mikrofon ditolak"; return }
            do { try recorder.start(); status = "Merekam… bicara lalu tekan Stop." }
            catch { status = "Gagal rekam: \(error.localizedDescription)" }
        }
    }

    var isRecording: Bool { recorder.isRecording }

    private func stopAndProcess() async {
        guard let url = recorder.stop() else { status = "Rekaman gagal"; return }
        isBusy = true
        defer { isBusy = false }

        // 1. STT
        status = "Transcribing…"
        do {
            let stt = try await whisper.transcribe(url: url)
            userText = stt.text
            guard !stt.text.trimmingCharacters(in: .whitespaces).isEmpty else {
                status = "Tidak ada suara terdeteksi"; return
            }
        } catch {
            status = "STT error: \(error.localizedDescription)"; return
        }

        // 2. LLM
        status = "Berpikir (LLM)…"
        history.append(["role": "user", "content": userText])
        do {
            let (content, _) = try await ollama.chat(model: model, messages: history)
            aiText = content
            history.append(["role": "assistant", "content": content])
        } catch {
            status = "LLM error: \(error.localizedDescription)"; return
        }

        // 3. Avatar bicara
        status = "Pewawancara menjawab…"
        await onSpeak?(aiText)
        status = "Giliranmu — tekan Mulai Bicara."
    }
}
