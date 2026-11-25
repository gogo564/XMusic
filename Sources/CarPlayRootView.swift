import SwiftUI

private enum Tab: String, CaseIterable, Identifiable {
    case playlists = "歌单"
    case recent = "最近"
    case nowPlaying = "正在播放"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .recent: return "clock.arrow.circlepath"
        case .nowPlaying: return "play.circle"
        }
    }
}

/// 统一强调色（对齐酷狗/网易云 CarPlay 的青色）
private let cpAccent = Color(red: 0.20, green: 0.84, blue: 0.95)

private struct OpenPlaylist: Identifiable {
    let id = UUID()
    let title: String
    let songs: [LXSong]
}

// CarPlay 窗口自绘 UI（UIWindowSceneSessionRoleCarPlay 路线，不依赖 CPInterfaceController 模板）。
//
// 布局参考：
// 1) 列表页参考酷狗 CarPlay：顶部图标 + 文字标签，全宽圆角卡片行（封面 + 标题 + 副标题 + 箭头）。
// 2) 播放页参考网易云 CarPlay：左上返回、右上应用名、左侧歌名/歌手 + 大方块控制键 + 进度，
//    底部随机/收藏/循环，右侧大封面，封面模糊铺底。
// 3) 交互参考网易云：点歌曲直接播放并进入播放页，返回回到原列表。
//
// 注意：CarPlay 会把 contentSizeCategory 设为 accessibility 极大档，
// 这里整棵树固定 .environment(\.sizeCategory, .large)，字号全部用固定值 + 几何推导。
struct CarPlayRootView: View {
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var player = PlayerManager.shared
    @StateObject private var recentStore = RecentStore.shared

    @State private var loaded = false
    @State private var tab: Tab = .playlists
    @State private var openPlaylist: OpenPlaylist?
    @State private var showPlayer = false

