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
    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []
    @State private var showRename = false
    @State private var isDeleting = false

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
        Group {
            if isEditing {
                editingList
            } else {
                normalList
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                editBottomBar
            } else {
                Color.clear
                    .frame(height: 120)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if kind == .user {
                    Button {
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                }
                Button(isEditing ? "完成" : "选择") {
                    withAnimation { isEditing.toggle() }
                    selectedIDs.removeAll()
                }
            }
        }
        .sheet(isPresented: $showRename) {
            NewPlaylistSheetView(renameID: playlistID, initialName: title)
                .environmentObject(playlistStore)
        }
    }

    // MARK: - Normal list

    private var normalList: some View {
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
                if songs.isEmpty {
                    Text("暂无歌曲")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
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
        }
    }

    // MARK: - Editing list

    private var editingList: some View {
        List {
            Section {
                if songs.isEmpty {
                    Text("暂无歌曲")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(songs) { song in
                        HStack(spacing: 10) {
                            Image(systemName: selectedIDs.contains(song.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20))
                                .foregroundColor(selectedIDs.contains(song.id) ? .accentColor : .secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    toggleSelection(song.id)
                                }
                            LXCachedImage(urlString: song.imageURL, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(song.singer)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            toggleSelection(song.id)
                        }
                    }
                }
            }
        }
    }

    private var editBottomBar: some View {
        HStack {
            Button {
                let allSelected = selectedIDs.count == songs.count
                if allSelected {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(songs.map { $0.id })
                }
            } label: {
                Label(selectedIDs.count == songs.count ? "取消全选" : "全选", systemImage: "checklist")
            }
            Spacer()
            if !songs.isEmpty {
                Text("\(selectedIDs.count)/\(songs.count)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Text("删除 (\(selectedIDs.count))")
                    .font(.system(size: 15, weight: .semibold))
            }
            .disabled(selectedIDs.isEmpty || isDeleting)
            .overlay {
                if isDeleting {
                    ProgressView()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
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

    private func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        let indices = songs.indices.filter { selectedIDs.contains(songs[$0].id) }
        isDeleting = true
        Task {
            do {
                switch kind {
                case .defaultList:
                    try await playlistStore.removeSongsFromDefault(at: indices)
                case .love:
                    try await playlistStore.removeSongsFromLove(at: indices)
                case .user:
                    try await playlistStore.removeSongs(at: indices, fromPlaylistID: playlistID)
                }
                selectedIDs.removeAll()
                isDeleting = false
            } catch {
                message = error.localizedDescription
                isDeleting = false
            }
        }
    }
}
