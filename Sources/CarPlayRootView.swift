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
    @State private var detailRoute: CarPlayListRoute?
    /// 进入播放器前的 tab,用于返回时回到原处
    @State private var lastNonPlayerTab: Tab = .playlists
    /// 播放器左上角动态来源名(歌单名 / 歌单 / 最近)
    @State private var playerBackTitle: String = "歌单"

    var body: some View {
        // 不再用 NavigationView:系统导航栏会在内容顶部留出一条空白(CarPlay 上尤其明显),
        // 改为手动路由,主页/播放页/歌单详情全部贴住内容区顶部。
        Group {
            if selectedTab == .nowPlaying {
                nowPlayingView
            } else if let route = detailRoute {
                CarPlayDetailView(
                    route: route,
                    onBack: { detailRoute = nil },
                    onPlay: { openPlayer(backTitle: route.title) }
                )
            } else {
                VStack(spacing: 0) {
                    CarPlayTabBar(selected: $selectedTab, onNeedPlayer: {
                        openPlayer(backTitle: selectedTab == .playlists ? "歌单" : "最近")
                    })
                    .padding(.top, 6)
                    if selectedTab == .playlists {
                        playlistList
                    } else {
                        recentList
                    }
                }
            }
        }
        .onChange(of: selectedTab) { newValue in
            if newValue != .nowPlaying {
                lastNonPlayerTab = newValue
            }
        }
        // 关键:锁定字体缩放,CarPlay 上 accessibility 档会让文字过大溢出
        .environment(\.sizeCategory, .large)
        .onAppear {
            if !loaded {
                loaded = true
                Task { await playlistStore.refresh() }
            }
        }
    }

    /// 跳到播放器并记录来源名;返回时回到 lastNonPlayerTab(若来源是歌单详情,detailRoute 仍在,自然回详情)
    private func openPlayer(backTitle: String) {
        playerBackTitle = backTitle
        selectedTab = .nowPlaying
    }

    // MARK: - 歌单列表(原生 CarPlay 列表行)
    private var playlistList: some View {
        List {
            CarPlayNavRow(
                title: "我喜欢的音乐",
                subtitle: "\(playlistStore.songs(kind: .love, playlistID: "").count) 首",
                coverURL: playlistStore.songs(kind: .love, playlistID: "").first?.imageURL ?? ""
            ) {
                detailRoute = CarPlayListRoute(title: "我喜欢的音乐", songs: playlistStore.songs(kind: .love, playlistID: ""))
            }
            CarPlayNavRow(
                title: "默认列表",
                subtitle: "\(playlistStore.songs(kind: .defaultList, playlistID: "").count) 首",
                coverURL: playlistStore.songs(kind: .defaultList, playlistID: "").first?.imageURL ?? ""
            ) {
                detailRoute = CarPlayListRoute(title: "默认列表", songs: playlistStore.songs(kind: .defaultList, playlistID: ""))
            }
            ForEach(playlistStore.playlists, id: \.id) { pl in
                CarPlayNavRow(
                    title: pl.name,
                    subtitle: "\(playlistStore.songs(kind: .user, playlistID: pl.id).count) 首",
                    coverURL: playlistStore.songs(kind: .user, playlistID: pl.id).first?.imageURL ?? ""
                ) {
                    detailRoute = CarPlayListRoute(title: pl.name, songs: playlistStore.songs(kind: .user, playlistID: pl.id))
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
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(songs.indices, id: \.self) { idx in
                        let song = songs[idx]
                        CarPlayNavRow(title: song.name, subtitle: song.singer, coverURL: song.imageURL) {
                            detailRoute = CarPlayListRoute(title: "最近播放", songs: songs)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 正在播放视图
    private var nowPlayingView: some View {
        CarPlayPlayerView(
            backTitle: playerBackTitle,
            onBack: { selectedTab = lastNonPlayerTab }
        )
    }
}

// 顶部功能标签栏
private struct CarPlayTabBar: View {
    @Binding var selected: Tab
    /// 点击「正在播放」时回调,由外部决定播放器的返回来源名
    var onNeedPlayer: () -> Void = {}

    private let tabs: [(Tab, String)] = [
        (.playlists, "list.bullet.rectangle"),
        (.recent, "clock"),
        (.nowPlaying, "play.circle"),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs, id: \.0) { tab, icon in
                Button {
                    if tab == .nowPlaying {
                        onNeedPlayer()
                    }
                    selected = tab
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: icon)
                            .font(.system(size: 16))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: selected == tab ? .heavy : .medium, design: .rounded))
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
                    .font(.system(size: 18, weight: isNowPlaying ? .heavy : .semibold, design: .rounded))
                    .foregroundColor(isNowPlaying ? Color(.systemOrange) : .primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
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

// 手动路由:歌单详情,取代 NavigationView(避免系统导航栏在顶部撑出空白条)
private struct CarPlayListRoute: Identifiable {
    let id = UUID()
    let title: String
    let songs: [LXSong]
}

// 歌单详情页:自绘顶部「‹ 返回 + 歌单名」+ 歌曲列表
private struct CarPlayDetailView: View {
    let route: CarPlayListRoute
    let onBack: () -> Void
    let onPlay: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("返回")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(Color(.systemBlue))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(route.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)

            CarPlaySongList(title: route.title, songs: route.songs, onPlay: onPlay)
        }
    }
}

// 主页导航行:左侧 56 小封面 + 右侧标题/副标题 + 右箭头(用于歌单/最近)
private struct CarPlayNavRow: View {
    let title: String
    let subtitle: String
    let coverURL: String
    let action: () -> Void

    init(title: String, subtitle: String, coverURL: String = "", action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                artwork
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
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
    /// 点歌返回后跳到播放器
    var onPlay: () -> Void = {}
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        List(songs.indices, id: \.self) { idx in
            let song = songs[idx]
            Button {
                Log.write("[CarPlay] 点击播放: \(song.name)")
                player.play(song: song, in: songs, index: idx, presentPlayer: false, sceneName: "CarPlay")
                onPlay()
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
        .environment(\.sizeCategory, .large)
    }
}


// 车机播放页(仿网易云车机视觉):
// 左上「‹ 返回歌单」/ 右上 App 名,主体大字歌词 + 右侧圆角封面,
// 下方一排半透明大圆角控制块、细进度条、底部胶囊控件。
// 圆润感来自:封面/按钮 18~22 圆角、白 8%~14% 半透明无边框、全胶囊控件、
// 封面模糊铺底 + 黑色遮罩、全局 SF Rounded 字体。
private struct CarPlayPlayerView: View {
    /// 来源名(歌单名 / 歌单 / 最近),显示在返回按钮上
    let backTitle: String
    let onBack: () -> Void
    @StateObject private var player = PlayerManager.shared

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let padH = max(16, w * 0.030)
            let topH = min(56, max(38, h * 0.105))
            let cover = min(w * 0.178, h * 0.30)
            let lyricSize = min(44, max(21, h * 0.088))
            let metaSize = min(15, max(11, h * 0.030))
            let smallSize = min(12, max(10, h * 0.024))
            let btnW = min(w * 0.175, h * 0.290)
            let btnH = min(80, max(52, h * 0.155))
            let btnRadius = btnH * 0.30
            let iconSize = min(30, max(17, h * 0.050))
            let trackH = min(6, max(4, h * 0.011))
            let knob = min(16, max(10, h * 0.030))

            ZStack {
                background(w: w, h: h)

                VStack(spacing: 0) {
                    header(barH: topH, padH: padH, size: metaSize)
                        // 去掉系统导航栏后,顶部补一点呼吸距离
                        .padding(.top, h * 0.022)

                    HStack(alignment: .top, spacing: max(18, w * 0.030)) {
                        lyricsBlock(lyricSize: lyricSize, metaSize: metaSize)

                        Spacer(minLength: 8)

                        LXCachedImage(
                            urlString: player.currentSong?.imageURL ?? "",
                            placeholder: "music.note",
                            size: cover,
                            cornerRadius: min(20, cover * 0.16)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: min(20, cover * 0.16), style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, padH)
                    // 歌词+封面整块占满 header 与控件之间的空间并垂直居中,
                    // 不再让 Spacer 把空白全压成歌词下方一大块
                    .frame(maxHeight: .infinity, alignment: .center)

                    controlRow(btnW: btnW, btnH: btnH, radius: btnRadius, iconSize: iconSize)
                        .padding(.horizontal, padH)
                        .padding(.top, h * 0.030)

                    progressBlock(trackH: trackH, knob: knob, timeSize: smallSize)
                        .padding(.horizontal, padH)
                        .padding(.top, h * 0.045)

                    pillRow(size: smallSize, height: max(28, h * 0.067))
                        .padding(.horizontal, padH)
                        .padding(.top, h * 0.050)
                        // 底部留白加大,把「按钮 + 进度 + 胶囊」整组往上抬
                        .padding(.bottom, h * 0.075)
                }
            }
        }
    }

    // 封面模糊铺底 + 黑遮罩,避免纯黑屏的硬边
    private func background(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            if let url = player.currentSong?.imageURL, !url.isEmpty {
                LXCachedImage(urlString: url, placeholder: "music.note", size: max(w, h), cornerRadius: 0)
                    .scaleEffect(1.12)
                    .blur(radius: 36)
                    .opacity(0.85)
            } else {
                Color(red: 0.10, green: 0.10, blue: 0.13)
            }
            Color.black.opacity(0.58)
        }
        .frame(width: w, height: h)
        .clipped()
        .allowsHitTesting(false)
    }

    // 顶部:‹ 返回 · 来源名 + 右侧 App 名
    private func header(barH: CGFloat, padH: CGFloat, size: CGFloat) -> some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: size, weight: .bold, design: .rounded))
                    Text("返回 · \(backTitle)")
                        .font(.system(size: size + 2, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .foregroundColor(.white.opacity(0.94))
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 0)

            Text("LX音乐")
                .font(.system(size: size, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.62))
        }
        .padding(.horizontal, padH)
        .frame(height: barH)
    }

    // 主体:大字歌词 + 歌手 + 歌名(无歌词时降级为歌名)
    private func lyricsBlock(lyricSize: CGFloat, metaSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(currentLyricLine() ?? player.currentSong?.name ?? "未在播放")
                .font(.system(size: lyricSize, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)

            if let singer = player.currentSong?.singer, !singer.isEmpty {
                Text(singer)
                    .font(.system(size: metaSize, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
                    .padding(.top, 8)
            }

            if currentLyricLine() != nil, let name = player.currentSong?.name, !name.isEmpty {
                Text(name)
                    .font(.system(size: metaSize + 2, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 三颗半透明大圆角控制块,左对齐
    private func controlRow(btnW: CGFloat, btnH: CGFloat, radius: CGFloat, iconSize: CGFloat) -> some View {
        HStack(spacing: max(12, btnH * 0.20)) {
            controlButton(width: btnW, height: btnH, radius: radius, opacity: 0.085) {
                player.playPrevious()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            controlButton(width: btnW, height: btnH, radius: radius, opacity: 0.14) {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(.white)
            }

            controlButton(width: btnW, height: btnH, radius: radius, opacity: 0.085) {
                player.playNext()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
            }

            Spacer(minLength: 0)
        }
    }

    private func controlButton<Icon: View>(
        width: CGFloat,
        height: CGFloat,
        radius: CGFloat,
        opacity: Double,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Icon
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(opacity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
    }

    // 进度:细胶囊轨道 + 白色圆点 + 两端时间
    private func progressBlock(trackH: CGFloat, knob: CGFloat, timeSize: CGFloat) -> some View {
        VStack(spacing: 6) {
            GeometryReader { g in
                let ratio = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
                let full = g.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: trackH)
                    Capsule()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: max(trackH, full * ratio), height: trackH)
                    Circle()
                        .fill(Color.white)
                        .frame(width: knob, height: knob)
                        .offset(x: min(max(full * ratio - knob / 2, 0), full - knob))
                }
                .frame(height: knob, alignment: .center)
            }
            .frame(height: knob)

            HStack(spacing: 6) {
                Text(timeStr(player.currentTime))
                Spacer(minLength: 4)
                Text("-" + timeStr(max(player.duration - player.currentTime, 0)))
            }
            .font(.system(size: timeSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundColor(.white.opacity(0.66))
        }
    }

    // 底部胶囊:随机(可切模式) + 音质(只展示)
    private func pillRow(size: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button { player.togglePlayMode() } label: {
                pillLabel(playModeText, size: size, height: height)
            }
            .buttonStyle(.borderless)

            if !player.qualityName.isEmpty {
                pillLabel(player.qualityName, size: size, height: height)
            }

            Spacer(minLength: 0)
        }
    }

    private func pillLabel(_ text: String, size: CGFloat, height: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(0.80))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(
                Capsule().fill(Color.white.opacity(0.07))
            )
            .overlay(
                Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var playModeText: String {
        switch player.playMode {
        case .sequential: return "顺序播放"
        case .loopAll: return "列表循环"
        case .loopOne: return "单曲循环"
        case .shuffle: return "随机播放"
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
