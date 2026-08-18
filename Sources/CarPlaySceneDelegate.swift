import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder,
    @preconcurrency CPTemplateApplicationSceneDelegate,
    @preconcurrency CPInterfaceControllerDelegate {

    private var interfaceController: CPInterfaceController?
    private var rootTemplate: CPListTemplate?
    private var rootTemplateSucceeded = false
    private var pendingRefresh = false

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
        // Apple 要求 didConnect 返回前必须设置根模板，否则黑屏。
        buildRootTemplate(placeholder: true)
        // 数据加载完成后，只在根模板已成功呈现时刷新内容；
        // 若还没成功（setRootTemplate completion 未回调），先标记，
        // 等 sceneDidBecomeActive 兜底重试成功后再刷新。
        Task { @MainActor in
            log("loading data")
            await PlaylistStore.shared.refresh()
            if rootTemplateSucceeded {
                log("data loaded, updating root")
                buildRootTemplate(placeholder: false)
            } else {
                log("data loaded, deferring root update")
                pendingRefresh = true
            }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log("didDisconnect")
        self.interfaceController = nil
        rootTemplate = nil
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        log("willConnectToSession role=\(session.role.rawValue)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        log("sceneDidBecomeActive role=\(scene.session.role.rawValue)")
        // 兜底（flutter_carplay 同款 force 更新）：场景激活时若车机当前没有任何根模板，
        // 说明之前的 setRootTemplate 未被接受（黑屏），强制重设。已呈现则不打扰。
        if let controller = interfaceController, controller.rootTemplate == nil, rootTemplate != nil {
            log("becomeActive: no root presented, forcing re-set")
            setRootTemplate()
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

    // 根模板只创建一次并强引用持有（iOS 15 上系统可能释放未持有的模板 -> 黑屏），
    // 数据加载完成时复用同一实例，仅 updateSections 刷新内容。
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
            setRootTemplate()
        } else {
            // 已有根模板：更新内容。保留强引用，不重建实例。
            let section = CPListSection(items: placeholder ? [loadingItem()] : makeRootItems())
            rootTemplate?.updateSections([section])
        }
    }

    private func setRootTemplate() {
        guard let controller = interfaceController, let template = rootTemplate else {
            log("setRootTemplate skipped: no controller or rootTemplate")
            return
        }
        // 与音流（flutter_carplay）一致：iOS 15 上只能用同步版 setRootTemplate(_:animated:)。
        // 带 completion 的版本在 iOS 15 有 bug，completion 永不回调 -> 模板从未呈现 -> 黑屏。
        // （同步版在 iOS 15 被标记 deprecated，但正是可行方案，flutter_carplay 同样这么用。）
        controller.setRootTemplate(template, animated: true)
        rootTemplateSucceeded = true
        log("setRootTemplate called (sync, deprecated-but-working)")
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

    // MARK: - CPInterfaceControllerDelegate（纯日志观测，不驱动任何行为）

    func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateWillAppear \(type(of: aTemplate)) animated=\(animated)")
    }

    func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateDidAppear \(type(of: aTemplate)) animated=\(animated)")
    }

    func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateWillDisappear \(type(of: aTemplate)) animated=\(animated)")
    }

    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        log("templateDidDisappear \(type(of: aTemplate)) animated=\(animated)")
    }
}
