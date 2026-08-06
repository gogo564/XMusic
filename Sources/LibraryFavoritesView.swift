import SwiftUI

// 收藏歌手 / 收藏专辑 (server /api/user/library/artists, /api/user/library/albums)
struct LibraryFavoritesView: View {
    @EnvironmentObject var player: PlayerManager
    @State private var artists: [LXLibraryArtist] = []
    @State private var albums: [LXLibraryAlbum] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, artists.isEmpty && albums.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("重试") {
                        Task { await load() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                List {
                    if !artists.isEmpty {
                        Section(header: Text("收藏歌手")) {
                            ForEach(artists) { artist in
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: artist.picUrl)) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        Image(systemName: "music.mic")
                                            .foregroundColor(.secondary)
                                    }
                                    .frame(width: 48, height: 48)
                                    .clipShape(Circle())
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(artist.name)
                                            .font(.system(size: 15, weight: .medium))
                                            .lineLimit(1)
                                        Text("歌手")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .onDelete { offsets in
                                removeArtists(at: offsets)
                            }
                        }
                    }

                    if !albums.isEmpty {
                        Section(header: Text("收藏专辑")) {
                            ForEach(albums) { album in
                                NavigationLink(destination: LibraryAlbumDetailView(album: album)) {
                                    HStack(spacing: 12) {
                                        AsyncImage(url: URL(string: album.picUrl)) { image in
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } placeholder: {
                                            Image(systemName: "music.note.list")
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(width: 48, height: 48)
                                        .cornerRadius(10)
                                        .clipped()
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(album.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .lineLimit(1)
                                            Text(album.songCount > 0 ? "\(album.artistName) · \(album.songCount) 首" : "\(album.artistName) · 专辑")
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            .onDelete { offsets in
                                removeAlbums(at: offsets)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("收藏")
        .refreshable {
            await load()
        }
        .onAppear {
            if artists.isEmpty && albums.isEmpty {
                Task { await load() }
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let a = LXAPIClient.shared.getLibraryArtists()
            async let b = LXAPIClient.shared.getLibraryAlbums()
            let (artistArr, albumArr) = try await (a, b)
            artists = artistArr.map(LXLibraryArtist.init)
            albums = albumArr.map(LXLibraryAlbum.init)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func removeArtists(at offsets: IndexSet) {
        artists.remove(atOffsets: offsets)
        Task {
            let payloads = artists.map { $0.toPayload() }
            try? await LXAPIClient.shared.saveLibraryArtists(payloads)
        }
    }

    private func removeAlbums(at offsets: IndexSet) {
        albums.remove(atOffsets: offsets)
        Task {
            let payloads = albums.map { $0.toPayload() }
            try? await LXAPIClient.shared.saveLibraryAlbums(payloads)
        }
    }
}

// 收藏专辑详情：播放专辑内曲目（打开时动态拉取歌曲，收藏数据仅存专辑元信息）
struct LibraryAlbumDetailView: View {
    @EnvironmentObject var player: PlayerManager
    let album: LXLibraryAlbum
    @State private var songs: [LXSong] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage, songs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("重试") {
                        Task { await loadSongs() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: album.picUrl)) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "music.note.list")
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 88, height: 88)
                            .cornerRadius(12)
                            .clipped()
                            VStack(alignment: .leading, spacing: 6) {
                                Text(album.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .lineLimit(2)
                                Text(album.artistName)
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                Text("\(songs.count) 首")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        if !songs.isEmpty {
                            Button {
                                playAll()
                            } label: {
                                Label("播放全部", systemImage: "play.circle.fill")
                                    .font(.system(size: 15, weight: .medium))
                            }
                        }
                    }
                    Section {
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
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadSongs()
        }
    }

    private func loadSongs() async {
        isLoading = true
        errorMessage = nil
        do {
            songs = try await LXAPIClient.shared.getAlbumSongs(source: album.source, albumID: album.albumID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(song: songs[0], in: songs, index: 0)
    }
}
