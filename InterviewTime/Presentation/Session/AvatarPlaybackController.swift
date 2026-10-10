//
//  AvatarPlaybackController.swift
//  InterviewTime
//

import AVFoundation
import AppKit
import Combine

@MainActor
final class AvatarPlaybackController: ObservableObject {
    @Published var player: AVQueuePlayer?
    @Published var idleLoopPlayer: AVQueuePlayer?
    @Published var previousIdleLoopPlayer: AVQueuePlayer?
    @Published var idleLoopVisible = false
    @Published var isTalking = false

    private var idleLooper: AVPlayerLooper?
    private var currentIdleLoopURL: URL?
    private var idleReadyObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var startedPlayback = false
    private var generationDone = false
    private var outputsRoot: URL?

    init() {}

    deinit {
        // Clean up any remaining observers and audio/video players
        idleReadyObserver?.invalidate()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func stopAndCleanUp() {
        idleReadyObserver?.invalidate()
        idleReadyObserver = nil

        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }

        player?.pause()
        player = nil

        idleLoopPlayer?.pause()
        idleLoopPlayer = nil

        previousIdleLoopPlayer?.pause()
        previousIdleLoopPlayer = nil

        idleLooper = nil
        isTalking = false
        idleLoopVisible = false
        startedPlayback = false
        generationDone = false
    }

    // MARK: - Talking playback

    func playItems(_ urls: [URL]) {
        beginTalkingSession()
        let tmpItems = urls.map { AVPlayerItem(url: $0) }
        for it in tmpItems {
            enqueue(it)
        }
        generationDone = true
        if !startedPlayback {
            returnToIdle()
        }
    }

    private func beginTalkingSession() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player?.pause()
        player = nil
        startedPlayback = false
        generationDone = false
    }

    private func enqueue(_ item: AVPlayerItem) {
        if !startedPlayback {
            let q = AVQueuePlayer(playerItem: item)
            q.actionAtItemEnd = .advance
            player = q
            startedPlayback = true
            isTalking = true
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                guard let ended = note.object as? AVPlayerItem,
                      let url = (ended.asset as? AVURLAsset)?.url,
                      url.lastPathComponent.hasPrefix("seg_") else { return }
                if self.generationDone, (self.player?.items().count ?? 0) <= 1 {
                    self.returnToIdle()
                }
            }
            q.play()
        } else {
            player?.insert(item, after: nil)
        }
    }

    func returnToIdle() {
        isTalking = false
        idleLoopPlayer?.seek(to: .zero)
        switchIdleLoop()
    }

    // MARK: - Idle Loop

    func startInitialIdleLoop(outputsRoot: URL) {
        self.outputsRoot = outputsRoot
        if let loop2 = idleLoopURLs().first(where: { $0.lastPathComponent.contains("loop2") }) {
            playIdleLoop(loop2)
        } else {
            switchIdleLoop()
        }
    }

    private func idleLoopURLs() -> [URL] {
        guard let dir = outputsRoot else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("idle_loop") && $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func switchIdleLoop() {
        let candidates = idleLoopURLs()
        guard !candidates.isEmpty else { return }
        // idle_loop2 difavoritkan 6:1
        let weighted = candidates.flatMap { url in
            Array(repeating: url, count: url.lastPathComponent.contains("loop2") ? 6 : 1)
        }
        guard let next = weighted.randomElement() else { return }
        guard next != currentIdleLoopURL || idleLoopPlayer == nil else { return }
        playIdleLoop(next)
    }

    private func playIdleLoop(_ url: URL) {
        let p = AVQueuePlayer()
        p.isMuted = true
        let template = AVPlayerItem(url: url)
        let looper = AVPlayerLooper(player: p, templateItem: template)

        idleReadyObserver?.invalidate()
        idleReadyObserver = p.observe(\.currentItem?.status, options: [.new, .initial]) { [weak self] pl, _ in
            guard pl.currentItem?.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.previousIdleLoopPlayer = self.idleLoopPlayer
                self.currentIdleLoopURL = url
                self.idleLooper = looper
                self.idleLoopVisible = false
                self.idleLoopPlayer = p
                p.play()
                DispatchQueue.main.async { self.idleLoopVisible = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.previousIdleLoopPlayer = nil
                }
            }
        }
    }
}
