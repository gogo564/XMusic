import SwiftUI

struct PlaylistDetailView: View {
    let playlist: LXOnlinePlaylist
    let source: String

    @EnvironmentObject var player: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @State private var songs: [LXSong] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isCollected = false
    @State private var collectBusy = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AsyncImage(url: URL(string: playlist.imageURL)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "music.note.list").foregroundColor(.secondary)
                        }
                        .frame(width: 88, height: 88)
                        .cornerRadius(10)
                        .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(playlist.name)
                                .font(.system(size: 16, weight: .bold))
                                .lineLimit(3)
                            if !playlist.playCount.isEmpty {
                                Text("播放 \(playlist.playCount)")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    if !playlist.desc.isEmpty {
                        Text(playlist.desc)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                    }
                    HStack(spacing: 12) {
                        Button {
                            playAll()
                        } label: {
                            Label("播放全部", systemImage: "play.circle.fill")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(songs.isEmpty)

                        Button {
                            toggleCollect()
                        } label: {
                            Label(isCollected ? "已收藏" : "收藏歌单",
                                  systemImage: isCollected ? "heart.fill" : "heart")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(isCollected ? .red : .accentColor)
                        .disabled(songs.isEmpty || collectBusy)
                    }
                }
                .padding(.vertical, 4)
            }
            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            Section {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(20)
                } else if songs.isEmpty {
                    Text("暂无歌曲")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(20)
                } else {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                        SongRow(song: song, showSource: true) { s in
                            player.play(song: s, in: songs, index: idx)
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
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            load()
        }
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(song: songs[0], in: songs, index: 0)
    }

    private func toggleCollect() {
        guard !songs.isEmpty, !collectBusy else { return }
        collectBusy = true
        Task {
            do {
                if isCollected {
                    _ = try await playlistStore.uncollectOnlinePlaylist(playlistID: playlist.id, source: source)
                    isCollected = false
                } else {
                    _ = try await playlistStore.collectOnlinePlaylist(playlist: playlist, source: source, songs: songs)
                    isCollected = true
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            collectBusy = false
        }
    }

    private func load() {
        guard songs.isEmpty else { return }
        isLoading = true
        Task {
            do {
                songs = try await LXAPIClient.shared.getSongListDetail(source: source, playlistID: playlist.id)
                isCollected = playlistStore.isOnlinePlaylistCollected(playlistID: playlist.id, source: source)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
