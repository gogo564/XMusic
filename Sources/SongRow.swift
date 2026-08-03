import SwiftUI

struct SongRow: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var downloader: DownloadService

    let song: LXSong
    let showSource: Bool
    var onPlay: ((LXSong) -> Void)?

    @State private var showMenu = false
    @State private var showPlaylistPicker = false
    @State private var showQualityPicker = false

    var body: some View {
        HStack(spacing: 12) {
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
            if let onPlay = onPlay { onPlay(song) } else { player.play(song: song) }
        }
        .confirmationDialog(song.name, isPresented: $showMenu, titleVisibility: .visible) {
            Button("立即播放") { player.play(song: song) }
            Button("选择音质播放") { showQualityPicker = true }
            Button("下一首播放") { player.playNext(with: song) }
            Button("添加到歌单") { showPlaylistPicker = true }
            if !downloader.isDownloaded(song) {
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
    }

    @ViewBuilder
    private var trailingView: some View {
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
        default: return s
        }
    }
}

// Picker to choose quality before playing
struct QualityPickerView: View {
    let song: LXSong
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(song.qualities, id: \.type) { q in
                Button {
                    player.play(song: song, atQuality: q.type)
                    dismiss()
                } label: {
                    HStack {
                        Text(q.type)
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
