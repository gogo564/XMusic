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
