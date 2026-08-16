import CarPlay
import UIKit
import AVFoundation

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPInterfaceControllerDelegate {

    private var interfaceController: CPInterfaceController?
    private var rootTemplate: CPListTemplate?
    private var retryTimer: Timer?
    private var rootDidAppear = false

    nonisolated private func log(_ message: String) {
        Log.write("[CarPlay] \(message)")
    }

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        log("didConnect")
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        // CarPlay 音频 app：连接即确保 audio session 激活 + 接收远程控制事件，
        // 否则系统可能在 scene 激活后立即把它切回后台（黑屏）。
        ensureAudioSessionActive()
        // Apple 要求 didConnect 返回前必须设置根模板，否则黑屏。
        buildRootTemplate(placeholder: true)
        // iOS 15 上 setRootTemplate completion 不回调，不能用 topTemplate/completion 判断成功。
        // 模板必须被强引用持有（rootTemplate 属性），否则系统会释放 -> 黑屏。
        // 强制重试：每 0.5s 检查一次，只要根模板未真正呈现就重设，直到 templateDidAppear 或断开。
        startRootRetry()
        Task { @MainActor in
            log("loading data")
            await PlaylistStore.shared.refresh()
            log("data loaded, updating root")
            buildRootTemplate(placeholder: false)
        }
    }

    // MARK: - CPInterfaceControllerDelegate

    // iOS 15 上接口控制器的布尔回调不可靠，用模板生命周期回调判断根模板是否真正呈现。
    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateWillAppear type=\(type(of: aTemplate))")
    }

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateDidAppear type=\(type(of: aTemplate)) isRoot=\(aTemplate === rootTemplate)")
        if aTemplate === rootTemplate {
            rootDidAppear = true
        }
    }

    private func startRootRetry() {
        retryTimer?.invalidate()
        var attempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.interfaceController != nil else {
                    timer.invalidate()
                    return
                }
                attempts += 1
                if self.rootDidAppear || attempts > 30 {
                    if self.rootDidAppear {
                        self.log("root appeared after \(attempts) checks")
                    }
                    timer.invalidate()
                    return
                }
                self.log("retry setRootTemplate attempt \(attempts) rootDidAppear=false")
                self.setRootTemplateAnimatedFalse()
            }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log("didDisconnect")
        retryTimer?.invalidate()
        retryTimer = nil
        self.interfaceController = nil
        rootTemplate = nil
        rootDidAppear = false
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        log("willConnectToSession role=\(session.role.rawValue)")
        // CarPlay 渲染用模板而非 UIWindow，这里只记录日志，不做 window 创建
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        log("sceneDidBecomeActive role=\(scene.session.role.rawValue)")
        // CarPlay 音频 app 的 scene 活跃依赖 audio session：激活场景时确保播放类别 + 激活，
        // 否则 CarPlay 会把 scene 立即切回后台（激活后几 ms 就 resignActive+enterBackground -> 黑屏）。
        if scene.session.role == UISceneSession.Role.carTemplateApplication {
            ensureAudioSessionActive()
            if !rootDidAppear {
                log("sceneDidBecomeActive: root not appeared yet, retrying")
                setRootTemplateAnimatedFalse()
            }
        }
    }

    private func ensureAudioSessionActive() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
            // CarPlay 音频 app 需要接收远程控制事件，否则车机不认为它是活跃的音频 app
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            log("ensureAudioSessionActive error: \(error)")
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        log("sceneWillResignActive role=\(scene.session.role.rawValue)")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        log("sceneDidEnterBackground role=\(scene.session.role.rawValue)")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        log("sceneDidDisconnect role=\(scene.session.role.rawValue)")
    }

    // MARK: - Root

    private func makeRootItems() -> [CPListItem] {
        var items: [CPListItem] = []

        // 我喜欢的音乐
        let loveSongs = PlaylistStore.shared.songs(kind: .love, playlistID: "")
        items.append(makeListEntry(
            title: "我喜欢的音乐",
            detail: "\(loveSongs.count) 首",
            image: image("heart.fill")
        ) { [weak self] in
            self?.pushSongs(title: "我喜欢的音乐", songs: loveSongs)
        })

        // 默认列表
        let defaultSongs = PlaylistStore.shared.songs(kind: .defaultList, playlistID: "")
        items.append(makeListEntry(
            title: "默认列表",
            detail: "\(defaultSongs.count) 首",
            image: image("music.note.list")
        ) { [weak self] in
            self?.pushSongs(title: "默认列表", songs: defaultSongs)
        })

        // 自定义歌单
        for pl in PlaylistStore.shared.playlists {
            let songs = PlaylistStore.shared.songs(kind: .user, playlistID: pl.id)
            items.append(makeListEntry(
                title: pl.name,
                detail: "\(songs.count) 首",
                image: image("music.note.list")
            ) { [weak self] in
                self?.pushSongs(title: pl.name, songs: songs)
            })
        }

        // 最近播放
        let recentTracks = RecentStore.shared.items
        let recentSongs = recentTracks.compactMap { $0.song }
        items.append(makeListEntry(
            title: "最近播放",
            detail: "\(recentSongs.count) 首",
            image: image("clock")
        ) { [weak self] in
            self?.pushSongs(title: "最近播放", songs: recentSongs)
        })

        // 热门搜索
        items.append(makeListEntry(
            title: "热门搜索",
            detail: "选择热门关键词试听",
            image: image("magnifyingglass")
        ) { [weak self] in
            self?.pushHotSearch()
        })

        // 歌单广场
        items.append(makeListEntry(
            title: "歌单广场",
            detail: "按分类浏览歌单",
            image: image("square.grid.2x2")
        ) { [weak self] in
            self?.pushPlaylistTags()
        })

        return items
    }

    // 根模板只创建一次并强引用持有（否则系统会释放 -> 黑屏）。
    // 数据加载完成/重试时复用同一实例，仅 updateSections 刷新内容。
    private func buildRootTemplate(placeholder: Bool) {
        guard let controller = interfaceController else {
            log("buildRootTemplate skipped: no interfaceController")
            return
        }
        log("buildRootTemplate placeholder=\(placeholder) hasRoot=\(rootTemplate != nil)")

        if rootTemplate == nil {
            let section = CPListSection(items: placeholder ? [loadingItem()] : makeRootItems())
            let template = CPListTemplate(title: "LX音乐", sections: [section])
            rootTemplate = template
            log("created root template instance")
            setRootTemplateAnimatedFalse()
        } else {
            // 已有根模板：更新内容。保留强引用，不重建实例。
            let section = CPListSection(items: placeholder ? [loadingItem()] : makeRootItems())
            rootTemplate?.updateSections([section])
        }
    }

    private func setRootTemplateAnimatedFalse() {
        guard let controller = interfaceController, let template = rootTemplate else {
            log("setRootTemplate skipped: no controller or rootTemplate")
            return
        }
        // animated:false 避免 iOS15 动画阻塞；completion 在 iOS15 上不会回调，不依赖它。
        controller.setRootTemplate(template, animated: false, completion: nil)
        log("called setRootTemplate (retained instance)")
    }

    private func loadingItem() -> CPListItem {
        let loading = CPListItem(text: "正在加载…", detailText: nil)
        loading.handler = { _, completion in completion() }
        return loading
    }

    // MARK: - Playlists / Songs

    private func pushSongs(title: String, songs: [LXSong]) {
        guard let controller = interfaceController, !songs.isEmpty else { return }
        let items = songs.enumerated().map { idx, song in
            makeListEntry(
                title: song.name,
                detail: song.singer,
                image: image("music.note")
            ) { [weak self] in
                PlayerManager.shared.play(song: song, in: songs, index: idx)
                self?.pushNowPlaying()
            }
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushNowPlaying() {
        guard let controller = interfaceController else { return }
        controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    // MARK: - Hot search

    private func pushHotSearch() {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: "热门搜索", sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["加载中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let keywords = (try? await LXAPIClient.shared.getHotSearch(source: "kw")) ?? []
                let items = keywords.prefix(10).compactMap { keyword -> CPListItem? in
                    self?.makeListEntry(
                        title: keyword,
                        detail: "搜索并播放",
                        image: self?.image("magnifyingglass")
                    ) {
                        self?.pushSearchResults(keyword: keyword)
                    }
                }
                template.updateSections([CPListSection(items: items)])
            }
        }
    }

    private func pushSearchResults(keyword: String) {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: keyword, sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["搜索中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let songs = (try? await LXAPIClient.shared.search(name: keyword, source: "kw", page: 1, pages: 3)) ?? []
                let items = songs.enumerated().map { idx, song in
                    self?.makeListEntry(
                        title: song.name,
                        detail: song.singer,
                        image: self?.image("music.note")
                    ) {
                        PlayerManager.shared.play(song: song, in: songs, index: idx)
                        self?.pushNowPlaying()
                    }
                }
                .compactMap { $0 }
                template.updateSections([CPListSection(items: items)])
            }
        }
    }

    // MARK: - 歌单广场

    /// 服务器首次请求 songList/tags 可能返回空（冷缓存/上游未就绪），自动重试几次自愈。
    @MainActor
    private func fetchTagsRetrying(source: String) async -> [(name: String, id: String)] {
        for attempt in 0..<3 {
            if let tags = try? await LXAPIClient.shared.getSongListTags(source: source), !tags.isEmpty {
                return tags
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        return []
    }

    private func pushPlaylistTags() {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: "歌单广场", sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["加载中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let tags = await self?.fetchTagsRetrying(source: "kw") ?? []
                var items = [self?.makeListEntry(
                    title: "推荐",
                    detail: "热门歌单",
                    image: self?.image("star")
                ) {
                    self?.pushPlaylists(tagName: "推荐", tagID: nil)
                }]
                for tag in tags {
                    items.append(self?.makeListEntry(
                        title: tag.name,
                        detail: "浏览歌单",
                        image: self?.image("music.note.list")
                    ) {
                        self?.pushPlaylists(tagName: tag.name, tagID: tag.id)
                    })
                }
                template.updateSections([CPListSection(items: items.compactMap { $0 })])
            }
        }
    }

    private func pushPlaylists(tagName: String, tagID: String?) {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: tagName, sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["加载中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let playlists = (try? await LXAPIClient.shared.getSongListByTag(source: "kw", tagId: tagID)) ?? []
                let items = playlists.map { pl in
                    self?.makeListEntry(
                        title: pl.name,
                        detail: "\(pl.songCount) 首 · \(pl.author)",
                        image: self?.image("music.note.list")
                    ) {
                        self?.pushPlaylistSongs(playlist: pl)
                    }
                }
                template.updateSections([CPListSection(items: items.compactMap { $0 })])
            }
        }
    }

    private func pushPlaylistSongs(playlist: LXOnlinePlaylist) {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: playlist.name, sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["加载中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let songs = (try? await LXAPIClient.shared.getSongListDetail(source: "kw", playlistID: playlist.id)) ?? []
                let items = songs.enumerated().map { idx, song in
                    self?.makeListEntry(
                        title: song.name,
                        detail: song.singer,
                        image: self?.image("music.note")
                    ) {
                        PlayerManager.shared.play(song: song, in: songs, index: idx)
                        self?.pushNowPlaying()
                    }
                }
                template.updateSections([CPListSection(items: items.compactMap { $0 })])
            }
        }
    }

    // MARK: - Helpers

    private func makeListEntry(title: String, detail: String, image: UIImage?, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: detail,
            image: image,
            accessoryImage: nil,
            accessoryType: .disclosureIndicator
        )
        item.handler = { _, completion in
            action()
            completion()
        }
        return item
    }

    private func image(_ name: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        return UIImage(systemName: name, withConfiguration: config)?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
    }
}
