import SwiftUI

private enum Tab: String, CaseIterable, Identifiable {
    case playlists = "歌单"
    case recent = "最近"
    case nowPlaying = "正在播放"
    var id: String { rawValue }
}

// CarPlay 窗口自绘 UI(参考 CarTube 的 UIWindowSceneSessionRoleCarPlay 路线,
// 不依赖 CPInterfaceController 模板系统,绕开 TrollStore 下模板渲染被拒的问题)。
//
// 关键点:
// 1) CarPlay 系统把 contentSizeCategory 设为 accessibility 极大档,SwiftUI 默认
//    .font(.system(size:)) 会随 Dynamic Type 缩放导致文字超大,所以整棵树固定
//    .environment(\.sizeCategory, .large)。
// 2) 主页(歌单/最近)改用原生 CarPlay 列表行:左侧小封面 + 右侧标题/副标题,
//    一屏可看多行、比例协调,不再用会溢出的大卡片网格。
// 3) 播放页重排为左大封面 + 右侧歌名/歌手/进度 + 下方控制排,封面与字号均由
//    GeometryReader 几何尺寸等比推导,任何车机分辨率都不会超出范围。

struct CarPlayRootView: View {
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var player = PlayerManager.shared
    @StateObject private var recentStore = RecentStore.shared
    @State private var loaded = false

    @State private var selectedTab: Tab = .playlists

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                CarPlayTabBar(selected: $selectedTab)
                Group {
                    switch selectedTab {
                    case .playlists:
                        playlistList
                    case .recent:
                        recentList
                    case .nowPlaying:
                        nowPlayingView
                    }
                }
            }
            .navigationTitle("LX音乐")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - 歌单列表(原生 CarPlay 列表行)
    private var playlistList: some View {
        List {
            CarPlayNavRow(
                title: "我喜欢的音乐",
                subtitle: "\(playlistStore.songs(kind: .love, playlistID: "").count) 首",
                coverURL: playlistStore.songs(kind: .love, playlistID: "").first?.imageURL ?? ""
            ) {
                CarPlaySongList(title: "我喜欢的音乐", songs: playlistStore.songs(kind: .love, playlistID: ""))
            }
            CarPlayNavRow(
                title: "默认列表",
                subtitle: "\(playlistStore.songs(kind: .defaultList, playlistID: "").count) 首",
                coverURL: playlistStore.songs(kind: .defaultList, playlistID: "").first?.imageURL ?? ""
            ) {
                CarPlaySongList(title: "默认列表", songs: playlistStore.songs(kind: .defaultList, playlistID: ""))
            }
            ForEach(playlistStore.playlists, id: \.id) { pl in
                CarPlayNavRow(
                    title: pl.name,
                    subtitle: "\(playlistStore.songs(kind: .user, playlistID: pl.id).count) 首",
                    coverURL: playlistStore.songs(kind: .user, playlistID: pl.id).first?.imageURL ?? ""
                ) {
                    CarPlaySongList(title: pl.name, songs: playlistStore.songs(kind: .user, playlistID: pl.id))
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - 最近播放列表
    private var recentList: some View {
        let songs = recentStore.items.compactMap { $0.song }
        return Group {
            if songs.isEmpty {
                VStack {
                    Spacer()
                    Text("暂无最近播放")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(songs.indices, id: \.self) { idx in
                        let song = songs[idx]
                        CarPlayNavRow(title: song.name, subtitle: song.singer, coverURL: song.imageURL) {
                            CarPlaySongList(title: "最近播放", songs: songs)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 正在播放视图
    private var nowPlayingView: some View {
        VStack {
            if player.currentSong != nil {
                CarPlayPlayerView()
            } else {
                Spacer()
                Text("当前没有正在播放的歌曲")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}

// 顶部功能标签栏
private struct CarPlayTabBar: View {
    @Binding var selected: Tab
    private let tabs: [(Tab, String)] = [
        (.playlists, "list.bullet.rectangle"),
        (.recent, "clock"),
        (.nowPlaying, "play.circle"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs, id: \.0) { tab, icon in
                Button {
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 16))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selected == tab ? .bold : .regular))
                    }
                    .foregroundColor(selected == tab ? Color(.systemOrange) : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected == tab ? Color(.systemOrange).opacity(0.18) : Color.clear)
                    )
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// 列表行:行首封面(有图用真封面,无图用音符占位)+ 标题/副标题(用于歌曲列表)
private struct CarPlayListRow: View {
    let title: String
    let subtitle: String
    var coverURL: String = ""
    var isNowPlaying = false

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: isNowPlaying ? .bold : .medium))
                    .foregroundColor(isNowPlaying ? Color(.systemOrange) : .primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 17))
                    .foregroundColor(Color(.systemOrange))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var artwork: some View {
        if coverURL.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 15))
                        .foregroundColor(Color.gray.opacity(0.7))
                )
        } else {
            LXCachedImage(urlString: coverURL, placeholder: "music.note", size: 40, cornerRadius: 8)
        }
    }
}

// 主页导航行:左侧 56 小封面 + 右侧标题/副标题 + 右箭头(用于歌单/最近)
private struct CarPlayNavRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let coverURL: String
    @ViewBuilder var destination: Destination

    init(title: String, subtitle: String, coverURL: String = "", @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var artwork: some View {
        if coverURL.isEmpty {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.26, green: 0.27, blue: 0.33), Color(red: 0.13, green: 0.13, blue: 0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundColor(Color.white.opacity(0.4))
                )
        } else {
            LXCachedImage(urlString: coverURL, placeholder: "music.note", size: 56, cornerRadius: 10)
        }
    }
}

// 歌单内歌曲列表(点击即播放)
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
                CarPlayListRow(
                    title: song.name,
                    subtitle: song.singer,
                    coverURL: song.imageURL,
                    isNowPlaying: song.id == player.currentSong?.id
                )
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.sizeCategory, .large)
    }
}

