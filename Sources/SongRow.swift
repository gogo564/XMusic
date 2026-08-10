import SwiftUI

struct SongRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloader: DownloadService
    @EnvironmentObject private var playlistStore: PlaylistStore

    let song: LXSong
    let showSource: Bool
    var isEditing: Bool = false
    var isSelected: Bool = false
    var showHeart: Bool = true
    var onPlay: ((LXSong) -> Void)?
    var onToggleSelect: (() -> Void)?

    @State private var showMenu = false
    @State private var showPlaylistPicker = false
    @State private var showQualityPicker = false
    @State private var showCollectAlert = false
    @State private var collectMessage = ""

    var body: some View {
        HStack(spacing: 12) {
            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onToggleSelect?()
                    }
            }
            LXCachedImage(urlString: song.imageURL, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if player.currentSong?.id == song.id {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                    }
                    Text(song.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(player.currentSong?.id == song.id ? .accentColor : .primary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if showSource {
                        Text(sourceName(song.source))
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                        if !qualityBadge.isEmpty {
                            Text(qualityBadge)
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(qualityBadgeColor.opacity(0.18))
                                .foregroundColor(qualityBadgeColor)
                                .clipShape(Capsule())
                        }
                        if isCached {
                            Text("缓存")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .clipShape(Capsule())
                        }
                        if isDownloaded {
                            Text("已下载")
                                .font(.system(size: 9))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .foregroundColor(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(song.singer)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailingView
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                onToggleSelect?()
            } else if let onPlay = onPlay {
                onPlay(song)
            } else {
                player.play(song: song)
            }
        }
        .confirmationDialog(song.name, isPresented: $showMenu, titleVisibility: .visible) {
            Button("立即播放") { player.play(song: song) }
            Button("选择音质播放") { showQualityPicker = true }
            Button("下一首播放") { player.playNext(with: song) }
            Button("添加到歌单") { showPlaylistPicker = true }
            if song.source == "soda" {
                Button("收藏到汽水歌单") { collectToSoda() }
            }
            if !downloader.isDownloaded(song), song.source != "soda" {
                Button("下载 (320k)") { downloader.download(song, quality: "320k") }
                Button("下载 (无损)") { downloader.download(song, quality: "flac") }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerView(song: song)
                .environmentObject(PlaylistStore.shared)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerView(song: song)
                .environmentObject(player)
        }
        .alert(collectMessage, isPresented: $showCollectAlert) {
            Button("好的", role: .cancel) {}
        }
    }

    private func collectToSoda() {
        guard let trackID = song.songmid, !trackID.isEmpty else {
            collectMessage = "汽水歌曲缺少 track_id，无法收藏"
            showCollectAlert = true
            return
        }
        Task {
            do {
                let ok = try await SodaAPIClient.shared.addToCollection(trackIDs: [trackID])
                await MainActor.run {
                    collectMessage = ok ? "已收藏到汽水「我喜欢的音乐」" : "收藏失败"
                    showCollectAlert = true
                    if ok { HapticManager.shared.notification(type: .success) }
                }
            } catch {
                await MainActor.run {
                    collectMessage = "收藏失败：\(error.localizedDescription)"
                    showCollectAlert = true
                }
            }
        }
    }

    @ViewBuilder
    private var trailingView: some View {
        if isEditing {
            EmptyView()
        } else {
            trailingActionView
        }
    }

    private var heartButton: some View {
        Button {
            if playlistStore.isLoved(song) {
                Task { try? await playlistStore.removeSongFromLove(song) }
            } else {
                Task { try? await playlistStore.addSongToLove(song) }
                HapticManager.shared.notification(type: .success)
            }
        } label: {
            Image(systemName: playlistStore.isLoved(song) ? "heart.fill" : "heart")
                .font(.system(size: 16))
                .foregroundColor(playlistStore.isLoved(song) ? .red : .secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var trailingActionView: some View {
        let key = song.id + "_320k"
        let downloading = downloader.activeTasks[key]
        if let progress = downloading {
            ZStack {
                Circle()
                    .stroke(Color(.systemGray4), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 8))
            }
            .frame(width: 30, height: 30)
        } else {
            HStack(spacing: 14) {
                if showHeart {
                    heartButton
                }
                if song.source == "soda" {
                    // 汽水歌：调 qishui-api 拿直链下载到本地
                    if downloader.isDownloaded(song) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                    } else {
                        Button {
                            downloader.download(song, quality: "320k")
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.secondary)
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.borderless)
                    }
                } else if downloader.isDownloaded(song) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                } else {
                    Button {
                        downloader.download(song, quality: "320k")
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    showMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func sourceName(_ s: String) -> String {
        switch s {
        case "kw": return "酷我"
        case "tx": return "腾讯"
        case "wy": return "网易"
        case "kg": return "酷狗"
        case "mg": return "咪咕"
        case "soda": return "汽水"
        default: return s
        }
    }

    private var qualityBadge: String {
        let qs = song.qualities.map { $0.type.lowercased() }
        if qs.contains("flac24bit") { return "Hi-Res" }
        if qs.contains("flac") { return "SQ" }
        if qs.contains("320k") { return "HQ" }
        if let first = song.qualities.first?.type, !first.isEmpty { return first }
        return ""
    }

    private var qualityBadgeColor: Color {
        switch qualityBadge {
        case "Hi-Res": return .purple
        case "SQ": return .blue
        case "HQ": return .orange
        default: return .gray
        }
    }

    private var isCached: Bool {
        MusicCacheManager.shared.isCached(id: song.id)
    }

    private var isDownloaded: Bool {
        downloader.isDownloaded(song)
    }
}

// Picker to choose quality before playing
struct QualityPickerView: View {
    let song: LXSong
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    private var options: [(type: String, size: String)] {
        if song.source == "soda" {
            return [
                ("128k", "汽水 128K"),
                ("320k", "汽水 320K"),
                ("flac", "汽水 无损"),
            ]
        }
        return song.qualities
    }

    var body: some View {
        NavigationView {
            List(options, id: \.type) { q in
                Button {
                    player.play(song: song, atQuality: q.type)
                    dismiss()
                } label: {
                    HStack {
                        Text(song.source == "soda" ? SodaAPIClient.qualityDisplayName(q.type) : q.type)
                            .font(.system(size: 15))
                        Spacer()
                        Text(q.size)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        if q.type == player.quality {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("选择音质")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
