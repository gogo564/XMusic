import SwiftUI

// CarPlay 窗口自绘 UI(参考 CarTube 的 UIWindowSceneSessionRoleCarPlay 路线,
// 不依赖 CPInterfaceController 模板系统,绕开 TrollStore 下模板渲染被拒的问题)。
//
// 关键点:
// 1) CarPlay 系统把 contentSizeCategory 设为 accessibility 极大档,SwiftUI 默认
//    .font(.system(size:)) 会随 Dynamic Type 缩放导致文字超大、超出横屏(426x240)显示不全,
//    所以整棵树固定 .environment(\.sizeCategory, .large)。
// 2) 播放页用 ScrollView + GeometryReader,高度不足时滚动而不被裁切。
// 3) iOS 15 兼容:NavigationView,不用 NavigationStack;nowplaying 行避免 NavigationLink
//    内嵌 Button(点击冲突导致空白),用 overlay 按钮 + .borderless。

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
            // 关键:锁定字体缩放,CarPlay 上 accessibility 档会让文字过大溢出
            .environment(\.sizeCategory, .large)
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

// 列表项排版:标题 + 副标题,统一字号(参考音流/汽水列表的整洁感)
private struct CarPlayListRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .regular))
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
        .environment(\.sizeCategory, .large)
    }
}

// "正在播放"入口行:整行可点击进播放页,播放/暂停作为独立 borderless 按钮放右侧
// (避免 NavigationLink 内嵌 Button 在 iOS 15 点击冲突导致空白页)
private struct CarPlayNowPlayingRow: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            NavigationLink {
                CarPlayPlayerView()
            } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.25))
                        .frame(width: 44, height: 44)
                    CarPlayListRowLabel(
                        title: player.currentSong?.name ?? "未在播放",
                        subtitle: player.currentSong?.singer ?? ""
                    )
                    Spacer()
                    // 占位,保持整行可点;真正按钮在 overlay
                    Color.clear.frame(width: 48, height: 44)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                    .padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
        }
    }
}

// 车机播放页:歌名/歌手 + 歌词 + 进度 + 控制,ScrollView 防裁切
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text(player.currentSong?.name ?? "未在播放")
                            .font(.system(size: 22, weight: .bold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text(player.currentSong?.singer ?? "")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.top, 12)

                    if let line = currentLyricLine() {
                        Text(line)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(3)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .id(player.currentLyricIndex)
                    }

                    VStack(spacing: 4) {
                        ProgressView(value: player.currentTime, total: max(player.duration, 1))
                            .padding(.horizontal, 8)
                        HStack {
                            Text(timeStr(player.currentTime))
                            Spacer()
                            Text(timeStr(player.duration))
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                    }
                    .padding(.top, 4)

                    HStack(spacing: 56) {
                        Button {
                            player.playPrevious()
                        } label: {
                            Image(systemName: "backward.fill").font(.system(size: 30))
                        }
                        .buttonStyle(.borderless)

                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 52))
                        }
                        .buttonStyle(.borderless)

                        Button {
                            player.playNext()
                        } label: {
                            Image(systemName: "forward.fill").font(.system(size: 30))
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.top, 4)

                    Spacer(minLength: 12)
                }
                .frame(minHeight: geo.size.height)
                .padding(.horizontal, 12)
            }
        }
        .navigationTitle("正在播放")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.sizeCategory, .large)
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