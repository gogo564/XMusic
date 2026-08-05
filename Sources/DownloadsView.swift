import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var downloader: DownloadService

    @State private var isEditing = false
    @State private var selectedIDs: Set<String> = []

    private var downloadedSorted: [DownloadedSong] {
        downloader.downloadedSongs.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        List {
            if !downloader.activeSongs.isEmpty {
                activeSection
            }
            if downloader.downloadedSongs.isEmpty && downloader.activeSongs.isEmpty {
                emptySection
            } else if !downloader.downloadedSongs.isEmpty {
                downloadedSection
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isEditing {
                editBottomBar
            }
        }
        .navigationTitle("下载")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !downloader.downloadedSongs.isEmpty {
                    Button(isEditing ? "完成" : "编辑") {
                        isEditing.toggle()
                        selectedIDs.removeAll()
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Group {
                    if isEditing {
                        editBottomBar
                    }
                }
            }
        }
    }

    private var activeSection: some View {
        Section(header: Text("正在下载")) {
            ForEach(Array(downloader.activeSongs.keys.sorted()), id: \.self) { key in
                if let song = downloader.activeSongs[key] {
                    activeRow(song: song, key: key)
                }
            }
        }
    }

    private func activeRow(song: LXSong, key: String) -> some View {
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

    private var emptySection: some View {
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
    }

    private var downloadedSection: some View {
        Section(header: Text("已下载 (\(downloader.downloadedSongs.count))")) {
            ForEach(downloadedSorted) { d in
                downloadedRow(d)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if isEditing {
                            toggleSelection(d.id)
                        } else {
                            downloader.playDownloaded(d)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if !isEditing {
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

    private var editBottomBar: some View {
        HStack {
            Button {
                let allSelected = selectedIDs.count == downloader.downloadedSongs.count
                if allSelected {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(downloadedSorted.map { $0.id })
                }
            } label: {
                Label(selectedIDs.count == downloader.downloadedSongs.count ? "取消全选" : "全选", systemImage: "checklist")
            }
            Spacer()
            Text("\(selectedIDs.count)/\(downloader.downloadedSongs.count)")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Button(role: .destructive) {
                deleteSelected()
            } label: {
                Text("删除 (\(selectedIDs.count))")
                    .font(.system(size: 15, weight: .semibold))
            }
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func downloadedRow(_ d: DownloadedSong) -> some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: selectedIDs.contains(d.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(selectedIDs.contains(d.id) ? .accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(d.id)
                    }
            }
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
            if !isEditing {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func toggleSelection(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        }
    }

    private func deleteSelected() {
        guard !selectedIDs.isEmpty else { return }
        let target = downloadedSorted.filter { selectedIDs.contains($0.id) }
        downloader.deleteMany(target)
        selectedIDs.removeAll()
    }

    private func sizeText(_ localFile: String) -> String {
        let url = downloader.downloadsDir.appendingPathComponent(localFile)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int64) ?? 0
        if bytes > 1024 * 1024 { return String(format: "%.1fMB", Double(bytes) / (1024 * 1024)) }
        return String(format: "%.0fKB", Double(bytes) / 1024)
    }
}
