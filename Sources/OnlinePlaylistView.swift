import SwiftUI

struct OnlinePlaylistRow: View {
    let playlist: LXOnlinePlaylist

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: playlist.imageURL)) { image in
                image.resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Image(systemName: "music.note.list")
                    .foregroundColor(.secondary)
            }
            .frame(width: 56, height: 56)
            .cornerRadius(8)
            .clipped()
            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if !playlist.playCount.isEmpty {
                        Text("播放 \(playlist.playCount)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if playlist.songCount > 0 {
                        Text("· \(playlist.songCount) 首")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                if !playlist.author.isEmpty {
                    Text("by \(playlist.author)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