    var body: some View {
        ZStack {
            background

            if let open = openPlaylist {
                songListPage(open)
            } else {
                VStack(spacing: 0) {
                    CarPlayTabBar(selected: $tab)
                    Group {
                        switch tab {
                        case .playlists:
                            playlistPage
                        case .recent:
                            recentPage
                        case .nowPlaying:
                            CarPlayPlayerPage(showBack: false, onBack: {})
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if showPlayer {
                CarPlayPlayerPage(showBack: true, onBack: { showPlayer = false })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        // 关键：锁定字体缩放，CarPlay 的 accessibility 档会让文字过大溢出
        .environment(\.sizeCategory, .large)
        .preferredColorScheme(.dark)
        .onAppear {
            if !loaded {
                loaded = true
                Task { await playlistStore.refresh() }
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color(red: 0.055, green: 0.06, blue: 0.075),
                     Color(red: 0.09, green: 0.095, blue: 0.115)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - 歌单页（酷狗式卡片列表）

    private var playlistPage: some View {
        let loveSongs = playlistStore.songs(kind: .love, playlistID: "")
        let defaultSongs = playlistStore.songs(kind: .defaultList, playlistID: "")
        return ScrollView {
            LazyVStack(spacing: 10) {
                NavigationRowButton(title: "我喜欢的音乐",
                                    subtitle: "\(loveSongs.count) 首",
                                    coverURL: loveSongs.first?.imageURL ?? "") {
                    openPlaylist = OpenPlaylist(title: "我喜欢的音乐", songs: loveSongs)
                }

                NavigationRowButton(title: "默认列表",
                                    subtitle: "\(defaultSongs.count) 首",
                                    coverURL: defaultSongs.first?.imageURL ?? "") {
                    openPlaylist = OpenPlaylist(title: "默认列表", songs: defaultSongs)
                }

                ForEach(playlistStore.playlists, id: \.id) { pl in
                    playlistRow(pl)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 16)
        }
    }

    private func playlistRow(_ pl: LXPlaylist) -> some View {
        let songs = playlistStore.songs(kind: .user, playlistID: pl.id)
        return NavigationRowButton(title: pl.name,
                                   subtitle: "\(songs.count) 首",
                                   coverURL: songs.first?.imageURL ?? "") {
            openPlaylist = OpenPlaylist(title: pl.name, songs: songs)
        }
    }

    // MARK: - 最近播放

    private var recentPage: some View {
        let songs = recentStore.items.compactMap { $0.song }
        return Group {
            if songs.isEmpty {
                emptyState("暂无最近播放")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(songs.indices, id: \.self) { idx in
                            let song = songs[idx]
                            Button {
                                playSong(song, in: songs, index: idx)
                            } label: {
                                SongRow(song: song,
                                        index: idx + 1,
                                        isCurrent: song.id == player.currentSong?.id,
                                        isPlaying: player.isPlaying)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    // MARK: - 歌单内歌曲列表

    private func songListPage(_ open: OpenPlaylist) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    openPlaylist = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 19, weight: .medium))
                    }
                    .foregroundColor(cpAccent)
                }
                .buttonStyle(.borderless)

                Spacer(minLength: 8)

                Text(open.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(open.songs.count) 首")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(open.songs.indices, id: \.self) { idx in
                        let song = open.songs[idx]
                        Button {
                            playSong(song, in: open.songs, index: idx)
                        } label: {
                            SongRow(song: song,
                                    index: idx + 1,
                                    isCurrent: song.id == player.currentSong?.id,
                                    isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
    }

    private func playSong(_ song: LXSong, in songs: [LXSong], index: Int) {
        Log.write("[CarPlay] 点击播放: \(song.name)")
        player.play(song: song, in: songs, index: index, presentPlayer: false, sceneName: "CarPlay")
        withAnimation(.easeOut(duration: 0.18)) {
            showPlayer = true
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 18))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
        }
    }
}

// MARK: - 顶部标签栏（图标 + 文字，酷狗式）

private struct CarPlayTabBar: View {
    @Binding var selected: Tab

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Tab.allCases) { t in
                Button {
                    selected = t
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: t.icon)
                            .font(.system(size: 19, weight: .semibold))
                        Text(t.rawValue)
                            .font(.system(size: 16, weight: selected == t ? .semibold : .regular))
                    }
                    .foregroundColor(selected == t ? cpAccent : Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected == t ? cpAccent.opacity(0.14) : Color.clear)
                    )
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

// MARK: - 歌单行（封面 + 标题 + 首数 + 箭头）

private struct NavigationRowButton: View {
    let title: String
    let subtitle: String
    let coverURL: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                CoverArt(urlString: coverURL, size: 48, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 歌曲行（序号/封面 + 歌名 + 歌手 + 正在播放标识）

private struct SongRow: View {
    let song: LXSong
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(urlString: song.imageURL, size: 42, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name)
                    .font(.system(size: 18, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(isCurrent ? cpAccent : .white)
                    .lineLimit(1)
                Text(song.singer)
                    .font(.system(size: 13.5))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: isPlaying ? "waveform" : "pause.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(cpAccent)
            } else {
                Text("\(index)")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.3))
                    .frame(minWidth: 26, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? cpAccent.opacity(0.14) : Color.white.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - 封面（有图用真封面，无图用渐变占位）

private struct CoverArt: View {
    let urlString: String
    var size: CGFloat = 48
    var radius: CGFloat = 8

    var body: some View {
        Group {
            if urlString.isEmpty {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.26, green: 0.27, blue: 0.33),
                                     Color(red: 0.13, green: 0.13, blue: 0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.4))
                            .foregroundColor(.white.opacity(0.4))
                    )
            } else {
                LXCachedImage(urlString: urlString, placeholder: "music.note", size: size, cornerRadius: radius)
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - 播放页（网易云式：左信息 + 大方块控制 + 进度，右大封面，封面模糊铺底）

private struct CarPlayPlayerPage: View {
    let showBack: Bool
    let onBack: () -> Void

    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        ZStack {
            BlurredCoverBackground(url: URL(string: player.currentSong?.imageURL ?? ""))
            Color.black.opacity(0.32).ignoresSafeArea()

            if player.currentSong == nil {
                VStack {
                    Spacer()
                    Text("当前没有正在播放的歌曲")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
            } else {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height
                    let cover = min(max(140, w * 0.255), h * 0.60)
                    let titleSize = min(33, max(20, cover * 0.135))
                    let subSize = min(21, max(14, cover * 0.082))
                    let ctrlIcon = min(38, max(26, cover * 0.15))
                    let playIcon = min(44, max(30, cover * 0.18))

                    VStack(spacing: 0) {
                        topBar

                        Spacer(minLength: 0)

                        HStack(alignment: .center, spacing: max(24, w * 0.05)) {
                            VStack(spacing: 0) {
                                Text(player.currentSong?.name ?? "")
                                    .font(.system(size: titleSize, weight: .bold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)

                                let album = player.currentSong?.albumName ?? ""
                                if !album.isEmpty {
                                    Text(album)
                                        .font(.system(size: subSize))
                                        .foregroundColor(.white.opacity(0.72))
                                        .lineLimit(1)
                                        .padding(.top, 2)
                                }

                                Text(player.currentSong?.singer ?? "")
                                    .font(.system(size: subSize))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                                    .padding(.top, 2)

                                if let line = currentLyricLine() {
                                    Text(line)
                                        .font(.system(size: max(13, subSize * 0.8), weight: .medium))
                                        .foregroundColor(cpAccent.opacity(0.9))
                                        .lineLimit(1)
                                        .padding(.top, 6)
                                }

                                Spacer().frame(height: max(12, cover * 0.07))

                                HStack(spacing: max(22, cover * 0.13)) {
                                    controlTile("backward.fill", width: 108, height: 78, icon: ctrlIcon) {
                                        player.playPrevious()
                                    }
                                    controlTile(player.isPlaying ? "pause.fill" : "play.fill",
                                                width: 120, height: 86, icon: playIcon) {
                                        player.togglePlayPause()
                                    }
                                    controlTile("forward.fill", width: 108, height: 78, icon: ctrlIcon) {
                                        player.playNext()
                                    }
                                }

                                Spacer().frame(height: max(10, cover * 0.06))

                                progressRow
                                    .frame(maxWidth: 430)
                            }
                            .frame(maxWidth: .infinity)

                            LXCachedImage(urlString: player.currentSong?.imageURL ?? "",
                                          placeholder: "music.note",
                                          size: cover,
                                          cornerRadius: 8)
                                .frame(width: cover, height: cover)
                                .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
                        }
                        .padding(.horizontal, max(18, w * 0.04))

                        Spacer(minLength: 0)

                        HStack(spacing: 26) {
                            modeTile(icon: "shuffle", active: player.playMode == .shuffle) {
                                player.playMode = (player.playMode == .shuffle ? .loopAll : .shuffle)
                            }
                            modeTile(icon: isLoved ? "heart.fill" : "heart", active: isLoved) {
                                toggleLove()
                            }
                            modeTile(icon: player.playMode == .loopOne ? "repeat.1" : "repeat",
                                     active: player.playMode == .loopOne) {
                                cycleRepeatMode()
                            }
                        }
                        .padding(.bottom, 14)
                    }
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            if showBack {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 19, weight: .medium))
                    }
                    .foregroundColor(cpAccent)
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Text("LX音乐")
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var progressRow: some View {
        let total = max(player.duration, 0.001)
        let fraction = min(max(player.currentTime / total, 0), 1)
        return HStack(spacing: 12) {
            Text(timeStr(player.currentTime))
                .font(.system(size: 16))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.8))

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: g.size.width * CGFloat(fraction), height: 4)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let f = min(max(value.location.x / max(g.size.width, 1), 0), 1)
                            player.seek(to: Double(f) * max(player.duration, 0))
                        }
                )
            }
            .frame(height: 22)

            Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
                .font(.system(size: 16))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private func controlTile(_ systemName: String,
                             width: CGFloat,
                             height: CGFloat,
                             icon: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: icon, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.17))
                )
        }
        .buttonStyle(.borderless)
    }

    private func modeTile(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 86, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(active ? Color.white : Color.white.opacity(0.14))
                )
        }
        .buttonStyle(.borderless)
    }

    private var isLoved: Bool {
        guard let song = player.currentSong else { return false }
        return playlistStore.isLoved(song)
    }

    private func toggleLove() {
        guard let song = player.currentSong else { return }
        if playlistStore.isLoved(song) {
            Task { try? await playlistStore.removeSongFromLove(song) }
        } else {
            Task { try? await playlistStore.addSongToLove(song) }
            HapticManager.shared.notification(type: .success)
        }
    }

    private func cycleRepeatMode() {
        switch player.playMode {
        case .loopAll: player.playMode = .loopOne
        case .loopOne: player.playMode = .sequential
        default: player.playMode = .loopAll
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
