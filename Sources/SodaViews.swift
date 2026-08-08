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
        .onAppear { Task { await loadSongs() } }
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
