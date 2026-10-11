//
//  STTTestView.swift
//  InterviewTime
//
//  Tahap 2: uji STT (WhisperKit) berdiri sendiri.
//  Rekam suara → transcribe → tampilkan teks. Belum tersambung ke avatar.
//

import SwiftUI

struct STTTestView: View {
    @StateObject private var whisper = WhisperService()
    @StateObject private var recorder = AudioRecorder()

    @State private var transcript = ""
    @State private var status = "Tekan 'Muat Model' dulu"
    @State private var isTranscribing = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Uji STT (WhisperKit)")
                .font(.title2).bold()

            Text(status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // 1. Muat model
            Button("Muat Model Whisper") {
                Task {
                    status = "Memuat model…"
                    await whisper.loadModel()
                    status = whisper.status
                }
            }
            .disabled(whisper.isLoading || whisper.isReady)

            // 2. Rekam / stop
            if whisper.isReady {
                Button(recorder.isRecording ? "⏹ Stop & Transcribe" : "🎙 Mulai Rekam") {
                    Task { await toggleRecord() }
                }
                .disabled(isTranscribing)

                if recorder.isRecording {
                    Text(String(format: "Merekam… %.1fs  level %.2f",
                                recorder.elapsed, recorder.level))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            // 3. Hasil
            if isTranscribing {
                ProgressView("Transcribing…")
            }

            ScrollView {
                Text(transcript.isEmpty ? "(hasil transcribe muncul di sini)" : transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            .frame(height: 150)
        }
        .padding(30)
        .frame(minWidth: 400, minHeight: 450)
    }

    private func toggleRecord() async {
        if recorder.isRecording {
            // Stop → transcribe
            guard let url = recorder.stop() else {
                status = "Gagal menyimpan rekaman"
                return
            }
            status = "Rekaman tersimpan, transcribing…"
            isTranscribing = true
            defer { isTranscribing = false }
            do {
                let result = try await whisper.transcribe(url: url)
                transcript = result.text
                status = String(format: "Selesai — %d kata, RTF %.2f",
                                result.words.count, result.realTimeFactor)
            } catch {
                status = "Error transcribe: \(error.localizedDescription)"
            }
        } else {
            // Start recording
            guard await recorder.requestPermission() else {
                status = "Izin mikrofon ditolak"
                return
            }
            do {
                try recorder.start()
                status = "Merekam… bicara sekarang, lalu tekan Stop"
            } catch {
                status = "Gagal mulai rekam: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    STTTestView()
}
