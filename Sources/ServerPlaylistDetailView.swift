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
        songList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isEditing {
                    editBottomBar
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if kind == .user {
                        Button {
                            showRename = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                    }
                    Button(isEditing ? "完成" : "编辑") {
                        isEditing.toggle()
                        selectedIDs.removeAll()
                    }
                }
            }
            .sheet(isPresented: $showRename) {
                NewPlaylistSheetView(renameID: playlistID, initialName: title)
                    .environmentObject(playlistStore)
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
            Spacer()
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
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - 同一个列表（编辑模式就地加复选框，不做整页替换）

    private var songList: some View {
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
                        SongRow(
                            song: song,
                            showSource: false,
                            isEditing: isEditing,
                            isSelected: selectedIDs.contains(song.id),
                            onPlay: { s in
                                player.play(song: s, in: songs, index: idx)
                            },
                            onToggleSelect: {
                                toggleSelection(song.id)
                            }
                        )
                        .swipeActions(edge: .trailing) {
                            if !isEditing {
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
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
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
