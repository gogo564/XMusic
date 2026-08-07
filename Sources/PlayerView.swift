import SwiftUI
import UIKit

struct PlayerView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var playlistStore: PlaylistStore
    @EnvironmentObject var downloader: DownloadService
    @Environment(\.dismiss) var dismiss
    @ObservedObject var recentStore = RecentStore.shared
    @ObservedObject var engine = RecommendationEngine.shared
    @State private var localTime: Double = 0
    @State private var isDraggingSlider = false
    @State private var showingRecentList = false
    @State private var showPlaylistPicker = false
    // 滑动换歌：displaySong 为"页面当前展示的歌曲"，起播成功前页面先切，音频起播后再同步
    @State private var displaySong: LXSong?
    // 拖动跟手用 @GestureState（不触发整个 songPage 重算），复位无动画（由 pageOffset 接管回弹/翻页）
    @GestureState private var dragOffset: CGFloat = 0
    @State private var pageOffset: CGFloat = 0
    @State private var dragTarget: LXSong?
    @State private var dragTargetDirection: CGFloat = 1 // +1=下一页在下方，-1=上一页在上方
    @State private var feedQueue: [LXSong] = []
    @State private var feedIndex = 0
    @State private var isSwitching = false
    @State private var feedActive = false
    @State private var feedLoaded = false
    @State private var showingFullLyrics = false
    @State private var showingComments = false

    private let qualityOptions = ["128k", "320k", "flac"]

    var body: some View {
        ZStack {
            swipeablePage
            topOverlay
            if showingFullLyrics {
                fullLyricsView
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingRecentList) {
            RecentPlaylistView()
                .environmentObject(playerManager)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let song = playerManager.currentSong {
                PlaylistPickerView(song: song)
                    .environmentObject(playlistStore)
            }
        }
        .sheet(isPresented: $showingComments) {
            CommentsView(song: playerManager.currentSong)
                .environmentObject(playerManager)
        }
        .onChange(of: playerManager.currentSong?.id) { _ in
            displaySong = playerManager.currentSong
            // 若当前歌不在推荐里（手动从歌单/搜索/榜单点的歌），自动退出推荐流回到歌单滑动
            if feedActive, let cur = playerManager.currentSong,
               !engine.recommendations.contains(where: { $0.id == cur.id }) {
                feedActive = false
            }
            rebuildFeedQueue()
        }
        .onAppear {
            playerManager.setPlaylistFromRecent(recentStore.items)
            displaySong = playerManager.currentSong
            if !feedLoaded {
                feedLoaded = true
                Task { await loadFeedQueue() }
            }
        }
    }

    private func coverURL(for song: LXSong?) -> URL? {
        guard let song = song, !song.imageURL.isEmpty else { return nil }
        return URL(string: song.imageURL)
    }

    // MARK: - 整页跟手竖滑（汽水式）：两页叠放 + offset 跟手，不使用 .id/.transition（规避 iOS15 崩溃）

    private var swipeablePage: some View {
        GeometryReader { geo in
            let pageHeight = geo.size.height
            // 拖动中跟手用 dragOffset；翻页动画中由 pageOffset 接管
            let currentOffset = isSwitching ? pageOffset : dragOffset
            ZStack {
                // 当前页（完整内容）
                songPage(song: displaySong, width: geo.size.width)
                    .offset(y: currentOffset)

                // 目标预览页（仅封面+背景），跟随拖动滑入
                if let target = dragTarget {
                    coverPreview(song: target, width: geo.size.width)
                        .offset(y: dragTargetDirection * pageHeight + currentOffset)
                }
            }
            .background(Color.black)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .updating($dragOffset) { value, state, _ in
                        // 拖动跟手（@GestureState 更新不触发整页重算）
                        state = value.translation.height
                    }
                    .onChanged { value in
                        guard !isSwitching else { return }
                        // 只在拖动方向首次确定时设置预览目标，拖动中不重复更新（避免 body 重算）
                        let newDirection: CGFloat = value.translation.height > 0 ? -1 : 1
                        if newDirection != dragTargetDirection || dragTarget == nil {
                            dragTargetDirection = newDirection
                            updateDragTarget()
                        }
                    }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.height
                        let moved = value.translation.height
                        // 快速滑动（预测位移远超实际）或位移足够 → 翻页
                        if predicted < -40 || moved < -80 {
                            if feedIndex < feedQueue.count - 1 {
                                commitSwipe(.next, pageHeight: pageHeight, fromOffset: value.translation.height)
                            } else {
                                bounceBack(fromOffset: value.translation.height)
                            }
                        } else if predicted > 40 || moved > 80 {
                            if feedIndex > 0 {
                                commitSwipe(.prev, pageHeight: pageHeight, fromOffset: value.translation.height)
                            } else {
                                bounceBack(fromOffset: value.translation.height)
                            }
                        } else {
                            bounceBack(fromOffset: value.translation.height)
                        }
                    }
            )
        }
    }

    private enum SwipeDirection {
        case next, prev
    }

    private func updateDragTarget() {
        if dragTargetDirection < 0 {
            if feedIndex < feedQueue.count - 1 {
                dragTarget = feedQueue[feedIndex + 1]
            } else {
                dragTarget = nil
            }
        } else {
            if feedIndex > 0 {
                dragTarget = feedQueue[feedIndex - 1]
            } else {
                dragTarget = nil
            }
        }
    }

    private func bounceBack(fromOffset: CGFloat = 0) {
        // 把跟手位置快照交给 pageOffset 做回弹动画，避免 @GestureState 瞬时归零跳变
        if isSwitching { return }
        isSwitching = true
        withAnimation(.none) {
            pageOffset = fromOffset
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            pageOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            isSwitching = false
            dragTarget = nil
            pageOffset = 0
        }
    }

    private func commitSwipe(_ direction: SwipeDirection, pageHeight: CGFloat, fromOffset: CGFloat) {
        guard !feedQueue.isEmpty else {
            bounceBack(fromOffset: fromOffset)
            return
        }
        guard !isSwitching else { return }
        isSwitching = true
        let targetIndex: Int
        switch direction {
        case .next: targetIndex = min(feedIndex + 1, feedQueue.count - 1)
        case .prev: targetIndex = max(feedIndex - 1, 0)
        }
        let song = feedQueue[targetIndex]
        guard playerManager.currentSong?.id != song.id else {
            isSwitching = false
            bounceBack(fromOffset: fromOffset)
            return
        }
        // 抖音式翻页：从当前跟手位置平滑滑出（目标页滑入到位），动画结束后才真正切歌
        let targetOffset = direction == .next ? -pageHeight : pageHeight
        pageOffset = fromOffset
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pageOffset = targetOffset
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            isSwitching = false
            feedIndex = targetIndex
            displaySong = song
            dragTarget = nil
            pageOffset = 0
            playerManager.play(song: song, in: feedQueue, index: targetIndex, presentPlayer: false)
        }
    }

    // 当前完整页：封面主色沉浸背景 + 大封面卡 + 一行歌词 + 底部控制区
    private func songPage(song: LXSong?, width: CGFloat) -> some View {
        let coverSize = width - 60
        return ZStack {
            DominantColorBackground(url: coverURL(for: song))

            LinearGradient(
                colors: [Color.black.opacity(0.5), .clear, .clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer(minLength: 100)

                coverCard(song: song, size: coverSize)

                Spacer(minLength: 40)

                currentLyricView

                Spacer(minLength: 0)

                trackInfoAndControls(song: song)

                Spacer(minLength: 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // 目标预览页：仅封面+背景，滑动过程中显示
    private func coverPreview(song: LXSong?, width: CGFloat) -> some View {
        let coverSize = width - 60
        return ZStack {
            DominantColorBackground(url: coverURL(for: song))

            LinearGradient(
                colors: [Color.black.opacity(0.5), .clear, .clear, Color.black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )

            coverCard(song: song, size: coverSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 全屏歌词（点击封面进入，抖音式覆盖层）：当前行高亮居中，可滚动，点击/下滑退出

    private var fullLyricsView: some View {
        ZStack {
            DominantColorBackground(url: coverURL(for: playerManager.currentSong))
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.6), .clear, .clear, Color.black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )

            if playerManager.parsedLyrics.isEmpty {
                VStack(spacing: 10) {
                    Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                    Text("点击任意处返回")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(32)
            } else {
                lyricsScroller
            }

            // 返回提示
            VStack {
                Spacer()
                Text("下滑返回")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            HapticManager.shared.selection()
            showingFullLyrics = false
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    // 下滑退出全屏歌词
                    if value.translation.height > 60 {
                        HapticManager.shared.selection()
                        showingFullLyrics = false
                    }
                }
        )
        .transition(.opacity)
        .zIndex(10)
    }

    // 歌词滚动视图：当前行高亮居中，随时间自动滚动到当前行
    private var lyricsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    Spacer(minLength: 140)
                    ForEach(Array(playerManager.parsedLyrics.enumerated()), id: \.element.id) { index, line in
                        let isCurrent = index == playerManager.currentLyricIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: isCurrent ? 21 : 15, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(isCurrent ? .white : .white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(index)
                    }
                    Spacer(minLength: 140)
                }
                .padding(.horizontal, 28)
            }
            .onChange(of: playerManager.currentLyricIndex) { _ in
                guard playerManager.currentLyricIndex >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(playerManager.currentLyricIndex, anchor: .center)
                }
            }
        }
    }

    // MARK: - 悬浮顶部 ActionBar（不随页滑动）

    private var topOverlay: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.down")
                        .font(.title2.bold())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }

                Spacer()

                modeMenu

                Spacer()

                topMenu
            }
            .padding(.horizontal)
            .padding(.top, 8)
            Spacer()
        }
        .foregroundColor(.white)
    }

    // 模式选择（三模式切换）+ 播放来源信息
    private var modeMenu: some View {
        Menu {
            ForEach(RecommendMode.allCases) { m in
                Button {
                    selectFeedMode(m)
                } label: {
                    if engine.mode == m {
                        Label(m.rawValue, systemImage: "checkmark")
                    } else {
                        Label(m.rawValue, systemImage: m.icon)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                exitFeedMode()
            } label: {
                Label("退出推荐流", systemImage: "xmark")
            }
        } label: {
            VStack(spacing: 2) {
                Text("模式选择")
                    .font(.headline)
                Text(engine.mode.rawValue)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(width: 150)
            .contentShape(Rectangle())
        }
    }

    // 来源 · 音质 · 下载/缓存 信息（显示在封面下方歌名上方）
    private var playbackInfoLine: String {
        var parts: [String] = []
        if !playerManager.sourceName.isEmpty {
            parts.append(MusicSources.name(playerManager.sourceName))
        }
        if !playerManager.qualityName.isEmpty {
            parts.append(MusicSources.qualityName(playerManager.qualityName))
        }
        if !playerManager.playbackOrigin.isEmpty {
            parts.append(playerManager.playbackOrigin)
        }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }

    private var topMenu: some View {
        Menu {
            Button {
                showPlaylistPicker = true
            } label: {
                Label("添加到歌单", systemImage: "text.badge.plus")
            }
            .disabled(playerManager.currentSong == nil)

            Picker("音质", selection: qualityBinding) {
                ForEach(qualityOptions, id: \.self) { q in
                    Text(q).tag(q)
                }
            }

            Menu("定时关闭") {
                Button("关闭定时") { playerManager.setSleepTimer(minutes: nil) }
                Button("5 分钟") { playerManager.setSleepTimer(minutes: 5) }
                Button("10 分钟") { playerManager.setSleepTimer(minutes: 10) }
                Button("30 分钟") { playerManager.setSleepTimer(minutes: 30) }
                Button("1 小时") { playerManager.setSleepTimer(minutes: 60) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { playerManager.quality },
            set: { playerManager.setQuality($0) }
        )
    }

    // MARK: - 歌词：封面下方上下 2 行左对齐（当前行 + 下一行），不截断完整显示

    private var currentLyricView: some View {
        Group {
            if playerManager.parsedLyrics.isEmpty {
                Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let lines = playerManager.parsedLyrics
                let idx = max(playerManager.currentLyricIndex, 0)
                let current = lines.indices.contains(idx) ? lines[idx].text : ""
                let next = lines.indices.contains(idx + 1) ? lines[idx + 1].text : ""
                VStack(alignment: .leading, spacing: 8) {
                    Text(current.isEmpty ? " " : current)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(next.isEmpty ? " " : next)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 74, alignment: .top)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Cover Card (square, rounded, 屏宽-60) 点击进入全屏歌词

    private func coverCard(song: LXSong?, size: CGFloat) -> some View {
        LXCachedImage(urlString: coverURL(for: song)?.absoluteString ?? "", size: size, cornerRadius: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 22, x: 0, y: 10)
            .onTapGesture {
                HapticManager.shared.selection()
                showingFullLyrics = true
            }
    }

    // MARK: - Track Info & Controls

    private func trackInfoAndControls(song: LXSong?) -> some View {
        VStack(spacing: 22) {
            // 歌名 / 歌手（左对齐）+ 下载 + 收藏
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(song?.name ?? "未知歌曲")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(song?.singer ?? "未知歌手")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                    if !playbackInfoLine.isEmpty {
                        Text(playbackInfoLine)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer()

                downloadButton
                commentButton
                loveButton
            }
            .padding(.horizontal, 24)

            if playerManager.isResolving {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在解析播放地址...")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }

            progressSection

            controlsSection
        }
    }

    private var loveButton: some View {
        Button(action: {
            if let song = playerManager.currentSong { toggleLove(song) }
        }) {
            let isLoved = playerManager.currentSong.map { playlistStore.isLoved($0) } ?? false
            Image(systemName: isLoved ? "heart.fill" : "heart")
                .font(.title3)
                .foregroundColor(isLoved ? .red : .white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var commentButton: some View {
        Button(action: {
            guard playerManager.currentSong != nil else { return }
            HapticManager.shared.selection()
            showingComments = true
        }) {
            Image(systemName: "bubble.right")
                .font(.title3)
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var downloadButton: some View {
        Button(action: {
            guard let song = playerManager.currentSong, !downloader.isDownloaded(song) else { return }
            downloader.download(song, quality: playerManager.quality)
            HapticManager.shared.selection()
        }) {
            if let song = playerManager.currentSong {
                if let progress = downloader.activeTasks[song.id + "_" + playerManager.quality] {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(Color.white, lineWidth: 2)
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                    .padding(12)
                } else if downloader.isDownloaded(song) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Custom Progress Section

    private var progressSection: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    let total = max(playerManager.duration, 1)
                    let bufferedRatio = CGFloat(min(playerManager.bufferedTime / total, 1))
                    let progressRatio = CGFloat(isDraggingSlider ? localTime / total : playerManager.currentTime / total)

                    ZStack(alignment: .leading) {
                        // 轨道
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 3)

                        // 缓冲
                        Capsule()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: geo.size.width * bufferedRatio, height: 3)

                        // 进度
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * max(progressRatio, 0), height: 3)

                        // 圆形滑块
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: Color.black.opacity(0.4), radius: 3, y: 1)
                            .offset(x: geo.size.width * max(progressRatio, 0) - 6)
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                isDraggingSlider = true
                                let ratio = min(max(value.location.x / geo.size.width, 0), 1)
                                localTime = Double(ratio) * total
                            }
                            .onEnded { _ in
                                playerManager.seek(to: localTime)
                                isDraggingSlider = false
                            }
                    )
                }
                .frame(height: 24)
            }

            HStack {
                Text(formatTime(isDraggingSlider ? localTime : playerManager.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(formatTime(playerManager.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 28)
        .onChange(of: playerManager.currentTime) { newValue in
            if !isDraggingSlider {
                localTime = newValue
            }
        }
    }

    // MARK: - Controls Section

    private var controlsSection: some View {
        HStack(spacing: 48) {
            Button(action: {
                playerManager.togglePlayMode()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.playModeIcon)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }

            Button(action: {
                playerManager.togglePlayPause()
                HapticManager.shared.selection()
            }) {
                Image(systemName: playerManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
            }

            Button(action: {
                showingRecentList = true
                HapticManager.shared.selection()
            }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Actions

    private func loadFeedQueue() async {
        if playlistStore.listData == nil {
            await playlistStore.refresh()
        }
        let loved = playlistStore.listData?.loveSongs ?? []
        await engine.load(recent: RecentStore.shared.items, loved: loved)
        await MainActor.run { rebuildFeedQueue() }
    }

    // 滑动队列：推荐流模式用推荐列表，否则用真实播放队列（歌单内切歌）
    private func rebuildFeedQueue() {
        if feedActive {
            var q = engine.recommendations
            if let cur = playerManager.currentSong, !q.contains(where: { $0.id == cur.id }) {
                q.insert(cur, at: 0)
            }
            feedQueue = q
            feedIndex = q.firstIndex(where: { $0.id == playerManager.currentSong?.id }) ?? 0
        } else {
            feedQueue = playerManager.queue
            feedIndex = max(playerManager.currentIndex, 0)
        }
    }

    private func selectFeedMode(_ m: RecommendMode) {
        guard engine.mode != m else { return }
        HapticManager.shared.selection()
        engine.setMode(m)
        feedActive = true
        Task {
            await engine.loadCurrentMode()
            await MainActor.run { rebuildFeedQueue() }
        }
    }

    // 退出推荐流：滑动队列回到真实播放队列（上下滑切歌在歌单内进行）
    private func exitFeedMode() {
        HapticManager.shared.selection()
        feedActive = false
        rebuildFeedQueue()
    }

    private func toggleLove(_ song: LXSong) {
        if playlistStore.isLoved(song) {
            Task {
                try? await playlistStore.removeSongFromLove(song)
            }
        } else {
            Task {
                try? await playlistStore.addSongToLove(song)
            }
            HapticManager.shared.notification(type: .success)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - 沉浸背景：从封面提取主色，随歌变色

private struct DominantColorBackground: View {
    let url: URL?
    @State private var color: Color = .black

    var body: some View {
        color
            .onAppear { load() }
            .onChange(of: url) { _ in load() }
    }

    private static var cache = NSCache<NSString, UIColor>()

    private func load() {
        guard let url = url else {
            color = .black
            return
        }
        let key = url.absoluteString as NSString
        if let cached = Self.cache.object(forKey: key) {
            color = Color(uiColor: cached)
            return
        }
        Task {
            let c = await Self.dominantColor(from: url)
            await MainActor.run {
                if let c = c {
                    color = Color(uiColor: c)
                } else {
                    color = .black
                }
            }
        }
    }

    private static func dominantColor(from url: URL) async -> Color? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
            let c = averageColor(of: cgImage)
            cache.setObject(c, forKey: url.absoluteString as NSString)
            return Color(uiColor: c)
        } catch {
            return nil
        }
    }

    private static func averageColor(of image: CGImage) -> UIColor {
        let width = 1
        let height = 1
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 4 * width,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .black }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return .black }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let r = CGFloat(bytes[0]) / 255
        let g = CGFloat(bytes[1]) / 255
        let b = CGFloat(bytes[2]) / 255
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}

#Preview {
    PlayerView()
        .environmentObject(PlayerManager.shared)
        .environmentObject(PlaylistStore.shared)
        .environmentObject(DownloadService.shared)
}
