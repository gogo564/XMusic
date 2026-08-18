import SwiftUI

// CarPlay 窗口自绘 UI(参考 CarTube 的 UIWindowSceneSessionRoleCarPlay 路线,
// 不依赖 CPInterfaceController 模板系统,绕开 TrollStore 下模板渲染被拒的问题)。
// iOS 15 兼容:用 NavigationView,不用 NavigationStack。

struct CarPlayRootView: View {
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var player = PlayerManager.shared
    @StateObject private var recentStore = RecentStore.shared
    @State private var loaded = false

    var body: some View {
        NavigationView {
            List {
                Section("本地歌单") {
                    CarPlayNavLink(
                        title: "我喜欢的音乐",
                        count: playlistStore.songs(kind: .love, playlistID: "").count
                    ) {
                        CarPlaySongList(title: "我喜欢的音乐", songs: playlistStore.songs(kind: .love, playlistID: ""))
                    }
                    CarPlayNavLink(
                        title: "默认列表",
                        count: playlistStore.songs(kind: .defaultList, playlistID: "").count
                    ) {
                        CarPlaySongList(title: "默认列表", songs: playlistStore.songs(kind: .defaultList, playlistID: ""))
                    }
                    ForEach(playlistStore.playlists, id: \.id) { pl in
                        CarPlayNavLink(
                            title: pl.name,
                            count: playlistStore.songs(kind: .user, playlistID: pl.id).count
                        ) {
                            CarPlaySongList(title: pl.name, songs: playlistStore.songs(kind: .user, playlistID: pl.id))
                        }
                    }
                }
                Section("最近播放") {
                    CarPlayNavLink(
                        title: "最近播放",
                        count: recentStore.items.count
                    ) {
                        CarPlaySongList(title: "最近播放", songs: recentStore.items.compactMap { $0.song })
                    }
                }
                if player.currentSong != nil {
                    Section {
                        CarPlayNowPlaying()
                    }
                }
            }
            .navigationTitle("LX音乐")
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if !loaded {
                loaded = true
                Task { await playlistStore.refresh() }
            }
        }
    }
}

private struct CarPlayNavLink<Destination: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var destination: Destination

    init(title: String, count: Int, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.count = count
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct CarPlaySongList: View {
    let title: String
    let songs: [LXSong]
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        List(songs.indices, id: \.self) { idx in
            let song = songs[idx]
            Button {
                player.play(song: song, in: songs, index: idx, sceneName: "CarPlay")
            } label: {
                HStack {
                    Text(song.name).lineLimit(1)
                    Spacer()
                    Text(song.singer).lineLimit(1).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct CarPlayNowPlaying: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(player.currentSong?.name ?? "未在播放")
                    .lineLimit(1)
                Text(player.currentSong?.singer ?? "")
                    .lineLimit(1)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
        }
    }
}
