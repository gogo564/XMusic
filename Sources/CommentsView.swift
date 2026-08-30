import SwiftUI
import UIKit

// 歌曲评论：soda 走 qishui-api /comment（LunaPC 签名链路），其余平台走 LX 后端聚合。
struct CommentsView: View {
    let song: LXSong?
    @Environment(\.dismiss) var dismiss
    @State private var comments: [MusicComment] = []
    @State private var total = 0
    @State private var maxPage = 1
    @State private var page = 1
    @State private var type = "hot" // hot / new（仅非 soda 平台使用）
    @State private var cursor = ""   // soda 游标分页
    @State private var hasMore = true
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var errorMessage = ""
    @State private var loadedOnce = false

    private var isSoda: Bool { song?.source == "soda" }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !isSoda {
                    typeSwitcher
                    Divider()
                }
                if loadedOnce && comments.isEmpty && !isLoading {
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
                        if canLoadMore {
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

    private var canLoadMore: Bool {
        isSoda ? hasMore : page < maxPage
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
            CommentAvatar(url: c.avatar)

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

    // 头像：复用首页同款 LXImageLoader(内存NSCache+磁盘URLCache+降采样+并发去重)，滚动复用 cell 不再反复请求解码，避免卡顿
    private struct CommentAvatar: View {
        let url: String?
        @State private var image: UIImage?
        var body: some View {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.25))
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.6))
                        )
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
            .task(id: url) {
                guard let url, !url.isEmpty else { image = nil; return }
                image = await LXImageLoader.shared.load(url, maxPixel: 132)
            }
        }
    }

    private func load() {
        guard let song = song, !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task {
            do {
                if isSoda {
                    let songmid = song.songmid ?? ""
                    let result = try await SodaAPIClient.shared.fetchComments(trackID: songmid)
                    await MainActor.run {
                        comments = result.comments
                        total = result.total
                        cursor = result.cursor
                        hasMore = result.hasMore
                        page = 1
                        maxPage = 1
                        isLoading = false
                    }
                } else {
                    let result = try await LXAPIClient.shared.getComments(for: song, type: type, page: 1, limit: 20)
                    await MainActor.run {
                        comments = result.comments
                        total = result.total
                        maxPage = result.maxPage
                        page = 1
                        isLoading = false
                    }
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
        guard let song = song, !isLoading, canLoadMore else { return }
        isLoading = true
        Task {
            do {
                if isSoda {
                    let songmid = song.songmid ?? ""
                    let result = try await SodaAPIClient.shared.fetchComments(trackID: songmid, cursor: cursor)
                    await MainActor.run {
                        comments += result.comments
                        cursor = result.cursor
                        hasMore = result.hasMore
                        total = result.total
                        isLoading = false
                    }
                } else {
                    let result = try await LXAPIClient.shared.getComments(for: song, type: type, page: page + 1, limit: 20)
                    await MainActor.run {
                        comments += result.comments
                        page += 1
                        maxPage = result.maxPage
                        isLoading = false
                    }
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
