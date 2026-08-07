import SwiftUI

// 歌曲评论（后端聚合各平台：QQ/网易/酷我/酷狗/咪咕）
struct CommentsView: View {
    let song: LXSong?
    @Environment(\.dismiss) var dismiss
    @State private var comments: [MusicComment] = []
    @State private var total = 0
    @State private var maxPage = 1
    @State private var page = 1
    @State private var type = "hot" // hot / new
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var errorMessage = ""
    @State private var loadedOnce = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                typeSwitcher
                Divider()
                if loadedOnce && comments.isEmpty {
                    Spacer()
                    Text("暂无评论")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                } else if loadFailed {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("评论加载失败")
                            .font(.subheadline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("重试") {
                            load()
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                } else {
                    List {
                        ForEach(comments.indices, id: \.self) { i in
                            commentRow(comments[i])
                        }
                        if page < maxPage {
                            HStack {
                                Spacer()
                                if isLoading {
                                    ProgressView()
                                } else {
                                    Button("加载更多") {
                                        loadMore()
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(song?.name ?? "评论")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(sourceLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                if !loadedOnce {
                    loadedOnce = true
                    load()
                }
            }
            .onChange(of: type) { _ in
                comments = []
                page = 1
                total = 0
                maxPage = 1
                loadFailed = false
                load()
            }
        }
    }

    private var sourceLabel: String {
        guard let s = song else { return "暂无来源" }
        return MusicSources.name(s.source) + " 评论"
    }

    private var typeSwitcher: some View {
        HStack {
            Button(action: {
                if type != "hot" { type = "hot" }
            }) {
                Text("最热")
                    .font(.headline)
                    .foregroundColor(type == "hot" ? .primary : .secondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            Button(action: {
                if type != "new" { type = "new" }
            }) {
                Text("最新")
                    .font(.headline)
                    .foregroundColor(type == "new" ? .primary : .secondary)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
        }
    }

    private func commentRow(_ c: MusicComment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let avatar = c.avatar, let url = URL(string: avatar) {
                AsyncImage(url: url) { image in
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    avatarPlaceholder
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                avatarPlaceholder
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(c.user.isEmpty ? "匿名用户" : c.user)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if c.likedCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "hand.thumbsup")
                                .font(.caption2)
                            Text("\(c.likedCount)")
                                .font(.caption2)
                                .monospacedDigit()
                        }
                        .foregroundColor(.secondary)
                    }
                }
                Text(c.content)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !c.time.isEmpty {
                    Text(c.time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowSeparator(.visible)
    }

    private var avatarPlaceholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.25))
            .frame(width: 40, height: 40)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            )
    }

    private func load() {
        guard let song = song, !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task {
            do {
                let result = try await LXAPIClient.shared.getComments(for: song, type: type, page: 1, limit: 20)
                await MainActor.run {
                    comments = result.comments
                    total = result.total
                    maxPage = result.maxPage
                    page = 1
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadMore() {
        guard let song = song, !isLoading, page < maxPage else { return }
        isLoading = true
        Task {
            do {
                let result = try await LXAPIClient.shared.getComments(for: song, type: type, page: page + 1, limit: 20)
                await MainActor.run {
                    comments += result.comments
                    page += 1
                    maxPage = result.maxPage
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    loadFailed = true
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
