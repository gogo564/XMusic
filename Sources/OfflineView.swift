import SwiftUI

/// 离线模式界面：仅展示本地可播放内容（已下载歌曲 + 最近播放中已缓存的歌曲），
/// 播放走下载文件/缓存文件路径，不触发网络解析。
struct OfflineView: View {
    @EnvironmentObject var player: PlayerManager
    @ObservedObject var recentStore = RecentStore.shared
    @EnvironmentObject var downloader: DownloadService

    private var cachedRecent: [(track: RecentTrack, song: LXSong)] {
        recentStore.items.compactMap { item -> (RecentTrack, LXSong)? in
            guard let song = item.song else { return nil }
            if DownloadService.shared.localURL(for: song) != nil { return (item, song) }
            if MusicCacheManager.shared.isCached(id: song.id) { return (item, song) }
            return nil
        }
    }

    private var downloadedSongs: [DownloadedSong] {
        downloader.downloadedSongs.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("已下载")) {
                    if downloadedSongs.isEmpty {
                        Text("暂无下载歌曲")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(downloadedSongs) { song in
                            Button {
                                playDownloaded(song)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(song.singer)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }

                Section(header: Text("已缓存")) {
                    if cachedRecent.isEmpty {
                        Text("暂无缓存歌曲")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(cachedRecent, id: \.track.id) { item in
                            Button {
                                player.play(song: item.song)
                            } label: {
                                HStack(spacing: 12) {
                                    LXCachedImage(urlString: item.track.imageUrl ?? "", size: 44, cornerRadius: 8)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.track.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Text(item.track.singer)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("离线模式")
            .overlay(alignment: .bottom) {
                Color.clear
                    .frame(height: 60)
                    .allowsHitTesting(false)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func playDownloaded(_ song: DownloadedSong) {
        downloader.playDownloaded(song)
    }
}
