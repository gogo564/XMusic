import SwiftUI

struct ServerPlaylistDetailView: View {
    let kind: LXListKind
    let playlistID: String

    init(kind: LXListKind, playlistID: String = "") {
        self.kind = kind
        self.playlistID = playlistID
    }

    @EnvironmentObject private var playlistStore: PlaylistStore
    @EnvironmentObject private var player: PlayerManager
    @State private var message: String?

    private var songs: [LXSong] {
        playlistStore.songs(kind: kind, playlistID: playlistID)
    }

    private var title: String {
        switch kind {
        case .defaultList: return "默认列表"
        case .love: return "我喜欢的音乐"
        case .user: return playlistStore.playlist(id: playlistID)?.name ?? "歌单"
        }
    }

    var body: some View {
        List {
            Section {
                Button {
                    playAll()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                if let msg = message {
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    SongRow(song: song, showSource: false) { s in
                        player.play(song: s, in: songs, index: idx)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            remove(at: idx)
                        } label: {
                            Label("删除", systemImage: "trash")
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
        .navigationTitle(title)
    }

    private func playAll() {
        guard !songs.isEmpty else { return }
        player.play(song: songs[0], in: songs, index: 0)
    }

    private func remove(at index: Int) {
        Task {
            do {
                switch kind {
                case .defaultList:
                    try await playlistStore.removeSongFromDefault(at: index)
                case .love:
                    guard songs.indices.contains(index) else { return }
                    try await playlistStore.removeSongFromLove(songs[index])
                case .user:
                    try await playlistStore.removeSong(at: index, fromPlaylistID: playlistID)
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
