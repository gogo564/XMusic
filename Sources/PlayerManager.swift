import AVFoundation
import MediaPlayer
import Combine

enum PlayMode: String, CaseIterable {
    case sequential    // 顺序播放
    case loopAll      // 列表循环
    case loopOne      // 单曲循环
    case shuffle      // 随机播放
}

final class PlayerManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = PlayerManager()

    @Published var isPlaying = false
    @Published var currentSong: LXSong?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var lyrics: String = ""
    @Published var parsedLyrics: [LyricLine] = []
    @Published var queue: [LXSong] = []
    @Published var queueRefreshCount = 0
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
    @Published var sceneName = ""
    @Published var qualityName = ""
    @Published var playbackOrigin = "" // "缓存" / "下载" / "本地" / ""（在线）
    @Published var quality: String {
        didSet {
            AppConfigStore.shared.config.defaultQuality = quality
        }
    }
    @Published var currentLyricIndex: Int = -1
    @Published var localPlaybackTitle = ""
    @Published var localPlaybackArtist = ""
    @Published var showPlayer = false
    @Published var sleepTimerRemaining: TimeInterval = 0
    @Published var currentPlaybackURL: URL? // 正在播放的本地文件（缓存/下载），供缓存清理时保护
    private var sleepTask: Task<Void, Never>?

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
    /// 汽水专用播放引擎：汽水永远先落盘明文 m4a，用 AVAudioPlayer 瞬时起播
    /// （无 AVPlayerItem 状态机、无 0.00s 瞬态 failed），其余平台仍走上面的 AVPlayer 流播。
    private var sodaPlayer: AVAudioPlayer?
    private var sodaTimeTimer: Timer?
    var activeIsSoda: Bool { sodaPlayer != nil }
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var lrc = LRC.parse(nil)
    private var shuffledIndices: [Int] = []
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedURLs: [String: String] = [:]

    /// 连续解析失败计数：>0 时解析失败自动跳下一首；跑满一圈（>= 队列长度）才停并弹错，
    /// 避免「播放全部」被一首失效/会员曲卡死，也避免整列失败时死循环。
    private var resolveFailStreak = 0
    // 预建好的下一首 item（含汽水 loader 挂载），切歌时直接替换省构建
    private var nextItem: AVPlayerItem?
    private var nextItemKey = ""
    /// 当前已加载歌词归属的歌曲 id：支持"歌词与解析并行拉取"+ 防止跨歌覆盖
    private var loadedLyricSongID: String?
    /// 最近一次实际起播的时间戳。用于过滤 AVPlayer 换 item 时滞留投递的
    /// AVPlayerItemDidPlayToEndTime 通知：刚起播（<1s）就收到结束通知，几乎都是
    /// 缓存文件 seek 起始时间异常或旧 item 残留通知，不应触发自动切歌。
    private var lastItemPlayStartTime = Date.distantPast

    /// 场景/推荐流队列播放到末尾时，调用此闭包拉取一批新歌替换队列。
    /// 由 SodaTrackListView 等视图注册；不注册则保持原有循环行为。
    var queueRefreshHandler: (() async -> [LXSong])?

    private override init() {
        super.init()
        self.quality = AppConfigStore.shared.config.defaultQuality
        setupAudioSession()
        setupInterruptionHandling()
        setupPeriodicTimeObserver()
        observeEnd()
        setupRemoteCommands()
        loadPlayMode()
        loadLastPlayed()
    }

    // MARK: - Setup

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("🔊 [Player] Audio Session Error: \(error.localizedDescription)")
        }
    }

    /// 来电/闹钟等打断音频会话：打断时暂停，结束后复活会话并按中断前状态续播。
    /// 不订阅到达的 interruptionNotification 会导致「来电不暂停、挂断不恢复」——
    /// 来电时系统夺走音频但 isPlaying 仍为 true；挂断后会话已失活也不会自动恢复。
    private func setupInterruptionHandling() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let info = notification.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

            switch type {
            case .began:
                Log.write("📵 [Player] 音频被打断 (来电/闹钟) → 暂停")
                self.wasPlayingBeforeInterruption = self.isPlaying
                if self.isPlaying {
                    self.enginePause()
                    self.isPlaying = false
                    self.updateNowPlaying()
                }
            case .ended:
                Log.write("📞 [Player] 打断结束 → 复活会话")
                try? AVAudioSession.sharedInstance().setActive(true)
                let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                // 来电/闹钟结束后默认续播；个别打断类型带 shouldResume 标志时更应恢复。
                if self.wasPlayingBeforeInterruption || shouldResume {
                    if self.activeIsSoda {
                        self.enginePlay()
                        self.isPlaying = true
                        self.updateNowPlaying()
                    } else if self.player.currentItem == nil, self.currentSong != nil {
                        self.resolveAndPlay(self.currentQueueSong)
                    } else {
                        self.enginePlay()
                        self.isPlaying = true
                        self.updateNowPlaying()
                    }
                }
            @unknown default:
                break
            }
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
            self.updateLyricIndex()
            self.updateNowPlayingElapsed()
        }
    }

    private func observeEnd() {
        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        // 注意：object 传 nil（而不是 player.currentItem）。带 object 的
        // AVPlayerItemDidPlayToEndTime 通知在部分 iOS 版本存在不投递的已知 bug，
        // 会直接导致「播完一首不自动切下一首」。object 为 nil 后 handler 会收到
        // 所有 item 的结束通知，playNext(auto:) 内部按 currentIndex 判断，逻辑不变。
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 过滤滞留的结束通知：换 item 后 1 秒内就收到 DidPlayToEnd，几乎都是
            // 旧 item 的残留通知或缓存文件 seek 时间异常误报，不是真的播完。
            guard Date().timeIntervalSince(self.lastItemPlayStartTime) >= 1 else { return }
            Log.write("⏭️ [Player] DidPlayToEnd → auto next")
            self.playNext(auto: true)
        }
    }

    private func updateLyricIndex() {
        guard !parsedLyrics.isEmpty else {
            currentLyricIndex = -1
            return
        }
        var idx = -1
        for (i, line) in parsedLyrics.enumerated() {
            if currentTime >= line.time { idx = i } else { break }
        }
        if idx != currentLyricIndex {
            currentLyricIndex = idx
        }
    }

    // MARK: - Public playback API

    func play(song: LXSong, in newQueue: [LXSong]? = nil, index: Int? = nil, presentPlayer: Bool = true, sceneName: String? = nil) {
        if let newQueue = newQueue {
            queue = newQueue
            // 设置新队列时清空刷新回调，防止旧场景的 handler 污染新队列
            queueRefreshHandler = nil
            self.sceneName = sceneName ?? ""
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
        // 只有显式要求 present 才打开播放页；false 时不改动 showPlayer（滑动换歌等场景不能把它关掉）
        if presentPlayer {
            showPlayer = true
        }
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
        queueRefreshHandler = nil
        currentIndex = startIndex
        if songs.indices.contains(startIndex) {
            resolveAndPlay(songs[startIndex])
        }
    }

    /// 静默预置队列：把浏览到的歌单设为播放队列，但**不触发播放、不打断当前正在播的歌**。
    /// 供歌单详情页进入/加载完成后调用，实现「翻到哪个歌单就以哪个歌单为队列」——
    /// 之后点播放器切歌/点列表任意一首都圈在当前歌单内，不会沿用上一个残留队列。
    func silentSetPlaylist(_ songs: [LXSong], startIndex: Int = 0) {
        guard !songs.isEmpty else { return }
        queue = songs
        queueRefreshHandler = nil
        currentIndex = startIndex
    }

    func setPlaylistFromRecent(_ tracks: [RecentTrack]) {
        let songs = tracks.compactMap { $0.song }
        if songs.isEmpty { return }
        if let song = currentSong, queue.contains(where: { $0.id == song.id }) { return }
        queue = songs
        queueRefreshHandler = nil
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
        if player.currentItem == nil, !activeIsSoda, currentSong != nil {
            Log.write("🔘 [Player] togglePlayPause → currentItem nil, resolveAndPlay")
            resolveAndPlay(currentQueueSong)
            return
        }
        if isPlaying {
            Log.write("🔘 [Player] togglePlayPause → pause (was playing)")
            enginePause()
            isPlaying = false
        } else {
            Log.write("🔘 [Player] togglePlayPause → play (was paused)")
            enginePlay()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func playNext(auto: Bool = false) {
        guard !queue.isEmpty else { return }
        switch playMode {
        case .loopOne:
            if auto {
                engineSeek(0)
                enginePlay()
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
                enginePause()
                isPlaying = false
                updateNowPlaying()
                return
            }
            currentIndex = nextIndex
            resolveAndPlay(currentQueueSong)
        case .loopAll:
            let nextIndex = (currentIndex + 1) % queue.count
            // 场景/推荐流：播到队尾（自动或手动切歌）时拉新一批替换，避免反复循环同一批旧歌
            if nextIndex == 0, let refresh = queueRefreshHandler {
                Task { @MainActor in
                    let newSongs = await refresh()
                    guard !newSongs.isEmpty else {
                        self.currentIndex = nextIndex
                        self.resolveAndPlay(self.currentQueueSong)
                        return
                    }
                    var deduped: [LXSong] = []
                    var seen = Set<String>()
                    for s in newSongs {
                        guard seen.insert(s.id).inserted else { continue }
                        deduped.append(s)
                    }
                    guard !deduped.isEmpty else {
                        self.currentIndex = nextIndex
                        self.resolveAndPlay(self.currentQueueSong)
                        return
                    }
                    self.queue = deduped
                    self.currentIndex = 0
                    self.queueRefreshCount += 1
                    self.resolveAndPlay(self.currentQueueSong)
                }
                return
            }
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
        engineSeek(time)
        updateNowPlaying()
    }

    func setQuality(_ q: String) {
        quality = q
        if currentSong != nil {
            resolveAndPlay(currentQueueSong)
        }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        guard let minutes = minutes, minutes > 0 else {
            sleepTimerRemaining = 0
            return
        }
        sleepTimerRemaining = TimeInterval(minutes * 60)
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                await MainActor.run {
                    guard let self = self else { return }
                    guard self.sleepTimerRemaining > 0 else { return }
                    self.sleepTimerRemaining -= 1
                    if self.sleepTimerRemaining <= 0 {
                        self.sleepTimerRemaining = 0
                        self.sleepTask?.cancel()
                        self.enginePause()
                        self.isPlaying = false
                        self.updateNowPlaying()
                    }
                }
            }
        }
    }

    var sleepTimerText: String {
        let total = Int(sleepTimerRemaining)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func playLocalFile(url: URL, title: String, artist: String) {
        localPlaybackTitle = title
        localPlaybackArtist = artist
        currentSong = LXSong(["name": title, "singer": artist])
        sourceName = ""
        qualityName = ""
        playbackOrigin = "本地"
        currentPlaybackURL = url
        stopSodaAudioPlayer()
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

        let item = makeItem(for: url)
        player.replaceCurrentItem(with: item)
        observeItemStatus(item)
        player.play()
        isPlaying = true
        updateNowPlaying()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        showPlayer = true
    }

    func canPlayNext() -> Bool {
        !queue.isEmpty && (playMode == .loopAll || playMode == .loopOne || playMode == .shuffle || currentIndex < queue.count - 1)
    }

    func canPlayPrevious() -> Bool {
        !queue.isEmpty
    }

    // MARK: - Internal playback

    /// 汽水音乐歌曲（source == "soda"），播放 URL 由 SodaAPIClient 直接提供
    private func isSoda(_ song: LXSong) -> Bool {
        song.source == "soda"
    }

    /// 统一获取播放地址：汽水源走 SodaAPIClient（下载+解密落地 file:// 本地播放），其余走 lx-sync-server
    private func playbackInfo(for song: LXSong) async throws -> (url: String, type: String, sourceName: String) {
        if isSoda(song) {
            let trackID = song.songmid ?? ""
            let mapped = mapSodaQuality(quality)
            do {
                let stream = try await SodaAPIClient.shared.songStream(trackID: trackID, quality: quality)
                let delivered = stream.quality.isEmpty ? mapped : stream.quality
                let display = SodaAPIClient.qualityDisplayName(delivered)
                if stream.hexKey.count == 32 {
                    // 加密流：只会下载+解密落盘成本地 m4a，AVPlayer 从本地文件播放。
                    // 绝不回退 sodastream:// custom loader——实测该 loader 在 iOS AVPlayer
                    // 上 item failed 概率 100%（历史日志 390/390），正是"头1秒重复"的根源。
                    for attempt in 0..<2 {
                        if let fileURL = try? await MusicCacheManager.shared.ensureSodaFile(trackID: trackID, id: song.id, quality: quality) {
                            return (fileURL.absoluteString, display, "汽水")
                        }
                        if attempt == 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
                    }
                    throw SodaError.cacheFailed
                }
                guard let url = URL(string: stream.mainURL) else {
                    throw SodaError.upstream
                }
                // 明文直链（qishui-api h5 兜底）：直接播放 CDN URL，无需解密
                return (url.absoluteString, display, "汽水")
            } catch {
                throw error
            }
        }
        let result = try await LXAPIClient.shared.getPlaybackURL(for: song, quality: quality, autoSwitch: AppConfigStore.shared.config.autoSwitchSource)
        return (result.url, result.type, result.sourceName)
    }

    /// 汽水音质档位映射：128k/320k/flac → 服务器 quality（medium/highest/lossless）
    private func mapSodaQuality(_ q: String) -> String {
        switch q {
        case "128k": return "medium"
        case "320k": return "highest"
        case "flac": return "lossless"
        case "hi_res": return "hi_res"
        default: return "highest"
        }
    }

    private func resolveAndPlay(_ song: LXSong?) {
        guard let song = song else { return }
        // 歌词与地址解析并行拉取：不用等起播成功才出现歌词
        Task { await self.loadLyric(for: song) }
        // 注意：不在解析前切换 currentSong。只有真正起播（startPlayback）成功才切，
        // 这样解析期间封面/歌词仍是上一首，声音与画面一致；解析失败则维持上一首继续播。
        isResolving = true
        playbackError = nil

        // 预取下一首：与当前曲解析并行，切歌时下一首 URL 已就绪，省去解析等待
        prefetchNext()

        // 0. Downloaded-file first (Documents/Downloads/) - instant playback
        if let localURL = DownloadService.shared.localURL(for: song) {
            let dlQuality = DownloadService.shared.downloadedQuality(for: song) ?? quality
            startPlayback(url: localURL, song: song, sourceName: song.source, qualityName: dlQuality, playbackOrigin: "下载")
            return
        }

        // 1. Cache-first（缓存按 音质 区分，命中即所选音质）
        if MusicCacheManager.shared.isCached(id: song.id, quality: quality), let cachedURL = MusicCacheManager.shared.cachedURL(for: song.id, quality: quality) {
            startPlayback(url: cachedURL, song: song, sourceName: song.source, qualityName: "缓存", playbackOrigin: "缓存")
            return
        }
        // 1.1 汽水跨音质兜底：本地任意音质的缓存都秒开，远好于慢网整首拉取。
        // （列表"缓存"角标按任意音质判断；若只精确匹配当前档，音质设置变过
        // 之后会永远 miss，明明有缓存却每次都要解析+下载。）
        if isSoda(song), let anyURL = MusicCacheManager.shared.anyQualityCachedURL(for: song.id) {
            Log.write("⚡️ [Player] 汽水跨音质缓存命中 song=\(song.name) file=\(anyURL.lastPathComponent)")
            startPlayback(url: anyURL, song: song, sourceName: song.source, qualityName: "缓存", playbackOrigin: "缓存")
            return
        }

        // 1.5 Prefetched URL：上一首播放时已预取好的下一首地址，直接起播省一次服务器往返
        if let preURL = prefetchedURLs.removeValue(forKey: song.id + "_" + quality), let url = URL(string: preURL) {
            startPlayback(url: url, song: song, sourceName: song.source, qualityName: quality, playbackOrigin: "")
            return
        }

        Task {
            do {
                let result = try await playbackInfo(for: song)
                await MainActor.run {
                    guard let url = URL(string: result.url) else {
                        self.handleResolveFailure("播放地址无效")
                        return
                    }
                    // file:// 已由 ensureSodaFile 落盘，无需再对本地文件发起网络缓存
                    if !url.isFileURL {
                        MusicCacheManager.shared.startCaching(url: result.url, quality: quality, id: song.id)
                    }
                    self.startPlayback(url: url, song: song, sourceName: result.sourceName, qualityName: result.type, playbackOrigin: "")
                }
            } catch {
                await MainActor.run {
                    self.handleResolveFailure(error.localizedDescription)
                }
            }
        }
    }

    /// 解析播放地址失败时：队列还有后续歌曲则自动跳到下一首（跳过失效/会员曲目），
    /// 连续失败一圈后才保留错误提示，避免「播放全部」卡在坏曲上。
    private func handleResolveFailure(_ message: String) {
        isResolving = false
        resolveFailStreak += 1
        if resolveFailStreak >= queue.count {
            resolveFailStreak = 0
            playbackError = message
            return
        }
        guard queue.count > 1 else {
            resolveFailStreak = 0
            playbackError = message
            return
        }
        let next = (currentIndex + 1) % queue.count
        guard next != currentIndex else {
            resolveFailStreak = 0
            playbackError = message
            return
        }
        currentIndex = next
        resolveAndPlay(currentQueueSong)
    }

    // MARK: - AVAudioPlayer 引擎（汽水专用）

    private func stopSodaAudioPlayer() {
        sodaPlayer?.stop()
        sodaPlayer = nil
        sodaTimeTimer?.invalidate()
        sodaTimeTimer = nil
    }

    private func enginePlay() {
        if let ap = sodaPlayer { ap.play() } else { player.play() }
    }

    private func enginePause() {
        if let ap = sodaPlayer { ap.pause() } else { player.pause() }
    }

    private func engineSeek(_ time: Double) {
        if let ap = sodaPlayer { ap.currentTime = time }
        else { player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
        currentTime = time
    }

    private func startSodaTimer() {
        sodaTimeTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let ap = self.sodaPlayer else { return }
                self.currentTime = ap.currentTime
                self.duration = ap.duration
                self.bufferedTime = ap.duration
                self.updateLyricIndex()
                self.updateNowPlayingElapsed()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sodaTimeTimer = t
    }

    /// 汽水永远先落盘明文 m4a，用 AVAudioPlayer 瞬时起播，绕过 AVPlayer 0.00s 瞬态失败。
    private func playSodaWithAudioPlayer(url: URL, song: LXSong, sourceName: String, qualityName: String, playbackOrigin: String) {
        stopSodaAudioPlayer()
        // 释放上一个 AVPlayer 项，避免双引擎同时出声
        player.pause()
        player.replaceCurrentItem(with: nil)
        do {
            let ap = try AVAudioPlayer(contentsOf: url)
            ap.delegate = self
            ap.prepareToPlay()
            sodaPlayer = ap
            currentPlaybackURL = url
            currentTime = 0
            duration = ap.duration
            bufferedTime = ap.duration
            isResolving = false
            isPlaying = true
            ap.play()
            lastItemPlayStartTime = Date()
            startSodaTimer()
            Log.write("🎧 [Player] soda AVAudioPlayer start url=\(url.absoluteString.prefix(60)) dur=\(Int(duration))s")
        } catch {
            stopSodaAudioPlayer()
            Log.write("❌ [Player] soda AVAudioPlayer create ERROR: \(error.localizedDescription)")
            handleResolveFailure("汽水本地打开失败，已自动跳过")
            return
        }
        saveLastPlayed()
        saveRecent(song: song)
        updateNowPlaying()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        guard Date().timeIntervalSince(lastItemPlayStartTime) >= 1 else { return }
        Log.write("⏭️ [Player] soda AVAudioPlayer DidPlayToEnd → auto next")
        isPlaying = false
        playNext(auto: true)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Log.write("⚠️ [Player] soda AVAudioPlayer decode error: \(error?.localizedDescription ?? "unknown")")
        handleResolveFailure("汽水解码失败，已自动跳过")
    }

    private func makeItem(for url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 8
        item.preferredPeakBitRate = 0
        return item
    }

    private func startPlayback(url: URL, song: LXSong, sourceName: String, qualityName: String, playbackOrigin: String = "") {
        Log.write("▶️ [Player] startPlayback song=\(song.name) scheme=\(url.scheme ?? "") origin=\(playbackOrigin) url=\(url.absoluteString.prefix(70))")
        resolveFailStreak = 0
        // 起播成功才切换当前曲目：封面/歌词/进度与声音同步更新
        currentSong = song
        // 歌词已在并行预取时到位则保留；否则清掉上一首的残留
        if loadedLyricSongID != song.id {
            lyrics = ""
            lrc = LRC.parse(nil)
            parsedLyrics = []
        }
        loadedLyricSongID = song.id
        currentLyricIndex = -1
        // —— 汽水本地明文 m4a：走专用 AVAudioPlayer 引擎瞬时起播，
        //    彻底绕开 AVPlayer 对本地汽水文件的 0.00s 瞬态 failed / 静音稳定 / asset 预热这套兜底。
        if sourceName == "汽水", url.isFileURL {
            playSodaWithAudioPlayer(url: url, song: song, sourceName: sourceName, qualityName: qualityName, playbackOrigin: playbackOrigin)
            return
        }
        // 非汽水：切回/保持 AVPlayer，并释放汽水引擎，避免双引擎同时出声
        stopSodaAudioPlayer()
        player.automaticallyWaitsToMinimizeStalling = false
        // 优先复用预建好的下一首 item（省去 AVURLAsset + loader 构建）；不匹配则现建
        let item: AVPlayerItem
        let itemKey = song.id + "_" + quality + "_" + (url.scheme ?? "")
        if let next = nextItem, nextItemKey == itemKey {
            item = next
            nextItem = nil
            nextItemKey = ""
        } else {
            nextItem = nil
            nextItemKey = ""
            item = makeItem(for: url)
        }
        // 非汽水 item 直接替换，不再走汽水的预热/重建兜底
        player.replaceCurrentItem(with: item)
        // 记录本次起播时间，供 DidPlayToEnd 守卫过滤旧 item 的滞留结束通知
        lastItemPlayStartTime = Date()
        observeItemStatus(item)
        observeEnd()
        self.sourceName = sourceName
        self.qualityName = qualityName
        self.playbackOrigin = playbackOrigin
        self.currentPlaybackURL = url.scheme == "file" ? url : nil
        currentTime = 0
        duration = 0
        bufferedTime = 0
        player.volume = 1
        player.play()
        isPlaying = true
        isResolving = false
        updateNowPlaying()
        saveLastPlayed()
        saveRecent(song: song)
    }

    /// 预解析+预缓存队列下一首：当前曲开始播放后，后台解析下一首的播放地址并下载到缓存，
    /// 使 4G 弱网下切歌时命中缓存秒开（跳过服务器解析 + 首包缓冲）。
    /// 同时预建好 AVPlayerItem，让切歌时直接替换、无需重新构建（汽水 loader 也提前挂载）。
    private func prefetchNext() {
        prefetchTask?.cancel()
        guard queue.count > 1, currentIndex >= 0 else { return }
        let nextIndex = (currentIndex + 1) % queue.count
        if nextIndex == currentIndex { return }
        guard queue.indices.contains(nextIndex) else { return }
        let next = queue[nextIndex]
        let prefetchQuality = self.quality
        if MusicCacheManager.shared.isCached(id: next.id, quality: prefetchQuality) { return }
        prefetchTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await playbackInfo(for: next)
                guard !Task.isCancelled else { return }
                guard let u = URL(string: result.url) else { return }
                self.prefetchedURLs[next.id + "_" + prefetchQuality] = result.url
                // file:// 已由 ensureSodaFile 落盘，无需再对本地文件发起网络缓存
                if !u.isFileURL {
                    MusicCacheManager.shared.startCaching(url: result.url, quality: prefetchQuality, id: next.id)
                }
                // 预建 item（后台线程构建 asset 无碍，loader 挂载在 AVURLAsset 上）
                let prebuilt = await MainActor.run { self.makeItem(for: u) }
                guard !Task.isCancelled else { return }
                self.nextItem = prebuilt
                self.nextItemKey = next.id + "_" + prefetchQuality + "_" + (u.scheme ?? "")
                // 主动触发资源预加载，让 readyToPlay 更快
                prebuilt.preferredForwardBufferDuration = 8
            } catch {
                // 预取失败不影响当前播放，静默忽略
            }
        }
    }

    private func observeItemStatus(_ item: AVPlayerItem) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch item.status {
                case .failed:
                    Log.write("❌ [Player] item failed: \(item.error?.localizedDescription ?? "")")
                    // AVPlayer 路径（非汽水：流播）失败直接上报；汽水已改走 AVAudioPlayer，
                    // 不再挂 AVPlayerItem，故此处不再有汽水的瞬时失败重建/静音稳定逻辑。
                    self.playbackError = item.error?.localizedDescription ?? "播放失败"
                    self.isPlaying = false
                case .readyToPlay:
                    let d = item.duration.seconds
                    Log.write("🎧 [Player] item ready dur=\(d) song=\(self.currentSong?.name ?? "") isPlayingBefore=\(self.isPlaying)")
                    if d.isFinite, d > 0 {
                        self.duration = d
                    }
                    self.playbackError = nil
                    self.updateNowPlaying()
                default:
                    break
                }
            }
        }
    }

    private func loadLyric(for song: LXSong) async {
        let fetched: (raw: String, parsed: LRC)? = try? await fetchLyricData(for: song)
        await MainActor.run {
            // 归属守卫：快速切歌时，迟到的歌词不得覆盖新歌的歌词
            guard self.currentSong?.id == song.id || self.currentSong == nil else { return }
            if let f = fetched {
                self.lyrics = f.raw
                self.lrc = f.parsed
                self.parsedLyrics = f.parsed.lines.map { LyricLine(time: $0.time, text: $0.text) }
                self.currentLyricIndex = -1
                self.loadedLyricSongID = song.id
                self.saveRecent(song: song, lrc: f.raw)
                self.updateNowPlaying()
            } else if self.loadedLyricSongID != song.id {
                self.lyrics = ""
                self.lrc = LRC.parse(nil)
                self.parsedLyrics = []
                self.currentLyricIndex = -1
                self.updateNowPlaying()
            }
        }
    }

    private func fetchLyricData(for song: LXSong) async throws -> (raw: String, parsed: LRC) {
        var raw: String
        var parsed: LRC
        if isSoda(song) {
            raw = try await SodaAPIClient.shared.lyric(trackID: song.songmid ?? "")
            parsed = LRC.parse(raw)
        } else {
            let result = try await LXAPIClient.shared.getLyric(for: song)
            raw = result.lyric ?? ""
            parsed = LRC.parse(raw, translation: result.translated)

            if parsed.lines.isEmpty, LRC.hasTimestamps(result.lxlyric) {
                let lxLines = LRC.parseLxlyric(result.lxlyric)
                if !lxLines.isEmpty {
                    raw = lxLines.map { formatLRC($0.time) + $0.text }.joined(separator: "\n")
                    parsed = LRC.parse(raw)
                }
            }

            if parsed.lines.isEmpty, LRC.hasTimestamps(raw) == false {
                if let fallback = await LXAPIClient.shared.getLyricFallback(for: song) {
                    raw = fallback
                    parsed = LRC.parse(fallback)
                }
            }
        }
        return (raw, parsed)
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

    /// Format a time interval as `[mm:ss.xx]` for LRC reconstruction.
    private func formatLRC(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        let ms = Int((t - floor(t)) * 100)
        return String(format: "[%02d:%02d.%02d]", m, s, ms)
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
                if !lyrics.isEmpty {
                    info[MPMediaItemPropertyLyrics] = lyrics
                }
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
        if !lyrics.isEmpty {
            info[MPMediaItemPropertyLyrics] = lyrics
        }
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
            self?.enginePlay()
            return .success
        }
        cmd.pauseCommand.addTarget { [weak self] _ in
            self?.isPlaying = false
            self?.enginePause()
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
