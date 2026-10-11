//
//  AudioRecorder.swift
//  AudioCombineApp
//
//  Records microphone input to a 16kHz mono WAV file for Whisper.
//  A fresh AVAudioEngine is created on every start() call to avoid
//  stale device state from a previous recording session.
//

import Foundation
import AVFoundation
import Combine

final class AudioRecorder: ObservableObject {

    @Published var isRecording = false
    @Published var level: Double = 0
    @Published var elapsed: Double = 0

    private var engine = AVAudioEngine()
    private var outFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var startTime: Date?
    private var timer: Timer?

    let sampleRate: Double = 16_000
    private(set) var currentURL: URL?

    // MARK: - Permission

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            print("[AudioRecorder] Mic permission denied — check System Settings > Privacy > Microphone")
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Recording

    func start() throws {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }

        // Small safety margin. TTS playback is handled entirely by the
        // Python server (via afplay), so this app never touches the output
        // device — this delay is just a courtesy buffer, not load-bearing.
        Thread.sleep(forTimeInterval: 0.2)

        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Input device not ready (invalid format)"])
        }

        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate,
                                          channels: 1,
                                          interleaved: false) else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create 16kHz target format"])
        }
        targetFormat = target
        converter = AVAudioConverter(from: inputFormat, to: target)

        let url = Self.newRecordingURL()
        currentURL = url

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        outFile = try AVAudioFile(forWriting: url, settings: fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        try engine.start()

        startTime = Date()
        publish { self.isRecording = true }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let start = self.startTime else { return }
            self.publish { self.elapsed = Date().timeIntervalSince(start) }
        }

        print("[AudioRecorder] Recording started → \(url.lastPathComponent)")
    }

    func stop() -> URL? {
        guard isRecording else { return currentURL }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate()
        timer = nil

        let frames = outFile?.length ?? 0
        outFile = nil
        publish { self.isRecording = false; self.level = 0 }

        print("[AudioRecorder] Recording stopped — \(frames) frames (\(String(format: "%.2f", Double(frames) / sampleRate))s)")
        return currentURL
    }

    // MARK: - Buffer processing

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || outBuffer.frameLength == 0 { return }

        try? outFile?.write(from: outBuffer)

        if let ch = outBuffer.floatChannelData?[0] {
            let n = Int(outBuffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            let scaled = min(1.0, Double(rms) * 6.0)
            publish { self.level = self.level * 0.6 + scaled * 0.4 }
        }
    }

    // MARK: - Helpers

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    static func recordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = docs
            .appendingPathComponent("AudioCombineApp", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func newRecordingURL() -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return recordingsDirectory().appendingPathComponent("rec_\(fmt.string(from: Date())).wav")
    }
}
