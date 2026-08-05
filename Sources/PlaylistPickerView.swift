import SwiftUI

struct PlaylistPickerView: View {
    let song: LXSong
    @EnvironmentObject private var playlistStore: PlaylistStore
    @Environment(\.dismiss) private var dismiss

    @State private var showNewPlaylist = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationView {
            List {
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("新建歌单并添加", systemImage: "plus.circle.fill")
                }
                Section(header: Text("我喜欢的音乐")) {
                    Button {
                        addToLove()
                    } label: {
                        Label("添加到「我喜欢的音乐」", systemImage: "heart.fill")
                    }
                }
                Section(header: Text("默认列表")) {
                    Button {
                        addToDefault()
                    } label: {
                        Label("添加到「默认列表」", systemImage: "music.note.list")
                    }
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
                        }
                    }
                }
                if let msg = message {
                    Section {
                        Text(msg)
                            .foregroundColor(isError ? .red : .green)
                            .font(.system(size: 13))
                    }
                }
            }
            .navigationTitle("添加到歌单")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showNewPlaylist) {
                NewPlaylistSheetView { created in
                    Task {
                        do {
                            try await playlistStore.addSong(song, toPlaylistID: created.id)
                            message = "已创建并添加"
                            isError = false
                        } catch {
                            message = error.localizedDescription
                            isError = true
                        }
                    }
                }
                .environmentObject(playlistStore)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func addToLove() {
        Task {
            do {
                try await playlistStore.addSongToLove(song)
                message = "已添加到「我喜欢的音乐」"
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
        }
    }

    private func addToDefault() {
        Task {
            do {
                try await playlistStore.addSongToDefault(song)
                message = "已添加到「默认列表」"
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
        }
    }

    private func add(to pid: String) {
        Task {
            do {
                try await playlistStore.addSong(song, toPlaylistID: pid)
                message = "已添加"
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
        }
    }
}
