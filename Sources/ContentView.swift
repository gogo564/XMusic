import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var isKeyboardVisible = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                NavigationView {
                    HomeView()
                }
                .tabItem {
                    Label("推荐", systemImage: "music.note.house")
                }
                .tag(0)

                NavigationView {
                    SearchView()
                }
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .tag(1)

                NavigationView {
                    LibraryView()
                }
                .tabItem {
                    Label("我的", systemImage: "music.note.list")
                }
                .tag(2)
            }

            if !isKeyboardVisible {
                MiniPlayerLayer()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                isKeyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                isKeyboardVisible = false
            }
        }
    }
}

/// 迷你播放器 + 与播放器相关的全局弹层。
///
/// 单独持有 PlayerManager 的观察，避免播放进度（currentTime 每 0.5s 变化）
/// 触发 ContentView 整棵视图树重绘——否则 LibraryView 的 List 会被重建，
/// 导致播放时左滑删除弹回、点不到删除按钮。
struct MiniPlayerLayer: View {
    @EnvironmentObject var player: PlayerManager

    var body: some View {
        MiniPlayerView()
            .offset(y: -48)
            .onTapGesture {
                if player.currentSong != nil {
                    player.showPlayer = true
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
            .fullScreenCover(isPresented: $player.showPlayer) {
                PlayerView()
                    .environmentObject(player)
            }
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var recentStore = RecentStore.shared
    @EnvironmentObject var player: PlayerManager

    @State private var source = "wy"
    @State private var boards: [(id: String, bangid: String, name: String)] = []
    @State private var squareTags: [(name: String, id: String)] = []
    @State private var squarePlaylists: [LXOnlinePlaylist] = []
    @State private var selectedTagID: String?
    @State private var hotKeywords: [String] = []
    @State private var isLoadingBoards = true
    @State private var squareLoading = true
    @State private var sodaPlaylists: [SodaAPIClient.SodaPlaylist] = []
    @State private var sodaRadios: [SodaAPIClient.SodaRadio] = []

    let gridColumns = [
        GridItem(.flexible(), spacing: 15),
        GridItem(.flexible(), spacing: 15)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                sourcePicker
                if source == "soda" {
                    sodaSection
                } else {
                    rankSection
                    squareSection
                    if !hotKeywords.isEmpty {
                        hotSearchSection
                    }
                }
                if !recentStore.items.isEmpty {
                    recentPlayedSection
                }
                Spacer(minLength: 120)
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
        UIKitHorizontalScrollView {
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
        .frame(height: 34)
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

            UIKitHorizontalScrollView {
                HStack(spacing: 8) {
                    tagChip("推荐", id: nil)
                    ForEach(squareTags, id: \.id) { tag in
                        tagChip(tag.name, id: tag.id)
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: 36)
            .padding(.bottom, 14)

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

    // MARK: 汽水推荐（source == "soda"）
    private var sodaSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("🍺 汽水推荐歌单")
                        .font(.title2.bold())
                    Spacer()
                    if !SodaAPIClient.shared.isConfigured {
                        Text("未配置汽水服务")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                } else if sodaPlaylists.isEmpty {
                    Text("暂无推荐，请检查设置中的汽水服务地址")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                } else {
                    LazyVGrid(columns: gridColumns, spacing: 20) {
                        ForEach(sodaPlaylists) { pl in
                            NavigationLink(destination: SodaTrackListView(
                                title: pl.title,
                                load: { try await SodaAPIClient.shared.playlistSongs(playlistID: pl.id) }
                            )) {
                                VStack(alignment: .leading, spacing: 8) {
                                    AsyncImage(url: URL(string: pl.coverURL)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Image(systemName: "music.note.list").foregroundColor(.secondary)
                                    }
                                    .frame(height: 120)
                                    .cornerRadius(12)
                                    .clipped()
                                    .overlay(alignment: .bottomTrailing) {
                                        if pl.trackCount > 0 {
                                            Text("\(pl.trackCount)首")
                                                .font(.caption2.bold())
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.black.opacity(0.6))
                                                .cornerRadius(4)
                                                .padding(4)
                                        }
                                    }
                                    Text(pl.title)
                                        .font(.subheadline.bold())
                                        .lineLimit(1)
                                        .foregroundColor(.primary)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("📻 汽水电台")
                    .font(.title2.bold())
                    .padding(.horizontal)

                if sodaRadios.isEmpty {
                    Text("暂无电台")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                } else {
                    UIKitHorizontalScrollView {
                        HStack(spacing: 8) {
                            ForEach(sodaRadios) { radio in
                                NavigationLink(destination: SodaTrackListView(
                                    title: radio.title,
                                    load: { try await SodaAPIClient.shared.radioTracks(radioID: radio.id) }
                                )) {
                                    Text(radio.title)
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

            ForEach(recentStore.items.prefix(5)) { item in
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
        guard source != "soda" else {
            await loadSodaHome()
            return
        }
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
    private func loadSodaHome() async {
        isLoadingBoards = true
        defer { isLoadingBoards = false }
        sodaPlaylists = (try? await SodaAPIClient.shared.recommendPlaylists()) ?? []
        sodaRadios = (try? await SodaAPIClient.shared.radioList()) ?? []
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
    @EnvironmentObject var libraryStore: LibraryStore
    @State private var searchText = ""
    @State private var source = "wy"
    @State private var mode = 0 // 0 = 歌曲, 1 = 歌手, 2 = 专辑, 3 = 歌单
    @State private var songResults: [LXSong] = []
    @State private var artistResults: [LXArtist] = []
    @State private var albumResults: [LXAlbum] = []
    @State private var playlistResults: [LXOnlinePlaylist] = []
    @State private var hasSearched = false
    @State private var isLoading = false
    @FocusState private var searchFocused: Bool

    private var trimmedText: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            sourcePicker
            searchField
            if hasSearched && source != "soda" {
                modePicker
            }
            ScrollView(showsIndicators: false) {
                if !hasSearched {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("搜索歌曲、歌手、专辑、歌单")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 80)
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("搜索中…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 60)
                } else {
                    switch mode {
                    case 0: songResultsList
                    case 1: artistResultsList
                    case 2: albumResultsList
                    default: playlistResultsList
                    }
                }
                Spacer(minLength: 120)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    searchFocused = false
                }
            )
        }
        .navigationTitle("搜索")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("搜索") {
                    searchFocused = false
                    Task { await performSearch() }
                }
            }
        }
        .onChange(of: searchText) { _ in
            if hasSearched && trimmedText.isEmpty {
                hasSearched = false
                songResults = []
                artistResults = []
                albumResults = []
                playlistResults = []
            }
        }
        .onChange(of: source) { _ in
            if hasSearched { Task { await performSearch() } }
        }
        .onChange(of: mode) { _ in
            if hasSearched { Task { await performSearch() } }
        }
    }

    private var sourcePicker: some View {
        UIKitHorizontalScrollView {
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
        .frame(height: 42)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundColor(.secondary)
            TextField("搜索歌曲、歌手、专辑、歌单", text: $searchText)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .font(.system(size: 15))
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit {
                    searchFocused = false
                    Task { await performSearch() }
                }
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
            Text("歌曲").tag(0)
            Text("歌手").tag(1)
            Text("专辑").tag(2)
            Text("歌单").tag(3)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var songResultsList: some View {
        LazyVStack(spacing: 0) {
            if songResults.isEmpty {
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

    private var artistResultsList: some View {
        LazyVStack(spacing: 0) {
            if artistResults.isEmpty {
                emptyView(text: "未找到歌手")
            } else {
                ForEach(artistResults) { artist in
                    HStack(spacing: 12) {
                        NavigationLink(destination: ArtistDetailView(artist: artist, source: source)) {
                            HStack(spacing: 12) {
                                LXCachedImage(urlString: artist.picUrl, size: 48, cornerRadius: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(artist.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("歌手 · \(artist.albumSize) 张专辑")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        loveButton(loved: libraryStore.isArtistLoved(artist)) {
                            libraryStore.toggleArtist(artist)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.top, 4)
    }

    private var albumResultsList: some View {
        LazyVStack(spacing: 0) {
            if albumResults.isEmpty {
                emptyView(text: "未找到专辑")
            } else {
                ForEach(albumResults) { album in
                    HStack(spacing: 12) {
                        NavigationLink(destination: AlbumDetailView(album: album, source: source)) {
                            HStack(spacing: 12) {
                                LXCachedImage(urlString: album.picUrl, size: 48, cornerRadius: 10)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(album.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(album.artistName) · \(album.size) 首")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        loveButton(loved: libraryStore.isAlbumLoved(album)) {
                            libraryStore.toggleAlbum(album)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    Divider().padding(.leading, 76)
                }
            }
        }
        .padding(.top, 4)
    }

    private var playlistResultsList: some View {
        LazyVStack(spacing: 0) {
            if playlistResults.isEmpty {
                emptyView(text: "未找到歌单")
            } else {
                ForEach(playlistResults) { pl in
                    HStack(spacing: 12) {
                        NavigationLink(destination: PlaylistDetailView(playlist: pl, source: source)) {
                            OnlinePlaylistRow(playlist: pl)
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        loveButton(loved: libraryStore.isPlaylistLoved(pl)) {
                            libraryStore.togglePlaylist(pl)
                        }
                    }
                    Divider().padding(.leading, 68)
                }
            }
        }
        .padding(.top, 4)
    }

    private func loveButton(loved: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: loved ? "heart.fill" : "heart")
                .font(.system(size: 18))
                .foregroundColor(loved ? .red : .secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
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
        let text = trimmedText
        guard !text.isEmpty else { return }
        hasSearched = true
        isLoading = true
        if source == "soda" {
            // 汽水仅支持歌曲搜索（/search 需登录，未登录时可能返回空）
            mode = 0
            let tracks = (try? await SodaAPIClient.shared.search(keyword: text)) ?? []
            songResults = tracks.map { $0.toLXSong() }
            isLoading = false
            return
        }
        switch mode {
        case 0:
            do {
                songResults = try await LXAPIClient.shared.search(name: text, source: source, page: 1, pages: 3)
            } catch {
                songResults = []
            }
        case 1:
            let arr = (try? await LXAPIClient.shared.searchMulti(name: text, source: source, type: "singer")) ?? []
            artistResults = arr.map(LXArtist.init)
        case 2:
            let arr = (try? await LXAPIClient.shared.searchMulti(name: text, source: source, type: "album")) ?? []
            albumResults = arr.map(LXAlbum.init)
        default:
            playlistResults = (try? await LXAPIClient.shared.searchPlaylists(name: text, source: source)) ?? []
        }
        isLoading = false
    }
}

// MARK: - 歌手详情

struct ArtistDetailView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var libraryStore: LibraryStore
    let artist: LXArtist
    let source: String

    @State private var songs: [LXSong] = []
    @State private var albums: [LXAlbum] = []
    @State private var isLoading = true
    @State private var isLoadingSongs = true
    @State private var isLoadingAlbums = true
    @State private var showAlbums = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    LXCachedImage(urlString: artist.picUrl, size: 88, cornerRadius: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(artist.name)
                            .font(.system(size: 20, weight: .bold))
                        Text("歌手")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        libraryStore.toggleArtist(artist)
                    } label: {
                        Image(systemName: libraryStore.isArtistLoved(artist) ? "heart.fill" : "heart")
                            .font(.system(size: 24))
                            .foregroundColor(libraryStore.isArtistLoved(artist) ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                Button {
                    playAll()
                } label: {
                    Label("播放全部", systemImage: "play.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            if showAlbums {
                Section(header: Text("专辑")) {
                    if isLoadingAlbums {
                        HStack {
                            ProgressView()
                            Text("加载中…")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if albums.isEmpty {
                        Text("暂无专辑")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album, source: source)) {
                                HStack(spacing: 12) {
                                    LXCachedImage(urlString: album.picUrl, size: 48, cornerRadius: 10)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(album.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                        Text("\(album.artistName) · \(album.size) 首")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            } else {
                Section(header: Text("热门歌曲")) {
                    if isLoadingSongs {
                        HStack {
                            ProgressView()
                            Text("加载中…")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    } else if songs.isEmpty {
                        Text("暂无歌曲")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                            Button {
                                player.play(song: song, in: songs, index: idx)
                            } label: {
                                HStack(spacing: 12) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(song.singer)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if !song.interval.isEmpty {
                                        Text(song.interval)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(showAlbums ? "歌曲" : "专辑") {
                    showAlbums.toggle()
                }
            }
        }
        .onAppear {
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        isLoadingSongs = true
        isLoadingAlbums = true
        // 专辑独立加载
        Task {
            let arr = ((try? await LXAPIClient.shared.getArtistAlbums(source: source, artistID: artist.id)) ?? [])
            await MainActor.run {
                albums = arr.map(LXAlbum.init)
                isLoadingAlbums = false
            }
        }
        // 歌曲先拉第 1 页立即展示，剩余页后台合并
        let first = (try? await LXAPIClient.shared.getArtistSongs(source: source, artistID: artist.id, page: 1)) ?? ArtistSongsPage(list: [], total: 0)
        songs = first.list
        isLoadingSongs = false
        isLoading = false
        let total = first.total
        let totalPages = max(1, Int(ceil(Double(total) / 100.0)))
        if totalPages > 1 && first.list.count < total {
            var extra: [LXSong] = []
            for p in 2...totalPages {
                if let page = try? await LXAPIClient.shared.getArtistSongs(source: source, artistID: artist.id, page: p) {
                    extra.append(contentsOf: page.list)
                    if page.list.isEmpty { break }
                }
            }
            await MainActor.run {
                var merged = first.list
                for s in extra where !merged.contains(where: { $0.id == s.id }) {
                    merged.append(s)
                }
                songs = merged
            }
        }
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(song: songs[0], in: songs, index: 0)
    }
}

// MARK: - 专辑详情

struct AlbumDetailView: View {
    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var libraryStore: LibraryStore
    let album: LXAlbum
    let source: String

    @State private var songs: [LXSong] = []
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    LXCachedImage(urlString: album.picUrl, size: 96, cornerRadius: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.name)
                            .font(.system(size: 17, weight: .bold))
                            .lineLimit(2)
                        Text(album.artistName)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text("\(album.size) 首")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        libraryStore.toggleAlbum(album)
                    } label: {
                        Image(systemName: libraryStore.isAlbumLoved(album) ? "heart.fill" : "heart")
                            .font(.system(size: 24))
                            .foregroundColor(libraryStore.isAlbumLoved(album) ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 6)
                Button {
                    playAll()
                } label: {
                    Label("播放全部", systemImage: "play.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                }
            }
            Section(header: Text("曲目")) {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
                } else if songs.isEmpty {
                    Text("暂无歌曲")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                        Button {
                            player.play(song: song, in: songs, index: idx)
                        } label: {
                            HStack(spacing: 12) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(song.name)
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text(song.singer)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if !song.interval.isEmpty {
                                    Text(song.interval)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task { await load() }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        songs = (try? await LXAPIClient.shared.getAlbumSongs(source: source, albumID: album.id, cover: album.picUrl)) ?? []
        isLoading = false
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(song: songs[0], in: songs, index: 0)
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
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .navigationTitle(query)
        .onAppear { Task { await load() } }
    }

    @MainActor
    private func load() async {
        isLoading = true
        do {
            if source == "soda" {
                let tracks = try await SodaAPIClient.shared.search(keyword: query)
                songs = tracks.map { $0.toLXSong() }
            } else {
                songs = try await LXAPIClient.shared.search(name: query, source: source, page: 1, pages: 3)
            }
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
                                Text(player.sourceName.isEmpty ? "" : "\(MusicSources.name(player.sourceName)) \(MusicSources.qualityName(player.qualityName))")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                if !player.playbackOrigin.isEmpty {
                                    Text(player.playbackOrigin)
                                        .font(.system(size: 9, weight: .medium))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color(.systemGray5))
                                        .clipShape(Capsule())
                                }
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
