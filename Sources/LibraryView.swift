import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var downloader: DownloadService
    @StateObject private var cacheManager = MusicCacheManager.shared

    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var showRename = false
    @State private var renameTarget: LXPlaylist?
    @State private var renameText = ""

    var body: some View {
        Group {
            if let error = playlistStore.errorMessage, playlistStore.listData == nil {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                    Button("重试") {
                        Task { await playlistStore.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                listContent
            }
        }
        .navigationTitle("我的")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewPlaylist = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("新建歌单", isPresented: $showNewPlaylist) {
            TextField("名称", text: $newName)
            Button("创建") { create() }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("保存") { rename() }
            Button("取消", role: .cancel) {}
        }
        .refreshable {
            await playlistStore.refresh()
        }
        .onAppear {
            if playlistStore.listData == nil {
                Task { await playlistStore.refresh() }
            }
        }
    }

    private var listContent: some View {
        Group {
            if let data = playlistStore.listData {
                List {
                    Section(header: Text("我的歌单")) {
                        NavigationLink(destination: ServerPlaylistDetailView(kind: .defaultList)) {
                            libraryRow(name: "默认列表", count: data.defaultSongs.count, image: "music.note.list", color: .accentColor)
                        }
                        NavigationLink(destination: ServerPlaylistDetailView(kind: .love)) {
                            libraryRow(name: "我喜欢的音乐", count: data.loveSongs.count, image: "heart.fill", color: .red)
                        }
                        if !data.userList.isEmpty {
                            ForEach(data.userList) { pl in
                                NavigationLink(destination: ServerPlaylistDetailView(kind: .user, playlistID: pl.id)) {
                                    playlistRow(pl)
                                }
                                .contextMenu {
                                    Button("重命名") {
                                        renameTarget = pl
                                        renameText = pl.name
                                        showRename = true
                                    }
                                    Button("删除", role: .destructive) {
                                        deletePlaylist(pl)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deletePlaylist(pl)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    Section(header: Text("存储空间")) {
                        HStack {
                            Text("缓存占用")
                            Spacer()
                            Text(cacheManager.cacheSizeString)
                                .foregroundColor(.secondary)
                        }
                        Button {
                            cacheManager.clearCache()
                            HapticManager.shared.notification(type: .success)
                        } label: {
                            Text("清除缓存")
                                .foregroundColor(.red)
                        }
                    }

                    Section {
                        NavigationLink(destination: DownloadsView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("下载")
                                        .font(.system(size: 15, weight: .medium))
                                    Text("\(downloader.downloadedSongs.count) 首已下载")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Section {
                        NavigationLink(destination: SettingsView(needsConfig: .constant(false))) {
                            HStack(spacing: 12) {
                                Image(systemName: "gearshape")
                                    .foregroundColor(.secondary)
                                    .frame(width: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("设置")
                                        .font(.system(size: 15, weight: .medium))
                                    Text(AppConfigStore.shared.config.normalizedBaseURL)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .contentInset(EdgeInsets(top: 0, leading: 0, bottom: 120, trailing: 0))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func libraryRow(name: String, count: Int, image: String, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.18))
                    .frame(width: 48, height: 48)
                Image(systemName: image)
                    .font(.system(size: 22))
                    .foregroundColor(color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text("\(count) 首")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func playlistRow(_ pl: LXPlaylist) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: pl.cover)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "music.note.list").foregroundColor(.secondary)
            }
            .frame(width: 48, height: 48)
            .cornerRadius(10)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(pl.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text("\(pl.songCount) 首")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            try? await playlistStore.createPlaylist(name: name)
            newName = ""
        }
    }

    private func rename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            try? await playlistStore.renamePlaylist(id: target.id, newName: name)
        }
    }

    private func deletePlaylist(_ pl: LXPlaylist) {
        Task {
            try? await playlistStore.deletePlaylist(id: pl.id)
        }
    }
}
