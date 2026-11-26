import SwiftUI

private enum Tab: String, CaseIterable, Identifiable {
    case recommend = "推荐"
    case playlists = "歌单"
    case recent = "最近"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .recommend: return "sparkles"
        case .playlists: return "music.note.list"
        case .recent: return "clock.arrow.circlepath"
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
    @State private var tab: Tab = .recommend
    @State private var openPlaylist: OpenPlaylist?
    @State private var showPlayer = false

    // 推荐页：热门榜单
    @State private var boards: [(id: String, bangid: String, name: String)] = []
    @State private var boardsLoading = false
    @State private var boardsLoaded = false
    @State private var boardLoading: String?

    var body: some View {
        ZStack {
            background

            if let open = openPlaylist {
                songListPage(open)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 4) {
                        CarPlayTabBar(selected: $tab)
                        // 右上角圆形「回播放页」按钮（对齐网易云）
                        Button {
                            showPlayer = true
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(cpAccent)
                                .frame(width: 30, height: 30)
                                .background(
                                    Circle().fill(Color.white.opacity(0.10))
                                )
                        }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 10)
                    }
                    Group {
                        switch tab {
                        case .recommend:
                            recommendPage
                        case .playlists:
                            playlistPage
                        case .recent:
                            recentPage
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
            loadBoards()
        }
        .onChange(of: tab) { t in
            if t == .recommend { loadBoards() }
        }
    }

    // MARK: - 推荐页（热门榜单，网易云式大行）

    private var recommendPage: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if boards.isEmpty {
                    if boardsLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding(.top, 30)
                    } else {
                        emptyState("暂无榜单")
                    }
                } else {
                    ForEach(boards, id: \.id) { b in
                        IconRowButton(icon: iconForBoard(b.name), title: b.name) {
                            openBoard(name: b.name, bangid: b.bangid)
                        }
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 44)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .overlay(
            Group {
                if let name = boardLoading {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("正在载入 \(name)…")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                }
            }
        )
    }

    private func loadBoards() {
        guard !boardsLoaded, !boardsLoading else { return }
        boardsLoading = true
        Task {
            let raw = (try? await LXAPIClient.shared.getLeaderBoards(source: "wy")) ?? []
            var list: [(id: String, bangid: String, name: String)] = []
            for b in raw {
                if let id = b["id"] as? String,
                   let bangid = b["bangid"] as? String,
                   let name = b["name"] as? String {
                    list.append((id: id, bangid: bangid, name: name))
                }
            }
            await MainActor.run {
                boards = list
                boardsLoading = false
                boardsLoaded = true
            }
        }
    }

    private func openBoard(name: String, bangid: String) {
        boardLoading = name
        Task {
            let songs = (try? await LXAPIClient.shared.getLeaderBoardSongs(source: "wy",
                                                                          bangid: bangid,
                                                                          page: 1)) ?? []
            await MainActor.run {
                boardLoading = nil
                openPlaylist = OpenPlaylist(title: name, songs: songs)
            }
        }
    }

    private func iconForBoard(_ name: String) -> String {
        if name.contains("热歌") { return "flame.fill" }
        if name.contains("新歌") { return "sparkles" }
        if name.contains("飙升") { return "chart.line.uptrend.xyaxis" }
        if name.contains("原创") { return "music.note" }
        return "chart.bar.fill"
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
            LazyVStack(spacing: 8) {
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
            .padding(.leading, 10)
            .padding(.trailing, 44)
            .padding(.top, 4)
            .padding(.bottom, 12)
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
        let songs: [LXSong] = recentStore.items.compactMap { $0.song }
        return Group {
            if songs.isEmpty {
                emptyState("暂无最近播放")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(songs.indices), id: \.self) { idx in
                            let song = songs[idx]
                            Button {
                                playSong(song, in: songs, index: idx)
                            } label: {
                                CarPlaySongRow(song: song,
                                        index: idx + 1,
                                        isCurrent: song.id == player.currentSong?.id,
                                        isPlaying: player.isPlaying)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 44)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
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
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("返回")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(cpAccent)
                }
                .buttonStyle(.borderless)

                Spacer(minLength: 6)

                Text(open.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text("\(open.songs.count) 首")
                    .font(.system(size: 11.5))
                    .foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, 5)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(open.songs.indices), id: \.self) { idx in
                        let song = open.songs[idx]
                        Button {
                            playSong(song, in: open.songs, index: idx)
                        } label: {
                            CarPlaySongRow(song: song,
                                    index: idx + 1,
                                    isCurrent: song.id == player.currentSong?.id,
                                    isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 44)
                .padding(.bottom, 12)
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
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.55))
            Spacer()
        }
    }
}

// MARK: - 顶部标签栏（图标 + 文字，酷狗式）

private struct CarPlayTabBar: View {
    @Binding var selected: Tab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { t in
                Button {
                    selected = t
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon)
                            .font(.system(size: 15, weight: .semibold))
                        Text(t.rawValue)
                            .font(.system(size: 13.5, weight: selected == t ? .semibold : .regular))
                    }
                    .foregroundColor(selected == t ? cpAccent : Color.white.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.leading, 10)
        .padding(.top, 5)
        .padding(.bottom, 3)
    }
}

// MARK: - 推荐页行（单色图标 + 标题 + 箭头，网易云式）

