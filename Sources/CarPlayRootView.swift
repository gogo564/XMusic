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
                    .foregroundColor(selected == tab ? Color(.systemBlue) : .gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected == tab ? Color(.systemBlue).opacity(0.18) : Color.clear)
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

// 车机播放页(对齐参考图):顶部进度(两端时间) → 居中三键 → 底部封面 + 歌名/歌手。
// 字号与控件均由窗口高度等比推导并封顶,与顶部导航/列表字体比例保持一致,不溢出。
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padH = max(14, w * 0.022)
            let padV = max(10, h * 0.022)
            let cover = max(88, min(w * 0.24, h * 0.44))
            let titleSize = min(26, max(17, h * 0.055))
            let subSize = min(16, max(12, h * 0.033))
            let timeSize = min(13, max(10, h * 0.026))
            let ctrlSize = min(40, max(22, h * 0.062))
            let playSize = min(62, max(34, h * 0.098))

            VStack(spacing: 0) {
                progressBlock(timeSize: timeSize)
                Spacer(minLength: 8)
                controlRow(ctrlSize: ctrlSize, playSize: playSize)
                Spacer(minLength: 8)
                infoRow(cover: cover, titleSize: titleSize, subSize: subSize)
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

    // 进度:两端时间 + 细条(等宽数字,单行不压缩)
    private func progressBlock(timeSize: CGFloat) -> some View {
        VStack(spacing: 5) {
            ProgressView(value: min(player.currentTime, max(player.duration, 1)), total: max(player.duration, 1))
                .tint(Color(.systemBlue))
            HStack(spacing: 8) {
                Text(timeStr(player.currentTime))
                Spacer(minLength: 8)
                Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
            }
            .font(.system(size: timeSize, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundColor(.secondary)
        }
    }

    // 控制:居中三键,播放键为白色圆角方块
    private func controlRow(ctrlSize: CGFloat, playSize: CGFloat) -> some View {
        HStack(spacing: max(28, playSize * 0.9)) {
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: ctrlSize))
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: playSize * 0.42, weight: .bold))
                    .foregroundColor(Color.black)
                    .frame(width: playSize, height: playSize)
                    .background(
                        RoundedRectangle(cornerRadius: playSize * 0.22, style: .continuous)
                            .fill(Color.white)
                    )
            }
            Button { player.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: ctrlSize))
            }
        }
        .foregroundColor(Color(.systemBlue))
        .buttonStyle(.borderless)
    }

    // 信息:左封面 + 右歌名/歌手/专辑/歌词 + 收藏
    private func infoRow(cover: CGFloat, titleSize: CGFloat, subSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 16) {
            LXCachedImage(
                urlString: player.currentSong?.imageURL ?? "",
                placeholder: "music.note",
                size: cover,
                cornerRadius: 12
            )
            .frame(width: cover, height: cover)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.currentSong?.name ?? "未在播放")
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(1)
                if let s = player.currentSong?.singer, !s.isEmpty {
                    Text(s)
                        .font(.system(size: subSize))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let a = player.currentSong?.albumName, !a.isEmpty, a != player.currentSong?.singer {
                    Text(a)
                        .font(.system(size: subSize * 0.92))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let line = currentLyricLine() {
                    Text(line)
                        .font(.system(size: subSize * 0.92, weight: .medium))
                        .foregroundColor(Color(.systemBlue).opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                guard let song = player.currentSong else { return }
                if playlistStore.isLoved(song) {
                    Task { try? await playlistStore.removeSongFromLove(song) }
                } else {
                    Task { try? await playlistStore.addSongToLove(song) }
                    HapticManager.shared.notification(type: .success)
                }
            } label: {
                Image(systemName: isLoved ? "heart.fill" : "heart")
                    .font(.system(size: min(24, max(16, cover * 0.20)))
                    .foregroundColor(isLoved ? Color(.systemRed) : .secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var isLoved: Bool {
        player.currentSong.map { playlistStore.isLoved($0) } ?? false
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
