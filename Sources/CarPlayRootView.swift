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
//    .font(.system(size:)) 会随 Dynamic Type 缩放导致文字超大、超出横屏(426x240)显示不全,
//    所以整棵树固定 .environment(\.sizeCategory, .large)。
// 2) 播放页用 ScrollView + GeometryReader,高度不足时滚动而不被裁切。
// 3) iOS 15 兼容:NavigationView,不用 NavigationStack;nowplaying 行避免 NavigationLink
//    内嵌 Button(点击冲突导致空白),用 overlay 按钮 + .borderless。
// 4) 排版参考 Apple CarPlay HIG:深色底、大行距、行首封面图;播放页为左侧大封面 +
//    右侧歌名/歌词/进度/控制 的车机经典布局。

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
                        playlistGrid
                    case .recent:
                        recentGrid
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

    // MARK: - 2×2 大卡片网格(本地歌单)
    private var playlistGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                CarPlayCardNavLink(
                    title: "我喜欢的音乐",
                    count: playlistStore.songs(kind: .love, playlistID: "").count,
                    coverURL: playlistStore.songs(kind: .love, playlistID: "").first?.imageURL ?? ""
                ) {
                    CarPlaySongList(title: "我喜欢的音乐", songs: playlistStore.songs(kind: .love, playlistID: ""))
                }
                CarPlayCardNavLink(
                    title: "默认列表",
                    count: playlistStore.songs(kind: .defaultList, playlistID: "").count,
                    coverURL: playlistStore.songs(kind: .defaultList, playlistID: "").first?.imageURL ?? ""
                ) {
                    CarPlaySongList(title: "默认列表", songs: playlistStore.songs(kind: .defaultList, playlistID: ""))
                }
                ForEach(playlistStore.playlists, id: \.id) { pl in
                    CarPlayCardNavLink(
                        title: pl.name,
                        count: playlistStore.songs(kind: .user, playlistID: pl.id).count,
                        coverURL: playlistStore.songs(kind: .user, playlistID: pl.id).first?.imageURL ?? ""
                    ) {
                        CarPlaySongList(title: pl.name, songs: playlistStore.songs(kind: .user, playlistID: pl.id))
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: - 最近播放网格
    private var recentGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                ForEach(recentStore.items.prefix(6), id: \.id) { item in
                    if let song = item.song {
                        CarPlayCardNavLink(
                            title: song.name,
                            count: 0,
                            coverURL: song.imageURL
                        ) {
                            CarPlaySongList(title: "最近播放", songs: recentStore.items.compactMap { $0.song })
                        }
                    }
                }
            }
            .padding(14)
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
                            .font(.system(size: 19))
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: selected == tab ? .bold : .regular))
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

// 列表行:行首封面(有图用真封面,无图用音符占位)+ 标题/副标题
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
                    .font(.system(size: 18, weight: isNowPlaying ? .bold : .medium))
                    .foregroundColor(isNowPlaying ? Color(.systemOrange) : .primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Color(.systemOrange))
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var artwork: some View {
        if coverURL.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 16))
                        .foregroundColor(Color.gray.opacity(0.7))
                )
        } else {
            LXCachedImage(urlString: coverURL, placeholder: "music.note", size: 44, cornerRadius: 8)
        }
    }
}

private struct CarPlayCardNavLink<Destination: View>: View {
    let title: String
    let count: Int
    let coverURL: String
    @ViewBuilder var destination: Destination

    init(title: String, count: Int, coverURL: String = "", @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.count = count
        self.coverURL = coverURL
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            VStack(spacing: 5) {
                artwork
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count) 首")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.13, green: 0.13, blue: 0.14))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var artwork: some View {
        if coverURL.isEmpty {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.gray.opacity(0.22))
                .frame(height: 76)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 26))
                        .foregroundColor(Color.gray.opacity(0.7))
                )
        } else {
            LXCachedImage(urlString: coverURL, placeholder: "music.note", size: 76, cornerRadius: 10)
                .frame(height: 76)
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
                CarPlayListRow(
                    title: song.name,
                    subtitle: song.singer,
                    coverURL: song.imageURL,
                    isNowPlaying: song.id == player.currentSong?.id
                )
            }
        }
        .listStyle(.insetGrouped)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.sizeCategory, .large)
    }
}

// 车机播放页(自绘,仿音流 CarPlay 模板观感):
// 右侧封面(≤35%宽)+ 左({歌名|歌手|专辑}三行) + 居中控制排 + 全宽进度 + 底部(随机/循环/单曲/收藏/更多)。
// 关键:整块固定为 geo 尺寸,用 clamp 封面 + Spacer 布局,保证 426×240 下不溢出、不触发 ScrollView 拉伸。
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cover = min(max(w * 0.30, 84), min(h * 0.52, 118)) // 右侧封面:占宽≤30%、高≤52%,顶边界留白

            VStack(spacing: 8) {
                // 上行:左侧信息 + 右侧封面
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.currentSong?.name ?? "未在播放")
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                        if let s = player.currentSong?.singer, !s.isEmpty {
                            Text(s)
                                .font(.system(size: 14, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let a = player.currentSong?.albumName, !a.isEmpty, a != player.currentSong?.singer {
                            Text(a)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let line = currentLyricLine() {
                            Text(line)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(.systemOrange).opacity(0.9))
                                .lineLimit(1)
                                .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: w * 0.55, minHeight: 0, alignment: .leading)

                    Spacer(minLength: 0)

                    LXCachedImage(
                        urlString: player.currentSong?.imageURL ?? "",
                        placeholder: "music.note",
                        size: cover,
                        cornerRadius: 12
                    )
                }

                // 中部控制排
                HStack(spacing: 0) {
                    HStack(spacing: 40) {
                        Button { player.playPrevious() } label: {
                            Image(systemName: "backward.fill").font(.system(size: 24))
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 40))
                        }
                        Button { player.playNext() } label: {
                            Image(systemName: "forward.fill").font(.system(size: 24))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderless)

                // 进度条 + 时间
                VStack(spacing: 3) {
                    ProgressView(value: player.currentTime, total: max(player.duration, 1))
                        .tint(Color(.systemOrange))
                    HStack {
                        Text(timeStr(player.currentTime))
                        Spacer()
                        Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }

                // 底部功能栏
                HStack {
                    actionButton("shuffle", love: false) { }
                    actionButton("repeat", love: false) { }
                    Spacer()
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
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
                .font(.system(size: 22))
                .foregroundColor((love && on) ? Color(.systemRed) : .primary)
                .frame(width: 44, height: 40)
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