// 车机播放页(自绘,仿音流/Apple CarPlay 原生观感):
// 左大封面 + 右(歌名/歌手/进度) + 下方控制排(随机/循环 | 上一首/播放/下一首 | 收藏/更多)。
// 关键:封面与字号均由 GeometryReader 几何尺寸等比推导,任何分辨率都套在框内不溢出。
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padH: CGFloat = 16
            let padV: CGFloat = 12
            // 封面边长:按窗口比例推导,横向不超过 40%、纵向不超过 52%,下限 84 点
            let cover = max(84, min(w * 0.40, h * 0.52))
            let titleSize = max(17, cover * 0.16)
            let subSize = max(12, cover * 0.11)
            let ctrlSize = max(18, cover * 0.17)
            let playSize = max(28, cover * 0.26)

            VStack(spacing: 10) {
                HStack(alignment: .center, spacing: 18) {
                    // 左:大封面
                    LXCachedImage(
                        urlString: player.currentSong?.imageURL ?? "",
                        placeholder: "music.note",
                        size: cover,
                        cornerRadius: 12
                    )
                    .frame(width: cover, height: cover)

                    // 右:歌名/歌手/专辑/进度
                    VStack(alignment: .leading, spacing: 5) {
                        Text(player.currentSong?.name ?? "未在播放")
                            .font(.system(size: titleSize, weight: .bold))
                            .lineLimit(1)
                        if let s = player.currentSong?.singer, !s.isEmpty {
                            Text(s)
                                .font(.system(size: subSize, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let a = player.currentSong?.albumName, !a.isEmpty, a != player.currentSong?.singer {
                            Text(a)
                                .font(.system(size: subSize * 0.9, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let line = currentLyricLine() {
                            Text(line)
                                .font(.system(size: subSize * 0.9, weight: .medium))
                                .foregroundColor(Color(.systemOrange).opacity(0.85))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 3) {
                            ProgressView(value: player.currentTime, total: max(player.duration, 1))
                                .tint(Color(.systemOrange))
                            HStack {
                                Text(timeStr(player.currentTime))
                                Spacer()
                                Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
                            }
                            .font(.system(size: subSize * 0.8))
                            .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 0)

                // 下方控制排
                HStack(spacing: 0) {
                    HStack(spacing: 14) {
                        actionButton("shuffle", love: false) { }
                        actionButton("repeat", love: false) { }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 24) {
                        Button { player.playPrevious() } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: ctrlSize))
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: playSize))
                        }
                        Button { player.playNext() } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: ctrlSize))
                        }
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        actionButton(player.currentSong.map { playlistStore.isLoved($0) } ?? false
                            ? "suit.heart.fill" : "suit.heart", love: true) {
                            guard let song = player.currentSong else { return }
                            if playlistStore.isLoved(song) {
                                Task { try? await playlistStore.removeSongFromLove(song) }
                            } else {
                                Task { try? await playlistStore.addSongToLove(song) }
                                HapticManager.shared.notification(type: .success)
                            }
                        }
                        actionButton("ellipsis.circle", love: false) { }
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .frame(width: w, height: h, alignment: .center)
        }
        .navigationTitle("正在播放")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.sizeCategory, .large)
        .onAppear {
            Log.write("[CarPlay] CarPlayPlayerView 出现 song=\(player.currentSong?.name ?? "nil")")
        }
    }

    private func actionButton(_ icon: String, love: Bool, action: @escaping () -> Void) -> some View {
        let on = player.currentSong.map { playlistStore.isLoved($0) } ?? false
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundColor((love && on) ? Color(.systemRed) : .primary)
                .frame(width: 38, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill((love && on) ? Color(.systemRed).opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
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