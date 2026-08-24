import SwiftUI

struct RankCategoryView: View {
    let source: String

    @EnvironmentObject var player: PlayerManager
    @State private var categories: [(id: String, bangid: String, name: String)] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(40)
                } else if categories.isEmpty {
                    Text("暂无榜单数据")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                        NavigationLink(destination: RankSongsView(rankId: category.bangid, rankName: category.name, source: source)) {
                            HStack {
                                Text(category.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 16)
                    }
                }
                Spacer(minLength: 120)
            }
        }
        .navigationTitle("热门榜单 · \(MusicSources.name(source))")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if categories.isEmpty {
                load()
            }
        }
    }

    private func load() {
        isLoading = true
        Task {
            do {
                let raw = try await LXAPIClient.shared.getLeaderBoards(source: source)
                categories = raw.compactMap { board in
                    if let id = board["id"] as? String, let bangid = board["bangid"] as? String, let name = board["name"] as? String {
                        return (id: id, bangid: bangid, name: name)
                    }
                    return nil
                }
            } catch {
                categories = []
            }
            isLoading = false
        }
    }
}

struct RankSongsView: View {
    let rankId: String
    let rankName: String
    let source: String

    @EnvironmentObject var player: PlayerManager
    @State private var songs: [LXSong] = []
    @State private var isLoading = true

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
            } else if songs.isEmpty {
                Text("该榜单暂无歌曲")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(30)
            } else {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    HStack(spacing: 12) {
                        Text("\(idx + 1)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(idx < 3 ? .red : .secondary)
                            .frame(width: 24)
                        SongRow(song: song, showSource: true) { s in
                            player.play(song: s, in: songs, index: idx)
                        }
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
        .navigationTitle(rankName)
        .onAppear {
            load()
        }
    }

    private func load() {
        isLoading = true
        Task {
            do {
                songs = try await LXAPIClient.shared.getLeaderBoardSongs(source: source, bangid: rankId)
                player.silentSetPlaylist(songs)
            } catch {
                songs = []
            }
            isLoading = false
        }
    }
}
