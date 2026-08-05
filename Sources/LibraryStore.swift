import Foundation
import Combine

/// 收藏歌手 / 收藏专辑的共享状态 (server /api/user/library/artists, /api/user/library/albums)
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var artists: [LXLibraryArtist] = []
    @Published private(set) var albums: [LXLibraryAlbum] = []
    @Published private(set) var isLoaded = false

    private init() {}

    @MainActor
    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await reload()
    }

    @MainActor
    func reload() async {
        do {
            async let a = LXAPIClient.shared.getLibraryArtists()
            async let b = LXAPIClient.shared.getLibraryAlbums()
            let (artistArr, albumArr) = try await (a, b)
            artists = artistArr.map(LXLibraryArtist.init)
            albums = albumArr.map(LXLibraryAlbum.init)
            isLoaded = true
        } catch {
            isLoaded = true
        }
    }

    func isArtistLoved(_ artist: LXArtist) -> Bool {
        artists.contains { $0.artistID == artist.id && $0.source == artist.source }
    }

    func isAlbumLoved(_ album: LXAlbum) -> Bool {
        albums.contains { $0.albumID == album.id && $0.source == album.source }
    }

    func isPlaylistLoved(_ playlist: LXOnlinePlaylist) -> Bool {
        PlaylistStore.shared.isOnlinePlaylistCollected(playlistID: playlist.id, source: playlist.source)
    }

    func toggleArtist(_ artist: LXArtist) {
        let current = artist.toPayload()
        if isArtistLoved(artist) {
            artists.removeAll { $0.artistID == artist.id && $0.source == artist.source }
        } else {
            artists.insert(LXLibraryArtist(current), at: 0)
        }
        persistArtists()
    }

    func toggleAlbum(_ album: LXAlbum) {
        let current = album.toPayload()
        if isAlbumLoved(album) {
            albums.removeAll { $0.albumID == album.id && $0.source == album.source }
        } else {
            albums.insert(LXLibraryAlbum(current), at: 0)
        }
        persistAlbums()
    }

    func togglePlaylist(_ playlist: LXOnlinePlaylist) {
        Task {
            let collected = PlaylistStore.shared.isOnlinePlaylistCollected(playlistID: playlist.id, source: playlist.source)
            if collected {
                _ = try? await PlaylistStore.shared.uncollectOnlinePlaylist(playlistID: playlist.id, source: playlist.source)
            } else {
                // 需要歌曲列表才能收藏，先拉取
                if let songs = try? await LXAPIClient.shared.getSongListDetail(source: playlist.source, playlistID: playlist.id) {
                    _ = try? await PlaylistStore.shared.collectOnlinePlaylist(playlist: playlist, source: playlist.source, songs: songs)
                }
            }
            await PlaylistStore.shared.refresh()
        }
    }

    private func persistArtists() {
        let payloads = artists.map { $0.toPayload() }
        Task {
            try? await LXAPIClient.shared.saveLibraryArtists(payloads)
        }
    }

    private func persistAlbums() {
        let payloads = albums.map { $0.toPayload() }
        Task {
            try? await LXAPIClient.shared.saveLibraryAlbums(payloads)
        }
    }
}
