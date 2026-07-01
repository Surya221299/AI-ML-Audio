//
//  SimpleTTSService.swift
//  InterviewTime
//

import AVFoundation
import Combine
import Foundation

// MARK: - Service

struct SimpleTTSGenerationOptions: Equatable {
    var cfgValue: Double
    var inferenceTimesteps: Int
    var maxTokens: Int
    var warmupPatches: Int

    static let fastBalanced = SimpleTTSGenerationOptions(
        cfgValue: 2.0,
        inferenceTimesteps: 4,
        maxTokens: 2000,
        warmupPatches: 0
    )
}

@MainActor
final class SimpleTTSService: ObservableObject {
    enum State: Equatable {
        case idle
        case generating
        case generatingVideo
        case ready(elapsed: Double, duration: Double)
        case playing(elapsed: Double, duration: Double)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var elapsedSeconds: Double = 0
    @Published var latestVideoPath: String?
    @Published var mouthOpenness: Double = 0   // 0…1 driven by live audio loudness

    private let streamURL = URL(string: "http://127.0.0.1:8808/speak_stream")!
    private let speakURL  = URL(string: "http://127.0.0.1:8808/speak")!

    private var receiver: TTSStreamReceiver?
    private var streamSession: URLSession?
    private var timerTask: Task<Void, Never>?
    private var startTime = Date()
    private var lastText = ""
    private var lastEmotion = ""

    // Cached audio for instant replay
    private var cachedAudioData: Data?
    private var cachedSampleRate: Double = 48000
    private var replayEngine: AVAudioEngine?
    private var replayPlayer: AVAudioPlayerNode?