private struct IconRowButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
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
            HStack(spacing: 10) {
                CoverArt(urlString: coverURL, size: 34, radius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 歌曲行（序号/封面 + 歌名 + 歌手 + 正在播放标识）

private struct CarPlaySongRow: View {
    let song: LXSong
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 9) {
            CoverArt(urlString: song.imageURL, size: 30, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.name)
                    .font(.system(size: 14.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundColor(isCurrent ? cpAccent : .white)
                    .lineLimit(1)
                Text(song.singer)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isCurrent {
                Image(systemName: isPlaying ? "waveform" : "pause.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(cpAccent)
            } else {
                Text("\(index)")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.3))
                    .frame(minWidth: 20, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? cpAccent.opacity(0.14) : Color.white.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    // 车机窗口的实际可视高度比 geo 高度小约 7%（DiPlay/部分车机会裁掉底部），
                    // 直接用 h 会让整页越往下越偏低、底栏被切。这里按可视高度 vh 排布。
                    let vh = h * 0.932
                    let pad = max(14, w * 0.035)
                    let gap = max(12, w * 0.040)
                    let cover = min(w * 0.275, vh * 0.44)
                    let coverX = w - max(18, w * 0.055) - cover / 2
                    let leftRight = coverX - cover / 2 - gap
                    let leftW = max(120, leftRight - pad)
                    let leftCX = pad + leftW / 2

                    let titleSize = max(14, min(17, w * 0.037))
                    let subSize = max(10.5, min(13, w * 0.028))
                    let lyricSize = max(9.5, min(11.5, w * 0.025))
                    let tileW = w * 0.135
                    let tileH = vh * 0.185
                    let tileGap = max(10, w * 0.040)
                    let ctrlIcon = tileH * 0.46
                    let modeW = w * 0.112
                    let modeH = vh * 0.105
                    let modeIcon = min(15, modeH * 0.52)

                    ZStack(alignment: .topLeading) {
                        topBar
                            .frame(width: w - pad * 2)
                            .position(x: w / 2, y: h * 0.09)

                        // 左侧：歌名 / 专辑 / 歌手 / 当前歌词
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
                                    .padding(.top, 3)
                            }

                            Text(player.currentSong?.singer ?? "")
                                .font(.system(size: subSize))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                                .padding(.top, 3)

                            if let line = currentLyricLine() {
                                Text(line)
                                    .font(.system(size: lyricSize, weight: .medium))
                                    .foregroundColor(cpAccent.opacity(0.9))
                                    .lineLimit(1)
                                    .padding(.top, 4)
                            }
                        }
                        .frame(width: leftW)
                        .position(x: leftCX, y: vh * 0.30)

                        // 三个等宽大方块控制键
                        HStack(spacing: tileGap) {
                            controlTile("backward.fill", width: tileW, height: tileH, icon: ctrlIcon) {
                                player.playPrevious()
                            }
                            controlTile(player.isPlaying ? "pause.fill" : "play.fill",
                                        width: tileW, height: tileH, icon: tileH * 0.48) {
                                player.togglePlayPause()
                            }
                            controlTile("forward.fill", width: tileW, height: tileH, icon: ctrlIcon) {
                                player.playNext()
                            }
                        }
                        .position(x: leftCX, y: vh * 0.585)

                        // 右侧大封面（清晰原图，不做模糊）
                        LXCachedImage(urlString: player.currentSong?.imageURL ?? "",
                                      placeholder: "music.note",
                                      size: cover,
                                      cornerRadius: 7)
                            .frame(width: cover, height: cover)
                            .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 7)
                            .position(x: coverX, y: vh * 0.47)

                        // 进度条：横贯整行，位于封面下方
                        progressRow
                            .frame(width: w - pad * 2 - 20)
                            .position(x: w / 2, y: vh * 0.80)

                        HStack(spacing: max(12, w * 0.037)) {
                            modeTile(icon: "shuffle", width: modeW, height: modeH, iconSize: modeIcon,
                                     active: player.playMode == .shuffle) {
                                player.playMode = (player.playMode == .shuffle ? .loopAll : .shuffle)
                            }
                            modeTile(icon: isLoved ? "heart.fill" : "heart", width: modeW, height: modeH, iconSize: modeIcon,
                                     active: isLoved) {
                                toggleLove()
                            }
                            modeTile(icon: player.playMode == .loopOne ? "repeat.1" : "repeat",
                                     width: modeW, height: modeH, iconSize: modeIcon,
                                     active: player.playMode != .sequential) {
                                cycleRepeatMode()
                            }
                        }
                        .position(x: w / 2, y: vh * 0.945)
                    }
                    .frame(width: w, height: h)
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            if showBack {
                // 左上返回：圆形深底 + 青色箭头 + 青色文字（对齐网易云）
                Button(action: onBack) {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 21, height: 21)
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(cpAccent)
                        }
                        Text("返回")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(cpAccent)
                    }
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
    }

    private var progressRow: some View {
        let total = max(player.duration, 0.001)
        let fraction = min(max(player.currentTime / total, 0), 1)
        return HStack(spacing: 9) {
            Text(timeStr(player.currentTime))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.9))

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.28))
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
            .frame(height: 16)

            Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.9))
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
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                )
        }
        .buttonStyle(.borderless)
    }

    private func modeTile(icon: String,
                          width: CGFloat,
                          height: CGFloat,
                          iconSize: CGFloat,
                          active: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.white : Color.white.opacity(0.16))
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
