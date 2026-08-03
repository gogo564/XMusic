import SwiftUI

struct PlayerView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @Environment(\.dismiss) var dismiss
    @ObservedObject var recentStore = RecentStore.shared
    @State private var showingLyrics = false
    @State private var localTime: Double = 0
    @State private var isDraggingSlider = false
    @State private var showingRecentList = false

    var body: some View {
        ZStack {
            // Background Blur
            if let song = playerManager.currentSong {
                GeometryReader { geo in
                    AsyncImage(url: URL(string: song.imageURL)) { image in
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

            // Full-screen lyrics overlay
            if showingLyrics {
                lyricsView
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                if value.translation.width > 80 {
                                    withAnimation { showingLyrics = false }
                                }
                            }
                    )
                    .transition(.move(edge: .trailing))
                    .animation(.spring(), value: showingLyrics)
                    .zIndex(2)
            }

            // Main player content
            if !showingLyrics {
                mainPlayerView
                    .zIndex(1)
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                if value.translation.width < -80 {
                                    withAnimation { showingLyrics = true }
                                }
                            }
                    )
            }
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

    // MARK: - Main Player View

    private var mainPlayerView: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top Bar
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
                        withAnimation { showingLyrics = true }
                    }) {
                        Image(systemName: "text.quote")
                            .font(.title2)
                    }
                    .frame(width: 44, height: 44)
                }
                .padding(.horizontal)
                .foregroundColor(.white)
                .padding(.top, 10)

                Spacer()

                // Album Art
                if let song = playerManager.currentSong {
                    AsyncImage(url: URL(string: song.imageURL)) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(20)
                            .shadow(radius: 20)
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.gray.opacity(0.3))
                            .overlay(Image(systemName: "music.note").font(.system(size: 80)))
                    }
                    .frame(width: geo.size.width * 0.8)
                    .padding(20)
                }

                Spacer()

                trackInfoAndControls
            }
        }
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

    // MARK: - Lyrics Full-Screen View

    private var lyricsView: some View {
        ZStack {
            if let song = playerManager.currentSong {
                GeometryReader { bg in
                    AsyncImage(url: URL(string: song.imageURL)) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: bg.size.width, height: bg.size.height)
                            .blur(radius: 50)
                            .opacity(0.5)
                    } placeholder: {
                        Color.black
                    }
                }
                .ignoresSafeArea()
            }

                VStack {
                    HStack {
                        Button(action: {
                            withAnimation { showingLyrics = false }
                        }) {
                            Image(systemName: "chevron.left")
                                .font(.title2.bold())
                        }
                        .frame(width: 44, height: 44)

                        Spacer()

                        Text("歌词")
                            .font(.headline)

                        Spacer()

                        Spacer().frame(width: 44)
                    }
                    .padding(.horizontal)
                    .foregroundColor(.white)
                    .padding(.top, 10)

                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 25) {
                                if playerManager.parsedLyrics.isEmpty {
                                    Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                                        .font(.title2)
                                        .multilineTextAlignment(.center)
                                        .foregroundColor(.white)
                                } else {
                                    ForEach(playerManager.parsedLyrics) { line in
                                        let isActive = isCurrentLine(line)
                                        Text(line.text)
                                            .font(isActive ? .title2.bold() : .title3)
                                            .multilineTextAlignment(.center)
                                            .foregroundColor(isActive ? .white : .white.opacity(0.4))
                                            .scaleEffect(isActive ? 1.05 : 1.0)
                                            .animation(.spring(), value: isActive)
                                            .id(line.id)
                                            .padding(.horizontal)
                                    }
                                }
                            }
                            .padding(.vertical, 100)
                        }
                        .onChange(of: playerManager.currentTime) { _ in
                            if let currentLineID = activeLineID() {
                                withAnimation {
                                    proxy.scrollTo(currentLineID, anchor: .center)
                                }
                            }
                        }
                    }

                    HStack {
                        Button(action: {
                            withAnimation { showingLyrics = false }
                        }) {
                            HStack {
                                Image(systemName: "chevron.left")
                                Text("返回播放")
                            }
                            .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding(.bottom, 30)
                }
        }
    }

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

    private func isCurrentLine(_ line: PlayerManager.LyricLine) -> Bool {
        guard let index = playerManager.parsedLyrics.firstIndex(where: { $0.id == line.id }) else { return false }
        let currentTime = playerManager.currentTime
        let startTime = line.time
        let endTime = index + 1 < playerManager.parsedLyrics.count ? playerManager.parsedLyrics[index + 1].time : Double.infinity
        return currentTime >= startTime && currentTime < endTime
    }

    private func activeLineID() -> UUID? {
        playerManager.parsedLyrics.last(where: { $0.time <= playerManager.currentTime })?.id
    }
}

#Preview {
    PlayerView()
        .environmentObject(PlayerManager.shared)
}
