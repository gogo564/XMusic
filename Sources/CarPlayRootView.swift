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
// 4) 排版参考 Apple CarPlay HIG:深色底、大行距、行首封面图;播放页为左侧大封面 +
//    右侧歌名/歌词/进度/控制 的车机经典布局。

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
                        count: playlistStore.songs(kind: .love, playlistID: "").count,
                        coverURL: playlistStore.songs(kind: .love, playlistID: "").first?.imageURL ?? ""
                    ) {
                        CarPlaySongList(title: "我喜欢的音乐", songs: playlistStore.songs(kind: .love, playlistID: ""))
                    }
                    CarPlayNavLink(
                        title: "默认列表",
                        count: playlistStore.songs(kind: .defaultList, playlistID: "").count,
                        coverURL: playlistStore.songs(kind: .defaultList, playlistID: "").first?.imageURL ?? ""
                    ) {
                        CarPlaySongList(title: "默认列表", songs: playlistStore.songs(kind: .defaultList, playlistID: ""))
                    }
                    ForEach(playlistStore.playlists, id: \.id) { pl in
                        CarPlayNavLink(
                            title: pl.name,
                            count: playlistStore.songs(kind: .user, playlistID: pl.id).count,
                            coverURL: playlistStore.songs(kind: .user, playlistID: pl.id).first?.imageURL ?? ""
                        ) {
                            CarPlaySongList(title: pl.name, songs: playlistStore.songs(kind: .user, playlistID: pl.id))
                        }
                    }
                }
                Section("最近播放") {
                    CarPlayNavLink(
                        title: "最近播放",
                        count: recentStore.items.count,
                        coverURL: recentStore.items.first?.song?.imageURL ?? ""
                    ) {
                        CarPlaySongList(title: "最近播放", songs: recentStore.items.compactMap { $0.song })
                    }
                }
            }
            .listStyle(.insetGrouped)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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

private struct CarPlayNavLink<Destination: View>: View {
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
            CarPlayListRow(title: title, subtitle: "\(count) 首", coverURL: coverURL)
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
                    LXCachedImage(
                        urlString: player.currentSong?.imageURL ?? "",
                        placeholder: "music.note",
                        size: 44,
                        cornerRadius: 8
                    )
                    CarPlayListRow(
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
                    .font(.system(size: 30))
                    .foregroundColor(.accentColor)
                    .padding(.trailing, 8)
            }
            .buttonStyle(.borderless)
        }
    }
}

// 车机播放页:左侧大封面 + 右侧(歌词/歌名/歌手 + 进度 + 控制),
// 经典 CarPlay 音频布局,ScrollView 防裁切
private struct CarPlayPlayerView: View {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                HStack(alignment: .center, spacing: 16) {
                    LXCachedImage(
                        urlString: player.currentSong?.imageURL ?? "",
                        placeholder: "music.note",
                        size: min(geo.size.height - 24, 160),
                        cornerRadius: 10
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        if let line = currentLyricLine() {
                            Text(line)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentSong?.name ?? "未在播放")
                                .font(.system(size: 21, weight: .bold))
                                .lineLimit(1)
                            Text(player.currentSong?.singer ?? "")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        VStack(spacing: 2) {
                            ProgressView(value: player.currentTime, total: max(player.duration, 1))
                            HStack {
                                Text(timeStr(player.currentTime))
                                Spacer()
                                Text(timeStr(player.duration))
                            }
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        }

                        HStack(spacing: 36) {
                            Button {
                                player.playPrevious()
                            } label: {
                                Image(systemName: "backward.fill").font(.system(size: 26))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                player.togglePlayPause()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 46))
                            }
                            .buttonStyle(.borderless)

                            Button {
                                player.playNext()
                            } label: {
                                Image(systemName: "forward.fill").font(.system(size: 26))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.trailing, 4)

                        Button {
                            guard let song = player.currentSong else { return }
                            if playlistStore.isLoved(song) {
                                Task { try? await playlistStore.removeSongFromLove(song) }
                            } else {
                                Task { try? await playlistStore.addSongToLove(song) }
                                HapticManager.shared.notification(type: .success)
                            }
                        } label: {
                            Image(systemName: (player.currentSong.map { playlistStore.isLoved($0) } ?? false)
                                ? "heart.fill" : "heart")
                                .font(.system(size: 24))
                                .foregroundColor((player.currentSong.map { playlistStore.isLoved($0) } ?? false)
                                    ? Color(.systemRed) : .secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 24)
                }
                .padding(16)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .center)
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