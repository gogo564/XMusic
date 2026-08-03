import SwiftUI
import SwiftData

struct RecentPlaylistView: View {
    @Query(sort: \RecentTrackEntity.lastPlayed, order: .reverse)
    var recentTracks: [RecentTrackEntity]

    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack {
            List {
                if recentTracks.isEmpty {
                    Text("暂无播放记录")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(recentTracks) { item in
                        Button(action: {
                            playFromList(item)
                        }) {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: (item.imageUrl ?? "").normalizedMusicUrl)) { image in
                                    image.resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Image(systemName: "music.note")
                                        .foregroundColor(.secondary)
                                }
                                .frame(width: 50, height: 50)
                                .cornerRadius(8)
                                .clipped()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(item.singer)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if isCurrentTrack(item) {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(.accentColor)
                                        .font(.caption)
                                }
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                deleteRecent(item)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            if let song = item.song {
                                Button {
                                    toggleLove(song)
                                } label: {
                                    let isLoved = playlistStore.isLoved(song)
                                    Label(isLoved ? "取消收藏" : "收藏", systemImage: isLoved ? "heart.slash" : "heart")
                                }
                                .tint(playlistStore.isLoved(song) ? .gray : .red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("最近播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isCurrentTrack(_ item: RecentTrackEntity) -> Bool {
        playerManager.currentSong?.id == item.id
    }

    private func playFromList(_ item: RecentTrackEntity) {
        playerManager.playFromRecent(item)
        dismiss()
    }

    private func deleteRecent(_ item: RecentTrackEntity) {
        withAnimation {
            modelContext.delete(item)
            playerManager.setPlaylistFromRecent(recentTracks.filter { $0.id != item.id })
        }
    }

    private func toggleLove(_ song: LXSong) {
        if playlistStore.isLoved(song) {
            Task {
                try? await playlistStore.removeSongFromLove(song)
            }
            HapticManager.shared.impact(style: .light)
        } else {
            Task {
                try? await playlistStore.addSongToLove(song)
            }
            HapticManager.shared.notification(type: .success)
        }
    }
}
