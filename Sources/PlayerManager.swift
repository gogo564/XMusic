import AVFoundation
import MediaPlayer
import Combine

enum PlayMode: String, CaseIterable {
    case sequential    // 顺序播放
    case loopAll      // 列表循环
    case loopOne      // 单曲循环
    case shuffle      // 随机播放
}

final class PlayerManager: ObservableObject {
    static let shared = PlayerManager()

    @Published var isPlaying = false
    @Published var currentSong: LXSong?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var lyrics: String = ""
    @Published var parsedLyrics: [LyricLine] = []
    @Published var queue: [LXSong] = []
    @Published var currentIndex: Int = -1
    @Published var playMode: PlayMode = .loopAll {
        didSet {
            UserDefaults.standard.set(playMode.rawValue, forKey: "playMode")
            updateRemoteCommandCenter()
        }
    }
    @Published var isResolving = false
    @Published var playbackError: String?
    @Published var sourceName = ""
    @Published var qualityName = ""
    @Published var quality: String {
        didSet {
            AppConfigStore.shared.config.defaultQuality = quality
        }
    }
    @Published var currentLyricIndex: Int = -1
    @Published var localPlaybackTitle = ""
    @Published var localPlaybackArtist = ""

    struct LyricLine: Identifiable {
        let id = UUID()
        let time: Double
        let text: String
    }

    var currentTrack: LXSong? { currentSong }
    var currentPlaylist: [LXSong] { queue }
    var localTitle: String { localPlaybackTitle }

    private var currentQueueSong: LXSong? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var lrc = LRC.parse(nil)
    private var shuffledIndices: [Int] = []

    private init() {
        self.quality = AppConfigStore.shared.config.defaultQuality
        setupAudioSession()
        setupPeriodicTimeObserver()
        observeEnd()
        setupRemoteCommands()
        loadPlayMode()
        loadLastPlayed()
    }

