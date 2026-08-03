import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var isShowingPlayer = false
    @EnvironmentObject var player: PlayerManager

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    HomeView()
                }
                .tabItem {
                    Label("推荐", systemImage: "music.note.house")
                }
                .tag(0)

                NavigationStack {
                    SearchView()
                }
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .tag(1)

                NavigationStack {
                    LibraryView()
                }
                .tabItem {
                    Label("我的", systemImage: "music.note.list")
                }
                .tag(2)
            }

            // Mini Player
            MiniPlayerView()
                .offset(y: -50)
                .onTapGesture {
                    if player.currentSong != nil {
                        isShowingPlayer = true
                    }
                }
        }
        .alert("播放错误", isPresented: Binding(
            get: { player.playbackError != nil },
            set: { if !$0 { player.playbackError = nil } }
        )) {
            Button("确定", role: .cancel) { player.playbackError = nil }
        } message: {
            Text(player.playbackError ?? "")
        }
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PlayerView()
                .environmentObject(player)
        }
    }
}

// MARK: - Home

struct HomeView: View {
    @Query(sort: \RecentTrackEntity.lastPlayed, order: .reverse) var recentTracks: [RecentTrackEntity]
    @EnvironmentObject var player: PlayerManager

    @State private var source = "wy"
    @State private var boards: [(id: String, bangid: String, name: String)] = []
    @State private var squareTags: [(name: String, id: String)] = []
    @State private var squarePlaylists: [LXOnlinePlaylist] = []
    @State private var selectedTagID: String?
    @State private var hotKeywords: [String] = []
    @State private var isLoadingBoards = true
    @State private var squareLoading = true

