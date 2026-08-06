import SwiftUI

struct PlaylistListView: View {
    let source: String

    @State private var playlists: [LXOnlinePlaylist] = []
    @State private var tags: [(name: String, id: String)] = []
    @State private var selectedTagID: String?
    @State private var isLoading = true
    @State private var currentPage = 1
    @State private var isLoadingMore = false
    @State private var hasMore = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    tagChip("推荐", id: nil)
                    ForEach(tags, id: \.id) { tag in
                        tagChip(tag.name, id: tag.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .background(Color(.systemGroupedBackground))

            List {
                if isLoading {
                    Section {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(30)
                    }
                } else if playlists.isEmpty {
                    Section {
                        Text("暂无歌单")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(30)
                    }
                } else {
                    Section {
                        ForEach(playlists) { pl in
                            NavigationLink(destination: PlaylistDetailView(playlist: pl, source: source)) {
                                OnlinePlaylistRow(playlist: pl)
                            }
                            .buttonStyle(.plain)
                        }
                        if isLoadingMore {
                            HStack { Spacer(); ProgressView(); Spacer() }
                        } else if hasMore {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { loadMore() }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
        .navigationTitle("歌单广场 · \(MusicSources.name(source))")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if tags.isEmpty { loadTags() }
            if playlists.isEmpty { Task { await load(reset: true) } }
        }
    }

    private func tagChip(_ name: String, id: String?) -> some View {
        Button {
            guard selectedTagID != id else { return }
            selectedTagID = id
            currentPage = 1
            hasMore = true
            Task { await load(reset: true) }
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

    private func loadTags() {
        Task {
            tags = (try? await LXAPIClient.shared.getSongListTags(source: source)) ?? []
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        if reset { playlists = [] }
        isLoading = true
        do {
            let items = try await LXAPIClient.shared.getSongListByTag(source: source, tagId: selectedTagID, page: currentPage)
            if reset {
                playlists = items
            } else {
                playlists.append(contentsOf: items)
            }
            hasMore = items.count >= 20
            currentPage += 1
        } catch {
            if reset { playlists = [] }
            hasMore = false
        }
        isLoading = false
    }

    private func loadMore() {
        guard !isLoadingMore && hasMore && !isLoading else { return }
        isLoadingMore = true
        Task {
            await load(reset: false)
            isLoadingMore = false
        }
    }
}