    // MARK: - Setup

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("🔊 [Player] Audio Session Error: \(error.localizedDescription)")
        }
    }

    private func loadPlayMode() {
        if let rawValue = UserDefaults.standard.string(forKey: "playMode"),
           let mode = PlayMode(rawValue: rawValue) {
            playMode = mode
        }
    }

    private func setupPeriodicTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.currentTime = time.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 {
                self.duration = d
            }
            if let ranges = self.player.currentItem?.loadedTimeRanges, let first = ranges.first {
                let tr = first.timeRangeValue
                self.bufferedTime = CMTimeGetSeconds(tr.start) + CMTimeGetSeconds(tr.duration)
            }
            self.updateNowPlayingElapsed()
        }
    }

    private func observeEnd() {
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            self?.playNext(auto: true)
        }
    }

    // MARK: - Public playback API

    func play(song: LXSong, in newQueue: [LXSong]? = nil, index: Int? = nil) {
        if let newQueue = newQueue {
            queue = newQueue
            currentIndex = index ?? (newQueue.firstIndex(where: { $0.id == song.id }) ?? 0)
        } else {
            if let i = queue.firstIndex(where: { $0.id == song.id }) {
                currentIndex = i
            } else {
                queue.append(song)
                currentIndex = queue.count - 1
            }
        }
        saveLastPlayed()
        resolveAndPlay(song)
    }

    func play(song: LXSong, atQuality q: String) {
        quality = q
        play(song: song)
    }

    // Insert a song to play immediately after the current one.
    func playNext(with song: LXSong) {
        if queue.isEmpty {
            play(song: song)
            return
        }
        let insertAt = min(currentIndex + 1, queue.count)
        if queue.contains(where: { $0.id == song.id }) {
            if let existing = queue.firstIndex(where: { $0.id == song.id }) {
                queue.remove(at: existing)
                let adjusted = insertAt > existing ? insertAt - 1 : insertAt
                queue.insert(song, at: min(adjusted, queue.count))
            }
        } else {
            queue.insert(song, at: insertAt)
        }
    }

    func setPlaylist(_ songs: [LXSong], startIndex: Int = 0) {
        queue = songs
        currentIndex = startIndex
        if songs.indices.contains(startIndex) {
            resolveAndPlay(songs[startIndex])
        }
    }

    func setPlaylistFromRecent(_ tracks: [RecentTrack]) {
        let songs = tracks.compactMap { $0.song }
        if songs.isEmpty { return }
        if let song = currentSong, queue.contains(where: { $0.id == song.id }) { return }
        queue = songs
        if let song = currentSong, let idx = songs.firstIndex(where: { $0.id == song.id }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
    }

    func playFromRecent(_ track: RecentTrack) {
        guard let song = track.song else { return }
        play(song: song)
    }

    func togglePlayPause() {
        if player.currentItem == nil, currentSong != nil {
            resolveAndPlay(currentQueueSong)
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func playNext(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        switch playMode {
        case .loopOne:
            if auto {
                seek(to: 0)
                player.play()
                isPlaying = true
                updateNowPlaying()
                return
            }
            let nextIndex = (currentIndex + 1) % queue.count
            currentIndex = nextIndex
            resolveAndPlay(currentQueueSong)
        case .shuffle:
            guard queue.count > 1 else { return }
            var nextIndex = currentIndex
            while nextIndex == currentIndex {
                nextIndex = Int.random(in: 0..<queue.count)
            }
            currentIndex = nextIndex
            resolveAndPlay(currentQueueSong)
        case .sequential:
            let nextIndex = (currentIndex + 1) % queue.count
            if auto && nextIndex == 0 {
                player.pause()
                isPlaying = false
                updateNowPlaying()
                return
            }
            currentIndex = nextIndex
            resolveAndPlay(currentQueueSong)
        case .loopAll:
            let nextIndex = (currentIndex + 1) % queue.count
            currentIndex = nextIndex
            resolveAndPlay(currentQueueSong)
        }
    }

    func playPrevious() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        let prevIndex = (currentIndex - 1 + queue.count) % queue.count
        currentIndex = prevIndex
        resolveAndPlay(currentQueueSong)
    }

    func togglePlayMode() {
        if let index = PlayMode.allCases.firstIndex(of: playMode) {
            let nextIndex = (index + 1) % PlayMode.allCases.count
            playMode = PlayMode.allCases[nextIndex]
        }
    }

    func cyclePlayMode() {
        togglePlayMode()
    }

    var playModeIcon: String {
        switch playMode {
        case .sequential: return "list.bullet"
        case .loopAll:    return "repeat"
        case .loopOne:    return "repeat.1"
        case .shuffle:    return "shuffle"
        }
    }

    func seek(to time: Double) {
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        currentTime = time
        updateNowPlaying()
    }

    func setQuality(_ q: String) {
        quality = q
        if currentSong != nil {
            resolveAndPlay(currentQueueSong)
        }
    }

    func playLocalFile(url: URL, title: String, artist: String) {
        localPlaybackTitle = title
        localPlaybackArtist = artist
        queue = []
        currentIndex = -1
        currentTime = 0
        duration = 0
        bufferedTime = 0
        playbackError = nil
        isResolving = false
        lyrics = ""
        parsedLyrics = []
        currentLyricIndex = -1

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeItemStatus(item)
        player.play()
        isPlaying = true
        updateNowPlaying()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func canPlayNext() -> Bool {
        !queue.isEmpty && (playMode == .loopAll || playMode == .loopOne || playMode == .shuffle || currentIndex < queue.count - 1)
    }

    func canPlayPrevious() -> Bool {
        !queue.isEmpty
    }

    // MARK: - Internal playback

    private func resolveAndPlay(_ song: LXSong?) {
        guard let song = song else { return }
        currentSong = song
        isResolving = true
        playbackError = nil
        lyrics = ""
        parsedLyrics = []
        currentLyricIndex = -1

        // 0. Downloaded-file first (Documents/Downloads/) - instant playback
        if let localURL = DownloadService.shared.localURL(for: song) {
            startPlayback(url: localURL, song: song, sourceName: "下载", qualityName: "本地")
            Task { await loadLyric(for: song) }
            return
        }

        // 1. Cache-first
        if MusicCacheManager.shared.isCached(id: song.id), let cachedURL = MusicCacheManager.shared.cachedURL(for: song.id) {
            startPlayback(url: cachedURL, song: song, sourceName: "缓存", qualityName: qualityName.isEmpty ? "缓存" : qualityName)
            Task { await loadLyric(for: song) }
            return
        }

        Task {
            do {
                let result = try await LXAPIClient.shared.getPlaybackURL(for: song, quality: quality, autoSwitch: AppConfigStore.shared.config.autoSwitchSource)
                await MainActor.run {
                    guard let url = URL(string: result.url) else {
                        self.playbackError = "播放地址无效"
                        self.isResolving = false
                        return
                    }
                    MusicCacheManager.shared.startCaching(url: result.url, id: song.id)
                    self.startPlayback(url: url, song: song, sourceName: result.sourceName, qualityName: result.type)
                }
                await self.loadLyric(for: song)
            } catch {
                await MainActor.run {
                    self.playbackError = error.localizedDescription
                    self.isResolving = false
                }
            }
        }
    }

    private func startPlayback(url: URL, song: LXSong, sourceName: String, qualityName: String) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        observeItemStatus(item)
        self.sourceName = sourceName
        self.qualityName = qualityName
        currentTime = 0
        duration = 0
        bufferedTime = 0
        player.play()
        isPlaying = true
        isResolving = false
        updateNowPlaying()
        saveLastPlayed()
        saveRecent(song: song)
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .failed:
                    self.playbackError = item.error?.localizedDescription ?? "播放失败"
                    self.isPlaying = false
                case .readyToPlay:
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 {
                        self.duration = d
                    }
                default:
                    break
                }
            }
        }
    }

    private func loadLyric(for song: LXSong) async {
        do {
            let result = try await LXAPIClient.shared.getLyric(for: song)
            await MainActor.run {
                let raw = result.lyric ?? ""
                self.lyrics = raw
                let parsed = LRC.parse(raw, translation: result.translated)
                self.lrc = parsed
                self.parsedLyrics = parsed.lines.map { LyricLine(time: $0.time, text: $0.text) }
                self.currentLyricIndex = -1
                self.saveRecent(song: song, lrc: raw)
            }
        } catch {
            await MainActor.run {
                self.lyrics = ""
                self.lrc = LRC.parse(nil)
                self.parsedLyrics = []
                self.currentLyricIndex = -1
            }
        }
    }

    // MARK: - Persistence

    private func saveLastPlayed() {
        if let song = currentSong, let data = song.jsonData {
            UserDefaults.standard.set(data, forKey: "lastPlayedSong")
        }
        if !queue.isEmpty {
            if let data = try? JSONSerialization.data(withJSONObject: queue.compactMap { $0.raw }) {
                UserDefaults.standard.set(data, forKey: "lastPlayedQueue")
            }
            UserDefaults.standard.set(currentIndex, forKey: "lastPlayedIndex")
        }
    }

    private func loadLastPlayed() {
        if let data = UserDefaults.standard.data(forKey: "lastPlayedSong"),
           let song = LXSong(jsonData: data) {
            currentSong = song
        }
        if let data = UserDefaults.standard.data(forKey: "lastPlayedQueue"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            queue = arr.map(LXSong.init)
            currentIndex = UserDefaults.standard.integer(forKey: "lastPlayedIndex")
            if currentIndex < 0 || currentIndex >= queue.count {
                currentIndex = queue.isEmpty ? -1 : 0
            }
        }
    }

    private func saveRecent(song: LXSong, lrc: String? = nil) {
        RecentStore.shared.upsert(song, lrc: lrc)
    }

    // MARK: - Now Playing + Remote commands

    /// In-memory artwork cache keyed by song id, so we download each cover only once.
    private var artworkCache: [String: MPMediaItemArtwork] = [:]

    /// Full now playing update. Called on play/pause/seek/song change.
    private func updateNowPlaying() {
        guard let song = currentSong else {
            if !localPlaybackTitle.isEmpty {
                var info: [String: Any] = [
                    MPMediaItemPropertyTitle: localPlaybackTitle,
                    MPMediaItemPropertyArtist: localPlaybackArtist,
                    MPMediaItemPropertyPlaybackDuration: duration,
                    MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                    MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
                ]
                if let art = artworkCache["local"] {
                    info[MPMediaItemPropertyArtwork] = art
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            } else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.singer,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = artworkCache[song.id] {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        loadArtwork(for: song)
    }

    /// Lightweight periodic update (every 0.5s): only refreshes elapsed time + rate,
    /// reusing the cached nowPlayingInfo so the artwork is never cleared/re-added.
    private func updateNowPlayingElapsed() {
        guard currentSong != nil else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if info.isEmpty { updateNowPlaying(); return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Downloads the cover once per song, then re-applies it without disturbing the rest.
    private func loadArtwork(for song: LXSong) {
        guard artworkCache[song.id] == nil, !song.imageURL.isEmpty, let coverURL = URL(string: song.imageURL) else { return }
        let coverSize = CGSize(width: 600, height: 600)
        Task { [weak self] in
            if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                let art = MPMediaItemArtwork(boundsSize: coverSize) { _ in img }
                await MainActor.run {
                    guard let self = self else { return }
                    self.artworkCache[song.id] = art
                    guard self.currentSong?.id == song.id else { return }
                    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    info[MPMediaItemPropertyArtwork] = art
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                }
            }
        }
    }

    private func setupRemoteCommands() {
        let cmd = MPRemoteCommandCenter.shared()
        cmd.playCommand.addTarget { [weak self] _ in
            self?.isPlaying = true
            self?.player.play()
            return .success
        }
        cmd.pauseCommand.addTarget { [weak self] _ in
            self?.isPlaying = false
            self?.player.pause()
            return .success
        }
        cmd.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        cmd.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        cmd.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        cmd.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
    }

    private func updateRemoteCommandCenter() {
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = canPlayNext()
        MPRemoteCommandCenter.shared().previousTrackCommand.isEnabled = canPlayPrevious()
    }
}