    func generate(
        text: String,
        emotion: String,
        withVideo: Bool = false,
        options: SimpleTTSGenerationOptions = .fastBalanced
    ) async {
        switch state {
        case .generating, .generatingVideo, .playing: return
        default: break
        }

        cleanup()
        lastText = text
        lastEmotion = emotion
        latestVideoPath = nil
        state = withVideo ? .generatingVideo : .generating
        startTime = Date()
        elapsedSeconds = 0

        if withVideo {
            await generateWithVideo(text: text, emotion: emotion, options: options)
            return
        }

        // Elapsed timer while waiting for first chunk
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.elapsedSeconds = Date().timeIntervalSince(self.startTime)
                }
            }
        }

        let recv = TTSStreamReceiver()
        receiver = recv

        // One-shot signal: fires when audio starts playing or on error
        var signalCont: AsyncStream<Bool>.Continuation?
        let signal = AsyncStream<Bool> { signalCont = $0 }

        recv.onPlaybackStarted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timerTask?.cancel()
                let elapsed = Date().timeIntervalSince(self.startTime)
                self.state = .playing(elapsed: elapsed, duration: 0)
            }
            signalCont?.yield(true)
            signalCont?.finish()
        }
        recv.onAmplitude = { [weak self] v in
            Task { @MainActor [weak self] in self?.mouthOpenness = v }
        }
        recv.onCompleted = { [weak self] duration in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mouthOpenness = 0
                // Cache audio for instant replay
                if let recv = self.receiver {
                    self.cachedAudioData = recv.fullAudioData
                    self.cachedSampleRate = recv.currentSampleRate
                }
                if case .playing(let e, _) = self.state {
                    self.state = .ready(elapsed: e, duration: duration)
                }
                self.streamSession?.finishTasksAndInvalidate()
                self.streamSession = nil
                self.receiver = nil
            }
        }
        recv.onError = { [weak self] err in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.timerTask?.cancel()
                self.mouthOpenness = 0
                self.state = .error(err.localizedDescription)
                self.streamSession?.invalidateAndCancel()
                self.streamSession = nil
                self.receiver = nil
            }
            signalCont?.yield(false)
            signalCont?.finish()
        }

        struct Payload: Encodable {
            let text, emotion: String
            let cfg_value: Double
            let inference_timesteps: Int
            let max_tokens: Int
            let warmup_patches: Int
        }
        var req = URLRequest(url: streamURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try? JSONEncoder().encode(Payload(
            text: text,
            emotion: emotion,
            cfg_value: options.cfgValue,
            inference_timesteps: options.inferenceTimesteps,
            max_tokens: options.maxTokens,
            warmup_patches: options.warmupPatches
        ))

        let session = URLSession(configuration: .default, delegate: recv, delegateQueue: .main)
        streamSession = session
        session.dataTask(with: req).resume()

        // Suspend caller until first audio chunk starts playing (or error)
        for await _ in signal { break }
    }

    /// Replay cached audio instantly (no regeneration).
    func play() {
        guard case .ready(let elapsed, let duration) = state,
              let audioData = cachedAudioData else { return }

        stopReplay()
        state = .playing(elapsed: elapsed, duration: duration)

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: cachedSampleRate,
                                channels: 1,
                                interleaved: false)!
        eng.connect(node, to: eng.mainMixerNode, format: fmt)

        // Amplitude tap for mouth animation
        eng.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms   = Double(sqrt(sum / Float(n)))
            let db    = 20 * log10(max(rms, 1e-6))
            var v     = (db + 40) / 26
            v = db < -42 ? 0 : max(0, min(1, v))
            v = pow(v, 0.8)
            Task { @MainActor [weak self] in self?.mouthOpenness = v }
        }

        try? eng.start()
        replayEngine = eng
        replayPlayer = node

        let frameCount = audioData.count / 4
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                        frameCapacity: AVAudioFrameCount(frameCount))
        else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)
        audioData.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            buf.floatChannelData![0].update(from: ptr, count: frameCount)
        }

        node.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mouthOpenness = 0
                self.stopReplay()
                self.state = .ready(elapsed: elapsed, duration: duration)
            }
        }
        node.play()
    }

    func stop() {
        let (elapsed, duration) = currentMetrics()
        cleanup()
        state = .ready(elapsed: elapsed, duration: duration)
    }

    // MARK: - Private helpers

    private func cleanup() {
        timerTask?.cancel()
        timerTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        receiver?.stop()
        receiver = nil
        stopReplay()
        mouthOpenness = 0
    }

    private func stopReplay() {
        replayPlayer?.stop()
        if let eng = replayEngine {
            eng.mainMixerNode.removeTap(onBus: 0)
            eng.stop()
        }
        replayEngine = nil
        replayPlayer = nil
    }

    private func currentMetrics() -> (Double, Double) {
        switch state {
        case .ready(let e, let d), .playing(let e, let d): return (e, d)
        default: return (0, 0)
        }
    }

    // MARK: - Video generation (non-streaming, unchanged)

    private func generateWithVideo(
        text: String,
        emotion: String,
        options: SimpleTTSGenerationOptions
    ) async {
        struct Payload: Encodable {
            let text, emotion: String
            let generate_video: Bool
            let cfg_value: Double
            let inference_timesteps: Int
            let max_tokens: Int
            let warmup_patches: Int
        }
        var req = URLRequest(url: speakURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        req.httpBody = try? JSONEncoder().encode(
            Payload(
                text: text,
                emotion: emotion,
                generate_video: true,
                cfg_value: options.cfgValue,
                inference_timesteps: options.inferenceTimesteps,
                max_tokens: options.maxTokens,
                warmup_patches: options.warmupPatches
            )
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "server error"
                throw NSError(domain: "TTS", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
            }
            struct Resp: Decodable { let audio: String; let video_path: String? }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            guard let audioBytes = Data(hexString: resp.audio) else {
                throw NSError(domain: "TTS", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid audio data"])
            }
            let elapsed = Date().timeIntervalSince(startTime)
            timerTask?.cancel()
            latestVideoPath = resp.video_path
            let duration = (try? AVAudioPlayer(data: audioBytes))?.duration ?? 0
            state = .ready(elapsed: elapsed, duration: duration)
        } catch {
            timerTask?.cancel()
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Streaming audio receiver

private final class TTSStreamReceiver: NSObject, URLSessionDataDelegate {
    var onPlaybackStarted: (() -> Void)?
    var onAmplitude:       ((Double) -> Void)?
    var onCompleted:       ((Double) -> Void)?   // passes total audio duration in seconds
    var onError:           ((Error) -> Void)?

    /// All raw float32 PCM bytes accumulated during this stream (for replay caching).
    private(set) var fullAudioData = Data()
    var currentSampleRate: Double { sampleRate }

    private var headerBuf  = Data()
    private var audioBuf   = Data()
    private var headerDone = false
    private var playing    = false
    private var sampleRate: Double = 48000
    private var totalFrames = 0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var isStopped = false

    // 8192 float32 frames = ~170ms @ 48 kHz — stable playback buffer
    private let framesPerBuffer = 8192

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !isStopped else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            onError?(NSError(domain: "TTS", code: code,
                             userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) from TTS server"]))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard !isStopped else { return }
        if !headerDone {
            headerBuf.append(data)
            guard headerBuf.count >= 8 else { return }
            sampleRate = Double(headerBuf.prefix(4).withUnsafeBytes {
                $0.load(as: UInt32.self).littleEndian
            })
            headerDone = true
            setupAudio()
            let tail = headerBuf.dropFirst(8)
            if !tail.isEmpty { drain(tail) }
        } else {
            drain(data)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !isStopped else { return }
        if let err = error as? URLError, err.code == .cancelled { return }
        if let err = error { onError?(err); return }

        // Flush any remaining bytes smaller than framesPerBuffer
        if !audioBuf.isEmpty {
            let last = audioBuf; audioBuf = Data()
            let frames = last.count / 4
            totalFrames += frames
            schedule(last, isLast: true)
        } else {
            if !playing {
                // Completed normally but never started playing (e.g. backend failed to yield audio)
                onError?(NSError(domain: "TTS", code: 0,
                                 userInfo: [NSLocalizedDescriptionKey: "No audio data received from server"]))
            } else {
                // All chunks already scheduled — fire sentinel with accumulated duration
                scheduleCompletionSentinel()
            }
        }
    }

    // MARK: Private

    private func setupAudio() {
        let eng  = AVAudioEngine()
        let node = AVAudioPlayerNode()
        eng.attach(node)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: sampleRate,
                                channels: 1,
                                interleaved: false)!
        eng.connect(node, to: eng.mainMixerNode, format: fmt)
        // Tap on mixer output for amplitude monitoring (~60 Hz @ 512 frames)
        eng.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buf, _ in
            Task { @MainActor [weak self] in
                self?.measure(buf)
            }
        }
        try? eng.start()
        engine = eng; player = node; format = fmt
    }

    private func drain(_ data: Data) {
        audioBuf.append(data)
        fullAudioData.append(data)   // cache for replay
        let stride = framesPerBuffer * 4
        while audioBuf.count >= stride {
            let chunk = Data(audioBuf.prefix(stride))
            audioBuf.removeFirst(stride)
            totalFrames += framesPerBuffer
            schedule(chunk)
        }
    }

    private func schedule(_ data: Data, isLast: Bool = false) {
        guard let player, let format else { return }
        let n = data.count / 4
        guard n > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))
        else { return }
        buf.frameLength = AVAudioFrameCount(n)
        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            buf.floatChannelData![0].update(from: ptr, count: n)
        }
        if isLast {
            let dur = Double(totalFrames) / sampleRate
            player.scheduleBuffer(buf) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.onCompleted?(dur)
                }
            }
        } else {
            player.scheduleBuffer(buf)
        }
        if !playing {
            player.play()
            playing = true
            onPlaybackStarted?()
        }
    }

    private func scheduleCompletionSentinel() {
        let dur = Double(totalFrames) / sampleRate
        guard let player, let format,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)
        else { onCompleted?(dur); return }
        buf.frameLength = 1
        buf.floatChannelData![0][0] = 0
        player.scheduleBuffer(buf) { [weak self] in
            Task { @MainActor [weak self] in
                self?.onCompleted?(dur)
            }
        }
    }

    private func measure(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms   = Double(sqrt(sum / Float(n)))
        let db    = 20 * log10(max(rms, 1e-6))
        var v     = (db + 40) / 26              // -40 dB→0, -14 dB→1
        v = db < -42 ? 0 : max(0, min(1, v))   // gate silence
        v = pow(v, 0.8)                         // emphasise variation
        onAmplitude?(v)
    }

    func stop() {
        isStopped = true
        player?.stop()
        engine?.mainMixerNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        player = nil
    }
}

// MARK: - Hex decoding helper

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            guard let b = UInt8(hexString[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        self = data
    }
}
