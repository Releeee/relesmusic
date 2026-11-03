import AVFoundation
import MediaPlayer
import UIKit

/// Reproductor con cola, segundo plano y controles en pantalla de bloqueo.
@MainActor
final class Player: ObservableObject {
    enum RepeatMode { case off, all, one }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var shuffle = false
    @Published var repeatMode: RepeatMode = .off
    @Published var errorMessage: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var originalQueue: [Track] = []
    private var urlCache: [String: (url: URL, date: Date)] = [:]
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var failuresInARow = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.tick(time) }
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.trackEnded() }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let typeRaw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            Task { @MainActor in self?.handleInterruption(type, shouldResume: shouldResume) }
        }

        setupRemoteCommands()
    }

    // MARK: Control

    func play(_ tracks: [Track], startAt i: Int = 0) {
        guard tracks.indices.contains(i) else { return }
        originalQueue = tracks
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: i)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = i
        }
        failuresInARow = 0
        load()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffle = true
        play(tracks, startAt: Int.random(in: 0..<tracks.count))
    }

    func playNext(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.insert(track, at: index + 1)
        originalQueue.append(track)
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
    }

    func toggleShuffle() {
        shuffle.toggle()
        guard let cur = current else { return }
        if shuffle {
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        } else {
            queue = originalQueue
            index = originalQueue.firstIndex(of: cur) ?? 0
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func togglePlay() {
        isPlaying ? pause() : resume()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard player.currentItem != nil else { load(); return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count {
            index += 1
        } else if repeatMode == .all {
            index = 0
        } else {
            pause()
            seek(to: 0)
            return
        }
        load()
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            load()
        }
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlaying()
    }

    // MARK: Carga

    private func load() {
        guard let track = current else { return }
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isLoading = true
        currentTime = 0
        duration = 0
        errorMessage = nil
        artwork = nil
        updateNowPlaying()
        loadArtwork(for: track)

        // Pide tiempo extra a iOS para poder cargar la siguiente con la pantalla apagada
        beginBackgroundWork()

        loadTask = Task {
            do {
                let url = try await resolve(track.id)
                guard !Task.isCancelled, current?.id == track.id else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.play()
                isPlaying = true
                isLoading = false
                failuresInARow = 0
                updateNowPlaying()
                prefetchNext()
                endBackgroundWork()
            } catch {
                guard !Task.isCancelled, current?.id == track.id else { return }
                endBackgroundWork()
                isLoading = false
                errorMessage = "No se pudo reproducir «\(track.title)»"
                failuresInARow += 1
                if failuresInARow < 5, index + 1 < queue.count {
                    next()
                } else {
                    isPlaying = false
                    updateNowPlaying()
                }
            }
        }
    }

    private func beginBackgroundWork() {
        endBackgroundWork()
        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundWork() }
        }
    }

    private func endBackgroundWork() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func resolve(_ id: String) async throws -> URL {
        // Los enlaces de YouTube caducan a las ~6 h
        if let cached = urlCache[id], Date().timeIntervalSince(cached.date) < 3 * 3600 {
            return cached.url
        }
        let url = try await YouTubeService.audioURL(for: id)
        urlCache[id] = (url: url, date: Date())
        return url
    }

    private func prefetchNext() {
        guard index + 1 < queue.count else { return }
        let id = queue[index + 1].id
        Task { _ = try? await resolve(id) }
    }

    private func trackEnded() {
        if repeatMode == .one {
            seek(to: 0)
            player.play()
        } else {
            next()
        }
    }

    private func tick(_ time: CMTime) {
        currentTime = time.seconds.isFinite ? time.seconds : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, d != duration {
            duration = d
            updateNowPlaying()
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool) {
        switch type {
        case .began:
            isPlaying = false
            updateNowPlaying()
        case .ended:
            if shouldResume { resume() }
        @unknown default:
            break
        }
    }

    // MARK: Pantalla de bloqueo

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for track: Track) {
        guard let url = track.thumbnailURL else { return }
        Task {
            guard let result = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: result.0).map(Self.squareCrop),
                  current?.id == track.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }

    /// Las miniaturas de YouTube son 4:3 con franjas negras; recorta el centro cuadrado.
    private static func squareCrop(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let side = min(h, w * 9 / 16)
        let rect = CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: rect) else { return image }
        return UIImage(cgImage: cropped)
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}
