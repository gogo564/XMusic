import CarPlay
import UIKit

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var window: UIWindow?
    private var didConnect = false

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        guard !didConnect else { return }
        didConnect = true
        buildRootTemplate()
        Task { @MainActor in
            await PlaylistStore.shared.refresh()
            buildRootTemplate()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.window = nil
        didConnect = false
    }

    // MARK: - Root

    private func buildRootTemplate() {
        guard let controller = interfaceController else { return }

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

        let section = CPListSection(items: items)
        if controller.topTemplate is CPListTemplate {
            if let current = controller.topTemplate as? CPListTemplate {
                current.updateSections([section])
            }
        } else {
            let template = CPListTemplate(title: "LX音乐", sections: [section])
            controller.setRootTemplate(template, animated: true) { success, error in
                if let error = error {
                    NSLog("CarPlay setRootTemplate error: \(error.localizedDescription)")
                } else if !success {
                    NSLog("CarPlay setRootTemplate did not succeed")
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
