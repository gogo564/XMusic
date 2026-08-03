import CarPlay
import UIKit

final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var window: UIWindow?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: UIWindow?
    ) {
        self.interfaceController = interfaceController
        self.window = window
        window?.isHidden = false
        buildRootTemplate()
        Task { @MainActor in
            await PlaylistStore.shared.refresh()
            buildRootTemplate()
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: UIWindow?
    ) {
        self.interfaceController = nil
        self.window = nil
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

        let section = CPListSection(items: items)
        if controller.topTemplate is CPListTemplate {
            if let current = controller.topTemplate as? CPListTemplate {
                current.updateSections([section])
            }
        } else {
            let template = CPListTemplate(title: "LX音乐", sections: [section])
            controller.setRootTemplate(template, animated: false, completion: nil)
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
                let keywords = (try? await LXAPIClient.shared.getHotSearch(source: "mg")) ?? []
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
                let songs = (try? await LXAPIClient.shared.search(name: keyword, source: "mg", page: 1, pages: 3)) ?? []
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

    // MARK: - Helpers

    private func makeListEntry(title: String, detail: String, image: UIImage?, action: @escaping () -> Void) -> CPListItem {
        let item = CPListItem(
            text: title,
            detailText: detail,
            image: image,
            accessoryType: .disclosureIndicator,
            handler: { _, completion in
                action()
                completion()
            }
        )
        return item
    }

    private func image(_ name: String) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        return UIImage(systemName: name, withConfiguration: config)?.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
    }
}
