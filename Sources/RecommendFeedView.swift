import SwiftUI

// 汽水音乐式竖滑推荐流：模式胶囊 + 全屏竖滑卡片，滑到自动预播
struct RecommendFeedView: View {
    @ObservedObject var engine = RecommendationEngine.shared
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var downloader: DownloadService

    @State private var currentIndex = 0
    @State private var scrollToPage: Int?
    @State private var hasLoaded = false

    let pageHeight: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            modeChips
            feedArea
        }
        .onAppear {
            if !hasLoaded {
                hasLoaded = true
                Task { await load() }
            }
        }
        .onChange(of: currentIndex) { idx in
            playCurrent(at: idx)
        }
    }

    // MARK: - 模式切换

    private var modeChips: some View {
        HStack(spacing: 8) {
            ForEach(RecommendMode.allCases) { m in
                Button {
                    selectMode(m)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: m.icon)
                            .font(.system(size: 11))
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(engine.mode == m ? Color.accentColor : Color(.systemGray5))
                    .foregroundColor(engine.mode == m ? .white : .primary)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private func selectMode(_ m: RecommendMode) {
        guard engine.mode != m else { return }
        HapticManager.shared.selection()
        engine.setMode(m)
        currentIndex = 0
        scrollToPage = 0
        Task {
            await engine.loadCurrentMode()
            await MainActor.run { playCurrent(at: 0, force: true) }
        }
    }

    // MARK: - 卡片流

    @ViewBuilder
    private var feedArea: some View {
        if engine.isLoading && engine.recommendations.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在为你挑歌…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: pageHeight)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        } else if let err = engine.errorMessage, engine.recommendations.isEmpty {
            VStack(spacing: 12) {
                Text("推荐加载失败")
                    .font(.headline)
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button("重试") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .frame(height: pageHeight)
        } else {
            VerticalPager(
                pageHeight: pageHeight,
                pageCount: engine.recommendations.count,
                currentPage: $currentIndex,
                scrollTo: $scrollToPage
            ) {
                ForEach(Array(engine.recommendations.enumerated()), id: \.element.id) { idx, song in
                    FeedCard(
                        song: song,
                        queue: engine.recommendations,
                        index: idx,
                        isActive: idx == currentIndex,
                        onLove: { toggleLove(song) },
                        onSkip: {
                            guard !engine.recommendations.isEmpty else { return }
                            scrollToPage = (idx + 1) % engine.recommendations.count
                        }
                    )
                    .frame(height: pageHeight)
                }
            }
            .frame(height: pageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
    }

    // MARK: - 播放 / 收藏

    private func playCurrent(at idx: Int, force: Bool = false) {
        guard engine.recommendations.indices.contains(idx) else { return }
        let song = engine.recommendations[idx]
        if !force, player.currentSong?.id == song.id { return }
        player.play(song: song, in: engine.recommendations, index: idx, presentPlayer: false)
    }

    private func toggleLove(_ song: LXSong) {
        HapticManager.shared.impact(style: .light)
        Task {
            do {
                if playlistStore.isLoved(song) {
                    try await playlistStore.removeSongFromLove(song)
                } else {
                    try await playlistStore.addSongToLove(song)
                }
            } catch {
                // 静默失败
            }
        }
    }

    private func load() async {
        if playlistStore.listData == nil {
            await playlistStore.refresh()
        }
        let loved = playlistStore.listData?.loveSongs ?? []
        await engine.load(recent: RecentStore.shared.items, loved: loved)
        await MainActor.run { playCurrent(at: 0, force: true) }
    }
}

// MARK: - 推荐卡片

struct FeedCard: View {
    let song: LXSong
    let queue: [LXSong]
    let index: Int
    let isActive: Bool
    var onLove: () -> Void
    var onSkip: () -> Void

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var downloader: DownloadService

    @State private var showPlaylistPicker = false
    @State private var showQualityPicker = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            coverBackground
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
            infoAndActions
        }
        .contentShape(Rectangle())
        .onTapGesture {
            player.play(song: song, in: queue, index: index)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(song: song).environmentObject(playlistStore)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerView(song: song).environmentObject(player)
        }
    }

    private var coverBackground: some View {
        AsyncImage(url: URL(string: song.imageURL)) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                LinearGradient(colors: [.blue.opacity(0.35), .purple.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var infoAndActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer()

            if isActive && player.currentSong?.id == song.id && player.isPlaying {
                Label("播放中", systemImage: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.25))
                    .clipShape(Capsule())
            }

            Text(song.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
            Text(song.singer)
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(MusicSources.name(song.source))
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.25))
                    .foregroundColor(.white)
                    .clipShape(Capsule())
                if !qualityBadge.isEmpty {
                    Text(qualityBadge)
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(qualityBadgeColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                if isCached {
                    Text("缓存")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                if isDownloaded {
                    Text("已下载")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 22) {
                Button {
                    onLove()
                } label: {
                    Image(systemName: playlistStore.isLoved(song) ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundColor(playlistStore.isLoved(song) ? .red : .white)
                }
                .buttonStyle(.plain)

                Button {
                    showQualityPicker = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Button {
                    showPlaylistPicker = true
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    onSkip()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qualityBadge: String {
        let qs = song.qualities.map { $0.type.lowercased() }
        if qs.contains("flac24bit") { return "Hi-Res" }
        if qs.contains("flac") { return "SQ" }
        if qs.contains("320k") { return "HQ" }
        if let first = song.qualities.first?.type, !first.isEmpty { return first }
        return ""
    }

    private var qualityBadgeColor: Color {
        switch qualityBadge {
        case "Hi-Res": return .purple
        case "SQ": return .blue
        case "HQ": return .orange
        default: return .gray
        }
    }

    private var isCached: Bool {
        MusicCacheManager.shared.isCached(id: song.id)
    }

    private var isDownloaded: Bool {
        downloader.isDownloaded(song)
    }
}