    let gridColumns = [
        GridItem(.flexible(), spacing: 15),
        GridItem(.flexible(), spacing: 15)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                sourcePicker
                rankSection
                squareSection
                if !hotKeywords.isEmpty {
                    hotSearchSection
                }
                if !recentTracks.isEmpty {
                    recentPlayedSection
                }
                Spacer(minLength: 100)
            }
            .padding(.top)
        }
        .navigationTitle("探索")
        .onAppear {
            if boards.isEmpty && hotKeywords.isEmpty {
                Task { await loadHome() }
            }
        }
        .onChange(of: source) { _ in
            Task { await loadHome() }
        }
    }

    // MARK: 音源选择
    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicSources.all, id: \.id) { s in
                    Button {
                        source = s.id
                    } label: {
                        Text(s.name)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(source == s.id ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(source == s.id ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: 热门榜单
    private var rankSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🏆 热门榜单")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(destination: RankCategoryView(source: source)) {
                    Text("查看全部")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            if isLoadingBoards {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if boards.isEmpty {
                Text("暂无榜单")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(Array(boards.prefix(8).enumerated()), id: \.offset) { _, board in
                        NavigationLink(destination: RankSongsView(rankId: board.bangid, rankName: board.name, source: source)) {
                            HStack(spacing: 8) {
                                Image(systemName: "chart.bar.fill")
                                    .foregroundColor(.accentColor)
                                Text(board.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: 歌单广场
    private var squareSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("🎵 歌单广场")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(destination: PlaylistListView(source: source)) {
                    Text("查看全部")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagChip("推荐", id: nil)
                    ForEach(squareTags, id: \.id) { tag in
                        tagChip(tag.name, id: tag.id)
                    }
                }
                .padding(.horizontal)
            }

            if squareLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if squarePlaylists.isEmpty {
                Text("歌单加载失败，请重试")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 20) {
                    ForEach(Array(squarePlaylists.prefix(10)), id: \.id) { pl in
                        NavigationLink(destination: PlaylistDetailView(playlist: pl, source: source)) {
                            VStack(alignment: .leading, spacing: 8) {
                                AsyncImage(url: URL(string: pl.imageURL)) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "music.note.list").foregroundColor(.secondary)
                                }
                                .frame(height: 120)
                                .cornerRadius(12)
                                .clipped()
                                .overlay(alignment: .bottomTrailing) {
                                    if pl.songCount > 0 {
                                        Text("\(pl.songCount)首")
                                            .font(.caption2.bold())
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.black.opacity(0.6))
                                            .cornerRadius(4)
                                            .padding(4)
                                    }
                                }
                                Text(pl.name)
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .foregroundColor(.primary)
                                if !pl.playCount.isEmpty {
                                    Text("播放 \(pl.playCount)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func tagChip(_ name: String, id: String?) -> some View {
        Button {
            guard selectedTagID != id else { return }
            selectedTagID = id
            Task { await loadSquare(tagID: id) }
        } label: {
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(selectedTagID == id ? Color.accentColor : Color(.systemGray5))
                .foregroundColor(selectedTagID == id ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 热搜
    private var hotSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🔥 热搜")
                .font(.title2.bold())
                .padding(.horizontal)

            ForEach(Array(hotKeywords.prefix(10).enumerated()), id: \.offset) { idx, keyword in
                NavigationLink(destination: SongSearchResultsView(query: keyword, source: source)) {
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(idx < 3 ? .red : .secondary)
                            .frame(width: 20)
                        Text(keyword)
                            .font(.system(size: 15))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 最近播放
    private var recentPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("⏱ 最近播放")
                    .font(.title2.bold())
                Spacer()
                NavigationLink(destination: RecentPlaylistView()) {
                    Text("查看全部")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal)

            ForEach(recentTracks.prefix(5)) { item in
                Button(action: {
                    player.playFromRecent(item)
                }) {
                    HStack {
                        AsyncImage(url: URL(string: (item.imageUrl ?? "").normalizedMusicUrl)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "music.note").foregroundColor(.secondary)
                        }
                        .frame(width: 50, height: 50)
                        .cornerRadius(8)
                        .clipped()
                        VStack(alignment: .leading) {
                            Text(item.name).font(.headline).foregroundColor(.primary)
                            Text(item.singer).font(.subheadline).foregroundColor(.secondary)
                        }
                        Spacer()
                        if player.currentSong?.id == item.id {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .foregroundColor(.accentColor)
                                .frame(width: 24, height: 24)
                        } else {
                            Image(systemName: "play.circle")
                                .foregroundColor(.secondary)
                                .frame(width: 24, height: 24)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal)
            }
        }
    }

    // MARK: 加载
    @MainActor
    private func loadHome() async {
        isLoadingBoards = true
        squareLoading = true
        async let hot = LXAPIClient.shared.getHotSearch(source: source)
        async let b = LXAPIClient.shared.getLeaderBoards(source: source)
        async let tags = LXAPIClient.shared.getSongListTags(source: source)
        hotKeywords = await (try? hot) ?? []
        let rawBoards = await (try? b) ?? []
        boards = rawBoards.compactMap { board in
            if let id = board["id"] as? String, let bangid = board["bangid"] as? String, let name = board["name"] as? String {
                return (id: id, bangid: bangid, name: name)
            }
            return nil
        }
        isLoadingBoards = false
        squareTags = await (try? tags) ?? []
        await loadSquare(tagID: selectedTagID)
    }

    @MainActor
    private func loadSquare(tagID: String?) async {
        squareLoading = true
        do {
            squarePlaylists = try await LXAPIClient.shared.getSongListByTag(source: source, tagId: tagID)
        } catch {
            squarePlaylists = []
        }
        squareLoading = false
    }
}

// MARK: - Search

struct SearchView: View {
    @EnvironmentObject var player: PlayerManager
    @State private var searchText = ""
    @State private var source = "wy"
    @State private var mode = 0 // 0 = 歌曲, 1 = 歌单
    @State private var songResults: [LXSong] = []
    @State private var playlistResults: [LXOnlinePlaylist] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            searchField
            if isSearching {
                modePicker
            }
            ScrollView {
                if isSearching {
                    if mode == 0 {
                        songResultsList
                    } else {
                        playlistResultsList
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("搜索你喜欢的音乐、歌手、歌单")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 80)
                }
            }
            .onTapGesture {
                searchFocused = false
            }
        }
        .navigationTitle("搜索")
        .onChange(of: searchText) { _ in
            debounce()
        }
        .onChange(of: source) { _ in
            if isSearching { Task { await performSearch() } }
        }
        .onChange(of: mode) { _ in
            if isSearching { Task { await performSearch() } }
        }
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MusicSources.all, id: \.id) { s in
                    Button {
                        source = s.id
                    } label: {
                        Text(s.name)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(source == s.id ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(source == s.id ? .white : .primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            TextField(mode == 0 ? "搜索歌曲 / 歌手" : "搜索歌单", text: $searchText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(size: 15))
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var modePicker: some View {
        Picker("搜索类型", selection: $mode) {
            Text("搜歌曲").tag(0)
            Text("搜歌单").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var songResultsList: some View {
        LazyVStack(spacing: 0) {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
            } else if songResults.isEmpty {
                emptyView(text: "未找到歌曲")
            } else {
                ForEach(Array(songResults.enumerated()), id: \.element.id) { idx, song in
                    SongRow(song: song, showSource: true) { s in
                        player.play(song: s, in: songResults, index: idx)
                    }
                    .padding(.horizontal, 16)
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.top, 4)
    }

    private var playlistResultsList: some View {
        LazyVStack(spacing: 0) {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
            } else if playlistResults.isEmpty {
                emptyView(text: "未找到歌单")
            } else {
                ForEach(playlistResults) { pl in
                    NavigationLink(destination: PlaylistDetailView(playlist: pl, source: source)) {
                        OnlinePlaylistRow(playlist: pl)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 68)
                }
            }
        }
        .padding(.top, 4)
    }

    private func emptyView(text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(text)
                .foregroundColor(.secondary)
        }
        .padding(40)
    }

    @MainActor
    private func performSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isLoading = true
        if mode == 0 {
            do {
                songResults = try await LXAPIClient.shared.search(name: text, source: source, page: 1, pages: 3)
            } catch {
                songResults = []
            }
        } else {
            do {
                playlistResults = try await LXAPIClient.shared.searchPlaylists(name: text, source: source)
            } catch {
                playlistResults = []
            }
        }
        isLoading = false
    }

    private func debounce() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            songResults = []
            playlistResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }
}

// MARK: - Hot search results (pushed from Home)

struct SongSearchResultsView: View {
    let query: String
    let source: String
    @EnvironmentObject var player: PlayerManager
    @State private var songs: [LXSong] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
            } else if songs.isEmpty {
                Text("未找到歌曲")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    SongRow(song: song, showSource: true) { s in
                        player.play(song: s, in: songs, index: idx)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(query)
        .onAppear { load() }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            songs = try await LXAPIClient.shared.search(name: query, source: source, page: 1, pages: 3)
        } catch {
            songs = []
        }
        isLoading = false
    }
}

// MARK: - Mini Player

struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerManager

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let song = player.currentSong {
                    AsyncImage(url: URL(string: song.imageURL)) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "music.note")
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 45, height: 45)
                    .cornerRadius(8)
                    .clipped()

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(song.singer)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            if !player.sourceName.isEmpty {
                                Text("•")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize()
                                Text("\(player.sourceName) \(player.qualityName)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .frame(width: 45, height: 45)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)

                    VStack(alignment: .leading) {
                        Text("未在播放")
                            .font(.system(size: 15, weight: .semibold))
                        Text("选择歌曲开始播放")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if player.isResolving {
                    ProgressView()
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 16) {
                    Button(action: {
                        player.playPrevious()
                        HapticManager.shared.selection()
                    }) {
                        Image(systemName: "backward.fill")
                            .font(.title3)
                            .foregroundColor(player.canPlayPrevious() ? .primary : .secondary.opacity(0.3))
                    }
                    .disabled(!player.canPlayPrevious())

                    Button(action: {
                        player.togglePlayPause()
                        HapticManager.shared.selection()
                    }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }

                    Button(action: {
                        player.playNext()
                        HapticManager.shared.selection()
                    }) {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .foregroundColor(player.canPlayNext() ? .primary : .secondary.opacity(0.3))
                    }
                    .disabled(!player.canPlayNext())

                    Button(action: {
                        player.togglePlayMode()
                        HapticManager.shared.selection()
                    }) {
                        Image(systemName: player.playModeIcon)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.trailing, 5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Progress Bar at the bottom
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))

                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(player.currentTime / max(player.duration, 1)))
                }
            }
            .frame(height: 3)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
    }
}

#Preview {
    ContentView()
        .environmentObject(PlayerManager.shared)
        .environmentObject(PlaylistStore.shared)
        .environmentObject(DownloadService.shared)
}
