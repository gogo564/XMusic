import SwiftUI

struct AddSongsToPlaylistView: View {
    let songs: [LXSong]
    let playlistName: String

    @EnvironmentObject private var playlistStore: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false
    @State private var message: String?
    @State private var isError = false
    @State private var isWorking = false

    var body: some View {
        NavigationView {
            List {
                Button {
                    addAsNamedPlaylist()
                } label: {
                    HStack {
                        Label("一键整单加入：\(playlistName)", systemImage: "folder.badge.plus")
                            .foregroundColor(.accentColor)
                        Spacer()
                        if isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("新建歌单并添加", systemImage: "plus.circle.fill")
                }
                .disabled(isWorking)
                Section(header: Text("我喜欢的音乐")) {
                    Button {
                        addToLove()
                    } label: {
                        Label("添加到「我喜欢的音乐」", systemImage: "heart.fill")
                    }
                    .disabled(isWorking)
                }
                Section(header: Text("默认列表")) {
                    Button {
                        addToDefault()
                    } label: {
                        Label("添加到「默认列表」", systemImage: "music.note.list")
                    }
                    .disabled(isWorking)
                }
                if !playlistStore.playlists.isEmpty {
                    Section(header: Text("选择歌单")) {
                        ForEach(playlistStore.playlists) { pl in
                            Button {
                                add(to: pl.id)
                            } label: {
                                HStack {
                                    Text(pl.name)
                                    Spacer()
                                    Text("\(pl.songCount)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .disabled(isWorking)
                        }
                    }
                }
                if let msg = message {
                    Section {
                        HStack(spacing: 8) {
                            if isWorking {
                                ProgressView()
                            }
                            Text(msg)
                                .foregroundColor(isError ? .red : .green)
                                .font(.system(size: 13))
                        }
                    }
                }
            }
            .navigationTitle("添加到我的歌单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("新建歌单", isPresented: $showNewPlaylist) {
                TextField("歌单名称", text: $newPlaylistName)
                Button("创建") { create() }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    private func addAsNamedPlaylist() {
        run {
            try await playlistStore.addSongsToNamedPlaylist(songs, name: playlistName)
            return "已整单加入「\(playlistName)」"
        }
    }

    private func addToLove() {
        run {
            try await playlistStore.addSongsToLove(songs)
            return "已添加 \(songs.count) 首到「我喜欢的音乐」"
        }
    }

    private func addToDefault() {
        run {
            try await playlistStore.addSongsToDefault(songs)
            return "已添加 \(songs.count) 首到「默认列表」"
        }
    }

    private func add(to pid: String) {
        run {
            try await playlistStore.addSongsToPlaylist(songs, toPlaylistID: pid)
            return "已添加 \(songs.count) 首"
        }
    }

    private func create() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        run {
            try await playlistStore.createPlaylist(name: name)
            if let newList = playlistStore.playlists.first(where: { $0.name == name }) {
                try await playlistStore.addSongsToPlaylist(songs, toPlaylistID: newList.id)
            }
            return "已创建并添加 \(songs.count) 首"
        }
    }

    private func run(_ op: @escaping () async throws -> String) {
        isWorking = true
        Task {
            do {
                let success = try await op()
                message = success
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }
}
