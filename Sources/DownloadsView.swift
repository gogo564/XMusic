import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloader: DownloadService

    var body: some View {
        List {
                if !downloader.activeSongs.isEmpty {
                    Section(header: Text("正在下载")) {
                        ForEach(Array(downloader.activeSongs.keys.sorted()), id: \.self) { key in
                            if let song = downloader.activeSongs[key] {
                                HStack(spacing: 12) {
                                    LXCachedImage(urlString: song.imageURL, size: 44)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.name)
                                            .font(.system(size: 14, weight: .medium))
                                            .lineLimit(1)
                                        Text(song.singer)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    let progress = downloader.activeTasks[key] ?? 0
                                    Text("\(Int(progress * 100))%")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.accentColor)
                                    Button {
                                        downloader.cancel(songID: key)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                if downloader.downloadedSongs.isEmpty && downloader.activeSongs.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text("暂无下载。\n在歌曲行点 ↓ 图标即可下载。")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                } else if !downloader.downloadedSongs.isEmpty {
                    Section(header: Text("已下载 (\(downloader.downloadedSongs.count))")) {
                        ForEach(downloader.downloadedSongs.sorted { $0.createdAt > $1.createdAt }) { d in
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 22))
                                    .foregroundColor(.accentColor)
                                    .frame(width: 44, height: 44)
                                    .background(Color(.systemGray5))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(d.singer)
                                        Text("·")
                                        Text(d.quality)
                                        Text("·")
                                        Text(sizeText(d.localFile))
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playLocal(d)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    downloader.delete(d)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
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
            .navigationTitle("下载")
    }

    private func playLocal(_ d: DownloadedSong) {
        let url = downloader.downloadsDir.appendingPathComponent(d.localFile)
        if FileManager.default.fileExists(atPath: url.path) {
            PlayerManager.shared.playLocalFile(url: url, title: d.name, artist: d.singer)
        }
    }

    private func sizeText(_ localFile: String) -> String {
        let url = downloader.downloadsDir.appendingPathComponent(localFile)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int64) ?? 0
        if bytes > 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.0fKB", Double(bytes) / 1024)
    }
}
