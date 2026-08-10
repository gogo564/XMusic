import SwiftUI

/// 汽水歌单/电台歌曲列表：异步加载 SodaTrack 并转为 LXSong 播放。
struct SodaTrackListView: View {
    let title: String
    let load: () async throws -> [SodaAPIClient.SodaTrack]

    @EnvironmentObject private var player: PlayerManager
    @State private var songs: [LXSong] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else if songs.isEmpty {
                Text("未获取到歌曲（汽水接口可能受限）")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    SongRow(song: song, showSource: true) { s in
                        player.play(song: s, in: songs, index: idx)
                        registerQueueRefresh()
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .navigationTitle(title)
        .onAppear {
            Task { await loadSongs() }
            registerQueueRefresh()
        }
        .onDisappear {
            player.queueRefreshHandler = nil
        }
        .onChange(of: player.queueRefreshCount) { _ in
            if !player.queue.isEmpty {
                songs = player.queue
            }
        }
    }

    /// 注册场景/推荐流队列刷新：播完一批后自动拉新一批替换队列
    private func registerQueueRefresh() {
        player.queueRefreshHandler = { [load] in
            do {
                let tracks = try await load()
                return tracks.map { $0.toLXSong() }
            } catch {
                return []
            }
        }
    }

    @MainActor
    private func loadSongs() async {
        guard songs.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let tracks = try await load()
            songs = tracks.map { $0.toLXSong() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// 首页汽水区的场景模式横排 chips：常用三模式（推荐/熟悉/新鲜）优先，随后补几个场景模式。
struct SodaModeChipsView: View {
    @State private var modes: [SodaAPIClient.SodaFeedMode] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && modes.isEmpty {
                Text("未获取到场景模式")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else if modes.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 12)
            } else {
                UIKitHorizontalScrollView {
                    HStack(spacing: 8) {
                        ForEach(modes) { m in
                            NavigationLink(destination: SodaTrackListView(
                                title: m.text,
                                load: {
                                    try await SodaAPIClient.shared.dailyMixTracks(
                                        sceneModeID: m.sceneModeID > 0 ? m.sceneModeID : nil,
                                        mode: m.type == "preference_mode" ? m.mode : nil
                                    )
                                }
                            )) {
                                Text(m.text)
                                    .font(.system(size: 13, weight: .medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color(.systemGray5))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 34)
            }
        }
        .onAppear {
            if !loaded {
                loaded = true
                Task { await loadModes() }
            }
        }
    }

    @MainActor
    private func loadModes() async {
        var all: [SodaAPIClient.SodaFeedMode] = []
        do { all = try await SodaAPIClient.shared.feedModes() } catch { all = [] }
        modes = Self.prioritizedModes(all).prefix(12).map { $0 }
    }

    /// 三模式（推荐/熟悉/新鲜）优先，再补场景模式
    static func prioritizedModes(_ all: [SodaAPIClient.SodaFeedMode]) -> [SodaAPIClient.SodaFeedMode] {
        let priority: [(String, String, String)] = [
            ("default", "推荐", "sparkles"),
            ("familiar", "熟悉", "heart.fill"),
            ("fresh", "新鲜", "leaf.fill"),
        ]
        var result: [SodaAPIClient.SodaFeedMode] = []
        for (key, text, icon) in priority {
            if let m = all.first(where: { $0.mode == key }) {
                result.append(m)
            } else {
                // feed/mode 未返回该偏好模式时兜底：直接构造
                result.append(SodaAPIClient.SodaFeedMode(
                    id: "pref_\(key)", text: text, type: "preference_mode",
                    mode: key, sceneModeID: 0, subQueueType: "", coverURI: ""
                ))
            }
        }
        let sceneModes = all.filter { $0.type == "scene_mode" && $0.sceneModeID > 0 }
        result.append(contentsOf: sceneModes)
        return result
    }
}

/// 汽水场景模式列表：45 个场景 + 常用三模式优先，点击进入该模式推荐流播放。
struct SodaModeListView: View {
    @State private var modes: [SodaAPIClient.SodaFeedMode] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let gridColumns = [
        GridItem(.flexible(), spacing: 15),
        GridItem(.flexible(), spacing: 15),
        GridItem(.flexible(), spacing: 15)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
                } else if let errorMessage {
                    VStack(spacing: 10) {
                        Text("模式加载失败").font(.headline)
                        Text(errorMessage).font(.caption).foregroundColor(.secondary)
                        Button("重试") { Task { await loadModes() } }.buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity).padding(30)
                } else {
                    modeGrid
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("场景音乐")
        .onAppear { Task { await loadModes() } }
    }

    private var modeGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 18) {
            ForEach(modes) { m in
                NavigationLink(destination: SodaTrackListView(
                    title: m.text,
                    load: {
                        try await SodaAPIClient.shared.dailyMixTracks(
                            sceneModeID: m.sceneModeID > 0 ? m.sceneModeID : nil,
                            mode: m.type == "preference_mode" ? m.mode : nil
                        )
                    }
                )) {
                    modeCell(m)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func modeCell(_ m: SodaAPIClient.SodaFeedMode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(
                        colors: [modeColor(m).opacity(0.85), modeColor(m).opacity(0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                Image(systemName: modeIcon(m))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(m.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
    }

    private func modeColor(_ m: SodaAPIClient.SodaFeedMode) -> Color {
        switch m.mode {
        case "default": return .pink
        case "familiar": return .orange
        case "fresh": return .green
        default:
            let hue = Double(abs(m.sceneModeID * 37) % 360) / 360.0
            return Color(hue: hue, saturation: 0.6, brightness: 0.7)
        }
    }

    private func modeIcon(_ m: SodaAPIClient.SodaFeedMode) -> String {
        switch m.mode {
        case "default": return "sparkles"
        case "familiar": return "heart.fill"
        case "fresh": return "leaf.fill"
        default: return "music.note"
        }
    }

    @MainActor
    private func loadModes() async {
        guard modes.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            let all = try await SodaAPIClient.shared.feedModes()
            modes = SodaModeChipsView.prioritizedModes(all)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// 汽水云收藏（歌单 / 专辑）：来自 /me/collection/mixed，读取自己账号的收藏。
struct SodaCollectionListView: View {
    @EnvironmentObject private var player: PlayerManager
    @State private var collections: [SodaAPIClient.SodaCollection] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else if collections.isEmpty {
                Text("暂无汽水云收藏\n可在汽水 App 收藏歌单或专辑后刷新")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ForEach(collections) { item in
                    if item.type == "playlist" {
                        NavigationLink(destination: SodaTrackListView(title: item.title, load: {
                            try await SodaAPIClient.shared.playlistSongs(playlistID: item.id)
                        })) {
                            collectionRow(item)
                        }
                    } else {
                        collectionRow(item)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("汽水收藏")
        .onAppear { Task { await loadCollections() } }
    }

    private func collectionRow(_ item: SodaAPIClient.SodaCollection) -> some View {
        HStack(spacing: 12) {
            LXCachedImage(urlString: item.coverURL, size: 48, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    @MainActor
    private func loadCollections() async {
        guard collections.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        do {
            collections = try await SodaAPIClient.shared.myCollections()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
