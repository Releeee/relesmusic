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
    /// Diagnóstico de velocidad de la última canción (se muestra en la pantalla del reproductor).
    @Published private(set) var loadInfo: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    private let player = AVPlayer()
    private var originalQueue: [Track] = []
    private var urlCache: [String: (url: URL, date: Date)] = [:]
    private var inflight: [String: Task<URL, Error>] = [:]
    private var visibleQueue: [String] = []   // canciones en pantalla (la última vista va primero)
    private var upcomingQueue: [String] = []  // próximas de la cola, en orden
    private var preparing = Set<String>()
    private var activePrefetches = 0
    private static let maxPrefetches = 1      // de una en una, para no frenar la canción que pulsas
    private static let upcomingCount = 15     // no más, para no gastar datos de golpe
    private var artwork: MPMediaItemArtwork?
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var loadStarted: Date?
    private var linkSeconds: Double = 0
    private var failuresInARow = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private static let cacheKey = "urlCache"
    private static let cacheLifetime: TimeInterval = 3 * 3600 // los enlaces de YouTube caducan a las ~6 h

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        loadCache()
        // Empieza a sonar en cuanto hay algo de audio, sin esperar a llenar mucho búfer
        player.automaticallyWaitsToMinimizeStalling = false

        playbackObservation = player.observe(\.timeControlStatus) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in self?.markStartedPlaying() }
        }

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
        prepareUpcoming()
    }

    func addToQueue(_ track: Track) {
        guard current != nil else { play([track]); return }
        queue.append(track)
        originalQueue.append(track)
        prepareUpcoming()
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
        prepareUpcoming()
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

    private func load(fresh: Bool = false) {
        guard let track = current else { return }
        if fresh { urlCache[track.id] = nil }
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isLoading = true
        currentTime = 0
        duration = 0
        errorMessage = nil
        artwork = nil
        loadInfo = nil
        let started = Date()
        loadStarted = started
        updateNowPlaying()
        loadArtwork(for: track)

        // Pide tiempo extra a iOS para poder cargar la siguiente con la pantalla apagada
        beginBackgroundWork()

        loadTask = Task {
            do {
                let url = try await resolve(track.id)
                guard !Task.isCancelled, current?.id == track.id else { return }
                linkSeconds = Date().timeIntervalSince(started)
                try? AVAudioSession.sharedInstance().setActive(true)
                let item = AVPlayerItem(url: url)
                watchForFailure(item, track: track, retried: fresh)
                player.replaceCurrentItem(with: item)
                player.play()
                isPlaying = true
                isLoading = false
                failuresInARow = 0
                updateNowPlaying()
                prepareUpcoming()
                endBackgroundWork()
            } catch {
                guard !Task.isCancelled, current?.id == track.id else { return }
                endBackgroundWork()
                isLoading = false
                runPrefetches()
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

    /// Apunta cuánto tardó en conseguir el enlace y en empezar a sonar.
    private func markStartedPlaying() {
        guard let started = loadStarted, player.currentItem != nil else { return }
        loadStarted = nil
        let total = Date().timeIntervalSince(started)
        loadInfo = String(format: "Enlace: %.1f s · Sonando a los %.1f s", linkSeconds, total)
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
        if isCached(id), let cached = urlCache[id] { return cached.url }
        // Si ya se está preparando (precarga), espera a esa misma búsqueda
        if let task = inflight[id] { return try await task.value }
        let task = Task { try await YouTubeService.audioURL(for: id) }
        inflight[id] = task
        defer { inflight[id] = nil }
        let url = try await task.value
        urlCache[id] = (url: url, date: Date())
        saveCache()
        return url
    }

    /// Prepara una canción que está en pantalla para que suene al instante al tocarla.
    /// Se atienden primero las últimas que han aparecido (las que estás viendo ahora).
    func prepare(_ track: Track) {
        let id = track.id
        guard needsPreparing(id), !visibleQueue.contains(id) else { return }
        visibleQueue.append(id)
        if visibleQueue.count > 30 { visibleQueue.removeFirst() }
        runPrefetches()
    }

    func prefetch(_ tracks: [Track], limit: Int = 3) {
        for track in tracks.prefix(limit).reversed() { prepare(track) }
    }

    /// Prepara en orden las próximas canciones de la cola (y la anterior), para que
    /// siguiente/anterior suenen al momento. Se rellena cada vez que cambia de canción.
    private func prepareUpcoming() {
        guard !queue.isEmpty else { return }
        var ids = queue[(index + 1)...].prefix(Self.upcomingCount).map(\.id)
        if repeatMode == .all, ids.count < Self.upcomingCount {
            ids += queue.prefix(min(index, Self.upcomingCount - ids.count)).map(\.id)
        }
        if index > 0 { ids.append(queue[index - 1].id) }
        upcomingQueue = ids.filter { needsPreparing($0) }
        runPrefetches()
    }

    private func runPrefetches() {
        // Mientras carga la canción que has pulsado, no se empieza a preparar ninguna otra
        while !isLoading, activePrefetches < Self.maxPrefetches, let id = nextToPrepare() {
            activePrefetches += 1
            preparing.insert(id)
            Task {
                _ = try? await resolve(id)
                preparing.remove(id)
                activePrefetches -= 1
                runPrefetches()
            }
        }
    }

    /// Primero lo que estás viendo en pantalla; después, lo que viene en la cola.
    private func nextToPrepare() -> String? {
        while let id = visibleQueue.popLast() {
            if needsPreparing(id) { return id }
        }
        while !upcomingQueue.isEmpty {
            let id = upcomingQueue.removeFirst()
            if needsPreparing(id) { return id }
        }
        return nil
    }

    private func needsPreparing(_ id: String) -> Bool {
        !isCached(id) && inflight[id] == nil && !preparing.contains(id)
    }

    private func isCached(_ id: String) -> Bool {
        guard let cached = urlCache[id] else { return false }
        return Date().timeIntervalSince(cached.date) < Self.cacheLifetime
    }

    /// Si el enlace guardado ya no vale (caducado o cambiaste de wifi a datos), pide uno nuevo una vez.
    private func watchForFailure(_ item: AVPlayerItem, track: Track, retried: Bool) {
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.current?.id == track.id else { return }
                if retried {
                    self.isPlaying = false
                    self.errorMessage = "No se pudo reproducir «\(track.title)»"
                    self.updateNowPlaying()
                } else {
                    self.load(fresh: true)
                }
            }
        }
    }

    private func loadCache() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.cacheKey) else { return }
        for (id, value) in raw {
            guard let entry = value as? [String: Any],
                  let string = entry["url"] as? String, let url = URL(string: string),
                  let date = entry["date"] as? Date,
                  Date().timeIntervalSince(date) < Self.cacheLifetime else { continue }
            urlCache[id] = (url: url, date: date)
        }
    }

    private func saveCache() {
        let fresh = urlCache.filter { Date().timeIntervalSince($0.value.date) < Self.cacheLifetime }
        let raw = fresh.mapValues { ["url": $0.url.absoluteString, "date": $0.date] as [String: Any] }
        UserDefaults.standard.set(raw, forKey: Self.cacheKey)
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
