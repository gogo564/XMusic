import Foundation
import Combine

/// 汽水歌单本地收藏存储（UserDefaults 持久化）。
/// 汽水歌单来自 qishui-api，lx-sync-server 不认识，因此收藏不上服务器，
/// 这里本地保存收藏列表，"我的"页可点开加载并播放。
final class SodaPlaylistStore: ObservableObject {
    static let shared = SodaPlaylistStore()

    @Published var loved: [SodaAPIClient.SodaPlaylist] = []

    private let key = "LovedSodaPlaylists_v1"
    private var loaded = false

    private init() { load() }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        if let list = try? JSONDecoder().decode([SodaAPIClient.SodaPlaylist].self, from: data) {
            loved = list
        }
    }

    func isLoved(_ playlist: SodaAPIClient.SodaPlaylist) -> Bool {
        loved.contains { $0.id == playlist.id }
    }

    func toggle(_ playlist: SodaAPIClient.SodaPlaylist) {
        if isLoved(playlist) {
            loved.removeAll { $0.id == playlist.id }
        } else {
            loved.insert(playlist, at: 0)
        }
        save()
    }

    func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            if loved.indices.contains(index) { loved.remove(at: index) }
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(loved) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
