import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var window: UIWindow?
    private var rootTemplate: CPListTemplate?

    private func log(_ message: String) {
        Log.write("[CarPlay] \(message)")
    }

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        log("didConnect")
        self.interfaceController = interfaceController
        // 参考官方 CarPlay Music / react-native-carplay：不设 guard，每次连接都重建根模板，
        // 避免车机断开重连或 scene 重建时 didConnect 再次触发被拦截导致黑屏。
        // Apple 要求 didConnect 返回前必须设置根模板，否则黑屏。
        buildRootTemplate(placeholder: true)
        // 延迟兜底：连接初期界面可能不稳定，参考实现会在 2s 后重设一次根模板。
        // 仅当此时仍无根模板（说明首次 setRootTemplate 失败/未生效，界面黑屏）才补设。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, let controller = self.interfaceController,
                  controller.topTemplate == nil else { return }
            log("retry placeholder root after timeout (topTemplate==nil)")
            self.buildRootTemplate(placeholder: true)
        }
        Task { @MainActor in
            log("loading data")
            await PlaylistStore.shared.refresh()
            log("data loaded, rebuilding root")
            buildRootTemplate(placeholder: false)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        log("didDisconnect")
        self.interfaceController = nil
        self.window = nil
        rootTemplate = nil
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        log("willConnectTo session role=\(session.role.rawValue)")
        if session.role == UISceneSession.Role.carTemplateApplication {
            self.window = UIWindow(windowScene: scene as! CPTemplateApplicationScene)
            // CarPlay 不需要手动显示 window；这里仅持有避免释放
        }
    }

    // MARK: - Root

    private func buildRootTemplate(placeholder: Bool) {
        guard let controller = interfaceController else {
            log("buildRootTemplate skipped: no interfaceController")
            return
        }
        log("buildRootTemplate placeholder=\(placeholder) topTemplate=\(String(describing: controller.topTemplate))")

        var items: [CPListItem] = []

        if placeholder {
            // 数据未就绪：先放一个"加载中"占位，避免空根模板导致黑屏
            let loading = CPListItem(text: "正在加载…", detailText: nil)
            loading.handler = { _, completion in completion() }
            let template = CPListTemplate(title: "LX音乐", sections: [CPListSection(items: [loading])])
            controller.setRootTemplate(template, animated: true) { success, error in
                self.log("placeholder setRoot success=\(success) error=\(String(describing: error))")
            }
            return
        }

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

        let section = CPListSection(items: items)
        if controller.topTemplate is CPListTemplate {
            if let current = controller.topTemplate as? CPListTemplate {
                current.updateSections([section])
            }
        } else {
            let template = CPListTemplate(title: "LX音乐", sections: [section])
            controller.setRootTemplate(template, animated: true) { success, error in
                if let error = error {
                    self.log("setRootTemplate error: \(error.localizedDescription)")
                } else if !success {
                    self.log("setRootTemplate did not succeed")
                } else {
                    self.log("setRootTemplate success")
                }
            }
        }
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

    private func pushPlaylistTags() {
        guard let controller = interfaceController else { return }
        let template = CPListTemplate(title: "歌单广场", sections: [CPListSection(items: [])])
        template.emptyViewTitleVariants = ["加载中…"]
        controller.pushTemplate(template, animated: true) { [weak self] _, _ in
            Task { @MainActor in
                let tags = (try? await LXAPIClient.shared.getSongListTags(source: "kw")) ?? []
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
