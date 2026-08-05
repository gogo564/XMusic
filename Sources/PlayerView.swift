import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject var recentStore = RecentStore.shared
    @State private var showInPlaceLyrics = false
    @State private var localTime: Double = 0
    @State private var isDraggingSlider = false
    @State private var showingRecentList = false

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
        .onAppear {
            playerManager.setPlaylistFromRecent(recentStore.items)
        }
    }

    private var backgroundBlur: some View {
        GeometryReader { geo in
            AsyncImage(url: coverURL) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: 50)
                    .opacity(0.5)
            } placeholder: {
                Color.black
            }
        }
        .ignoresSafeArea()
    }

    private var coverURL: URL? {
        guard let song = playerManager.currentSong, !song.imageURL.isEmpty else { return nil }
        return URL(string: song.imageURL)
    }

    // MARK: - Main Player View

    private var mainPlayerView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar

                Spacer()

                centerArea(width: geo.size.width)

                Spacer()

                trackInfoAndControls
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.down")
                    .font(.title2.bold())
            }
            .frame(width: 44, height: 44)

            Spacer()

            Text("正在播放")
                .font(.headline)

            Spacer()

            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showInPlaceLyrics.toggle() }
                HapticManager.shared.selection()
            }) {
                Image(systemName: "text.quote")
                    .font(.title2)
            }
            .frame(width: 44, height: 44)
        }
        .padding(.horizontal)
        .foregroundColor(.white)
        .padding(.top, 10)
    }

    // MARK: - Center Area (cover <-> lyrics in place)

    private func centerArea(width: CGFloat) -> some View {
        let cdSize = min(width * 0.72, 320)
        return ZStack {
            if showInPlaceLyrics {
                inPlaceLyricsView
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.85))))
            } else {
                cdCoverView(size: cdSize)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.85))))
            }
        }
        .frame(height: cdSize + 40)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showInPlaceLyrics.toggle() }
            HapticManager.shared.selection()
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -60, !showInPlaceLyrics {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showInPlaceLyrics = true }
                        HapticManager.shared.selection()
                    } else if value.translation.height > 60, showInPlaceLyrics {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showInPlaceLyrics = false }
                        HapticManager.shared.selection()
                    }
                }
        )
    }

    // MARK: - CD Cover

    private func cdCoverView(size: CGFloat) -> some View {
        ZStack {
            AsyncImage(url: coverURL) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(albumRotationAngle))
                    .animation(.linear(duration: 0.5), value: playerManager.currentTime)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundColor(.white.opacity(0.6))
                    )
            }
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 2)
            )

            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: size * 0.16, height: size * 0.16)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                )

            Circle()
                .fill(Color.gray.opacity(0.4))
                .frame(width: size * 0.05, height: size * 0.05)
        }
        .shadow(color: Color.black.opacity(0.4), radius: 18, y: 8)
    }

    // MARK: - In-place Layered Lyrics (上一句 / 当前句 / 下一句)

    private var inPlaceLyricsView: some View {
        VStack(spacing: 14) {
            if playerManager.parsedLyrics.isEmpty {
                Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 24)
            } else if playerManager.currentLyricIndex < 0 {
                Text("正在加载歌词…")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))
            } else {
                ForEach(visibleLyrics) { item in
                    Text(item.text)
                        .font(item.diff == 0 ? .title2.bold() : .callout)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .foregroundColor(item.diff == 0 ? .white : .white.opacity(0.35))
                        .padding(.horizontal, 24)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: playerManager.currentLyricIndex)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var visibleLyrics: [VisibleLyric] {
        let lines = playerManager.parsedLyrics
        let idx = playerManager.currentLyricIndex
        guard !lines.isEmpty, idx >= 0, idx < lines.count else { return [] }
        var out: [VisibleLyric] = []
        for offset in -1...1 {
            let li = idx + offset
            if lines.indices.contains(li) {
                out.append(VisibleLyric(id: li, diff: offset, text: lines[li].text))
            }
        }
        return out
    }

    // MARK: - Track Info & Controls

    private var trackInfoAndControls: some View {
        VStack(spacing: 30) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(playerManager.currentSong?.name ?? "未知歌曲")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(playerManager.currentSong?.singer ?? "未知歌手")
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.8))
                        .lineLimit(1)
                    if !playerManager.sourceName.isEmpty {
                        Text("\(playerManager.sourceName) · \(playerManager.qualityName)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                Spacer()

                if let song = playerManager.currentSong {
                    Button(action: {
                        toggleLove(song)
                    }) {
                        Image(systemName: playlistStore.isLoved(song) ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundColor(playlistStore.isLoved(song) ? .red : .white)
                    }
                }
            }
            .padding(.horizontal, 30)

            if playerManager.isResolving {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在解析播放地址...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.bottom, 10)
            }

            progressSection

            controlsSection
                .padding(.bottom, 50)
        }
    }

    // MARK: - Progress Section

    private var progressSection: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: geo.size.width * CGFloat(playerManager.bufferedTime / max(playerManager.duration, 1)))
                }
                .frame(height: 3)

                Slider(value: $localTime, in: 0...max(playerManager.duration, 1), onEditingChanged: { dragging in
                    if dragging {
                        isDraggingSlider = true
                    } else {
                        playerManager.seek(to: localTime)
                    }
                })
                .accentColor(.white)
            }

            HStack {
                Text(formatTime(isDraggingSlider ? localTime : playerManager.currentTime))
                Spacer()
                Text(formatTime(playerManager.duration))
            }
        }
        .padding(.horizontal, 30)
        .onChange(of: playerManager.currentTime) { newValue in
            if isDraggingSlider {
                if abs(localTime - newValue) < 0.5 {
                    isDraggingSlider = false
                }
            } else {
                localTime = newValue
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        HStack(spacing: 25) {
            Button(action: {
                playerManager.togglePlayMode()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.playModeIcon)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }

            Button(action: {
                playerManager.playPrevious()
                HapticManager.shared.selection()
            }) {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundColor(playerManager.canPlayPrevious() ? .white : .gray)
                    .frame(width: 44, height: 44)
            }
            .disabled(!playerManager.canPlayPrevious())

            Button(action: {
                playerManager.togglePlayPause()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 70))
            }

            Button(action: {
                playerManager.playNext()
                HapticManager.shared.selection()
            }) {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundColor(playerManager.canPlayNext() ? .white : .gray)
            }
            .disabled(!playerManager.canPlayNext())

            Button(action: {
                showingRecentList = true
                HapticManager.shared.selection()
            }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
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

    // MARK: - Lyric Helpers

    /// CD-style rotation: 15°/s while playing, frozen when paused (derived from currentTime).
    private var albumRotationAngle: Double {
        (playerManager.currentTime * 15).truncatingRemainder(dividingBy: 360)
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
}
