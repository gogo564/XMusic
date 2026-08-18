import SwiftUI

// CarPlay 窗口自绘 UI(参考 CarTube 的 UIWindowSceneSessionRoleCarPlay 路线,
// 不依赖 CPInterfaceController 模板系统,绕开 TrollStore 下模板渲染被拒的问题)。
// 排版参考音流/汽水的 CPListTemplate 风格:统一行高、左标题右副标题、
// 固定大字号、分组清晰。iOS 15 兼容:用 NavigationView,不用 NavigationStack。

struct CarPlayRootView: View {
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var player = PlayerManager.shared
    @StateObject private var recentStore = RecentStore.shared
    @State private var loaded = false

    var body: some View {
        NavigationView {
            List {
                if player.currentSong != nil {
                    Section {
                        CarPlayNowPlayingRow()
                    }
                }
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
            }
            .listStyle(.insetGrouped)
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

// 列表项通用排版:固定两行(标题 + 副标题),模拟 CPListTemplate 的行样式
private struct CarPlayListRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 22, weight: .regular))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
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
            CarPlayListRowLabel(title: title, subtitle: "\(count) 首")
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
                Log.write("[CarPlay] 点击播放: \(song.name)")
                player.play(song: song, in: songs, index: idx, presentPlayer: false, sceneName: "CarPlay")
            } label: {
                CarPlayListRowLabel(title: song.name, subtitle: song.singer)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
    }
}

// 车机上的"正在播放"入口行
private struct CarPlayNowPlayingRow: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        NavigationLink {
            CarPlayPlayerView()
        } label: {
            HStack {
                // 封面占位:统一尺寸,避免大小参差
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 56, height: 56)
                CarPlayListRowLabel(
                    title: player.currentSong?.name ?? "未在播放",
                    subtitle: player.currentSong?.singer ?? ""
                )
                Spacer()
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
            }
        }
    }
}

// 车机上的完整播放页:歌名/歌手 + 歌词 + 进度条 + 播放控制
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            VStack(spacing: 6) {
                Text(player.currentSong?.name ?? "未在播放")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(player.currentSong?.singer ?? "")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let line = currentLyricLine() {
                Text(line)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .id(player.currentLyricIndex)
            }

            VStack(spacing: 6) {
                ProgressView(value: player.currentTime, total: max(player.duration, 1))
                    .padding(.horizontal)
                HStack {
                    Text(timeStr(player.currentTime))
                    Spacer()
                    Text(timeStr(player.duration))
                }
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.horizontal)
            }

            HStack(spacing: 48) {
                Button {
                    player.playPrevious()
                } label: {
                    Image(systemName: "backward.fill").font(.system(size: 34))
                }
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                Button {
                    player.playNext()
                } label: {
                    Image(systemName: "forward.fill").font(.system(size: 34))
                }
            }
            .padding(.top, 6)

            Spacer()
        }
        .navigationTitle("正在播放")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Log.write("[CarPlay] CarPlayPlayerView 出现 song=\(player.currentSong?.name ?? "nil")")
        }
    }

    private func currentLyricLine() -> String? {
        guard !player.parsedLyrics.isEmpty else { return nil }
        let idx = player.currentLyricIndex
        return player.parsedLyrics.indices.contains(idx) ? player.parsedLyrics[idx].text : player.parsedLyrics.last?.text
    }

    private func timeStr(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t) % 60
        let m = Int(t) / 60
        return "\(m):\(String(format: "%02d", s))"
    }
}