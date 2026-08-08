import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var downloader: DownloadService
    @Environment(\.dismiss) var dismiss
    @ObservedObject var recentStore = RecentStore.shared
    @State private var showInPlaceLyrics = false
    @State private var localTime: Double = 0
    @State private var isDraggingSlider = false
    @State private var showingRecentList = false
    @State private var showPlaylistPicker = false

    private let qualityOptions = ["128k", "320k", "flac"]

    var body: some View {
        ZStack {
            backgroundBlur
            mainPlayerView
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingRecentList) {
            RecentPlaylistView()
                .environmentObject(playerManager)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let song = playerManager.currentSong {
                PlaylistPickerView(song: song)
                    .environmentObject(playlistStore)
            }
        }
        .onAppear {
            playerManager.setPlaylistFromRecent(recentStore.items)
        }
    }

    private var backgroundBlur: some View {
        GeometryReader { geo in
            ZStack {
                AsyncImage(url: coverURL) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: 45)
                        .opacity(0.6)
                } placeholder: {
                    Color.black
                }

                // 顶部 + 底部渐变遮罩，保证文字可读
                LinearGradient(
                    colors: [Color.black.opacity(0.5), .clear, .clear, Color.black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }

    private var coverURL: URL? {
        guard let song = playerManager.currentSong, !song.imageURL.isEmpty else { return nil }
        return URL(string: song.imageURL)
    }

    private var playbackSubtitle: String {
        var parts: [String] = []
        if !playerManager.sourceName.isEmpty {
            parts.append(MusicSources.name(playerManager.sourceName))
        }
        if !playerManager.qualityName.isEmpty {
            parts.append(MusicSources.qualityName(playerManager.qualityName))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    // MARK: - Main Player View

    private var mainPlayerView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 8)

                bodyArea(width: geo.size.width)

                trackInfoAndControls
                    .padding(.bottom, 40)
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.title2.bold())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Spacer()

            VStack(spacing: 2) {
                Text("正在播放")
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(playbackSubtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                    if !playerManager.playbackOrigin.isEmpty {
                        Text(playerManager.playbackOrigin)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                if playerManager.sleepTimerRemaining > 0 {
                    Text("定时 \(playerManager.sleepTimerText) 后停止")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer()

            topMenu
        }
        .padding(.horizontal)
        .foregroundColor(.white)
    }

    private var topMenu: some View {
        Menu {
            Button {
                showPlaylistPicker = true
            } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            .disabled(playerManager.currentSong == nil)

            Picker("音质", selection: qualityBinding) {
                ForEach(qualityOptions, id: \.self) { q in
                    Text(q).tag(q)
                }
            }

            Button {
                toggleLyrics()
            } label: {
                Label(showInPlaceLyrics ? "隐藏歌词" : "显示歌词", systemImage: "text.quote")
            }

            Menu("定时关闭") {
                Button("关闭定时") { playerManager.setSleepTimer(minutes: nil) }
                Button("5 分钟") { playerManager.setSleepTimer(minutes: 5) }
                Button("10 分钟") { playerManager.setSleepTimer(minutes: 10) }
                Button("30 分钟") { playerManager.setSleepTimer(minutes: 30) }
                Button("1 小时") { playerManager.setSleepTimer(minutes: 60) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { playerManager.quality },
            set: { playerManager.setQuality($0) }
        )
    }

    private func toggleLyrics() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showInPlaceLyrics.toggle() }
        HapticManager.shared.selection()
    }

    // MARK: - Body Area (cover <-> full-height lyrics)

    private func bodyArea(width: CGFloat) -> some View {
        let coverSize = min(width * 0.74, 320)
        return ZStack {
            if showInPlaceLyrics {
                fullLyricsView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.9)),
                        removal: .opacity.combined(with: .scale(scale: 0.9))))
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 8)
                    coverCard(size: coverSize)
                    Spacer(minLength: 8)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.9)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            toggleLyrics()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -60, !showInPlaceLyrics {
                        toggleLyrics()
                    } else if value.translation.height > 60, showInPlaceLyrics {
                        toggleLyrics()
                    }
                }
        )
    }

    // MARK: - Cover Card (square, rounded)

    private func coverCard(size: CGFloat) -> some View {
        AsyncImage(url: coverURL) { image in
            image.resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        } placeholder: {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.35))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 54))
                        .foregroundColor(.white.opacity(0.55))
                )
        }
        .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 10)
    }

    // MARK: - Full-height Layered Lyrics
    // 顶部从「正在播放」下方开始，底部到歌名/控制区为止，铺满整块区域。

    private var fullLyricsView: some View {
        VStack(alignment: .center, spacing: 0) {
            if playerManager.parsedLyrics.isEmpty {
                Spacer(minLength: 0)
                Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else if playerManager.currentLyricIndex < 0 {
                Spacer(minLength: 0)
                Text(playerManager.parsedLyrics.first?.text ?? "歌词即将开始")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                VStack(spacing: 18) {
                    ForEach(visibleLyrics) { item in
                        Text(item.text)
                            .font(.body)
                            .fontWeight(item.diff == 0 ? .bold : .regular)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .foregroundColor(item.text.isEmpty ? .clear : (item.diff == 0 ? .white : .white.opacity(0.45)))
                            .shadow(color: Color.black.opacity(0.5), radius: 6)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .move(edge: .top).combined(with: .opacity)))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: playerManager.currentLyricIndex)
    }

    private var visibleLyrics: [VisibleLyric] {
        let lines = playerManager.parsedLyrics
        let idx = playerManager.currentLyricIndex
        guard !lines.isEmpty, idx >= 0, idx < lines.count else { return [] }
        var out: [VisibleLyric] = []
        for offset in -2...2 {
            let li = idx + offset
            if lines.indices.contains(li) {
                out.append(VisibleLyric(id: li, diff: offset, text: lines[li].text))
            } else {
                out.append(VisibleLyric(id: li, diff: offset, text: ""))
            }
        }
        return out
    }

    // MARK: - Track Info & Controls

    private var trackInfoAndControls: some View {
        VStack(spacing: 26) {
            // 歌名 / 歌手（左对齐）+ 收藏 + 下载
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(playerManager.currentSong?.name ?? "未知歌曲")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(playerManager.currentSong?.singer ?? "未知歌手")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                Spacer()

                downloadButton
                loveButton
            }
            .padding(.horizontal, 24)

            if playerManager.isResolving {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在解析播放地址...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            progressSection

            controlsSection
        }
    }

    private var loveButton: some View {
        Button(action: {
            if let song = playerManager.currentSong { toggleLove(song) }
        }) {
            let isLoved = playerManager.currentSong.map { playlistStore.isLoved($0) } ?? false
            Image(systemName: isLoved ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundColor(isLoved ? .red : .white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var downloadButton: some View {
        Button(action: {
            guard let song = playerManager.currentSong, !downloader.isDownloaded(song) else { return }
            downloader.download(song, quality: playerManager.quality)
            HapticManager.shared.selection()
        }) {
            if let song = playerManager.currentSong {
                if let progress = downloader.activeTasks[song.id + "_" + playerManager.quality] {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.white, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                    .padding(12)
                } else if downloader.isDownloaded(song) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Custom Progress Section

    private var progressSection: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    let total = max(playerManager.duration, 1)
                    let bufferedRatio = CGFloat(min(playerManager.bufferedTime / total, 1))
                    let progressRatio = CGFloat(isDraggingSlider ? localTime / total : playerManager.currentTime / total)

                    ZStack(alignment: .leading) {
                        // 轨道
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)

                        // 缓冲
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: geo.size.width * bufferedRatio, height: 3)

                        // 进度
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * max(progressRatio, 0), height: 3)

                        // 圆形滑块
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: Color.black.opacity(0.4), radius: 3, y: 1)
                            .offset(x: geo.size.width * max(progressRatio, 0) - 6)
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingSlider = true
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                localTime = Double(ratio) * total
                            }
                            .onEnded { _ in
                                playerManager.seek(to: localTime)
                                isDraggingSlider = false
                            }
                    )
                }
                .frame(height: 24)
            }

            HStack {
                Text(formatTime(isDraggingSlider ? localTime : playerManager.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(formatTime(playerManager.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 28)
        .onChange(of: playerManager.currentTime) { newValue in
            if !isDraggingSlider {
                localTime = newValue
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        HStack(spacing: 28) {
            Button(action: {
                playerManager.togglePlayMode()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.playModeIcon)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }

            Button(action: {
                playerManager.playPrevious()
                HapticManager.shared.selection()
            }) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 26))
                    .foregroundColor(playerManager.canPlayPrevious() ? .white : .gray)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!playerManager.canPlayPrevious())

            Button(action: {
                playerManager.togglePlayPause()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
            }

            Button(action: {
                playerManager.playNext()
                HapticManager.shared.selection()
            }) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 26))
                    .foregroundColor(playerManager.canPlayNext() ? .white : .gray)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!playerManager.canPlayNext())

            Button(action: {
                showingRecentList = true
                HapticManager.shared.selection()
            }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Actions

    private func toggleLove(_ song: LXSong) {
        if playlistStore.isLoved(song) {
            Task {
                try? await playlistStore.removeSongFromLove(song)
            }
        } else {
            Task {
                try? await playlistStore.addSongToLove(song)
            }
            HapticManager.shared.notification(type: .success)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// A single lyric line shown in the in-place layered lyrics view.
/// `id` is the absolute index in `parsedLyrics`, `diff` is distance from current line (-1/0/1).
private struct VisibleLyric: Identifiable {
    let id: Int
    let diff: Int
    let text: String
}

#Preview {
    PlayerView()
        .environmentObject(PlayerManager.shared)
        .environmentObject(PlaylistStore.shared)
        .environmentObject(DownloadService.shared)
}
