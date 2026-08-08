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
    // 滑动换歌（汽水式分页）：feedIndex 为当前页索引，由原生分页容器驱动
    @State private var displaySong: LXSong?
    @State private var feedQueue: [LXSong] = []
    @State private var feedIndex = 0
    @State private var feedActive = false
    @State private var feedLoaded = false
    @State private var showingFullLyrics = false
    @State private var showingComments = false
    // 三模式侧边栏（汽水式：右缘滑出 / 顶栏呼出）
    @State private var sidebarOffset: CGFloat = 0
    @State private var sidebarDragging = false
    @State private var showingSidebar = false

    private let qualityOptions = ["128k", "320k", "flac"]

    var body: some View {
        ZStack {
            swipeablePage
            topOverlay
            if showingFullLyrics {
                fullLyricsView
            }
            sidebarView
        }
        .preferredColorScheme(.dark)
        .gesture(sidebarPanGesture)  // 仅右缘右滑触发，与竖向分页兼容
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
        .onChange(of: feedIndex) { _ in
            // 原生分页吸附落定后切歌（汽水式：滑动到哪页播哪页）
            handlePageSettled()
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

    // MARK: - 汽水式竖向分页：原生 UIScrollView 分页容器（系统级惯性/吸附），
    // 每页完整播放页，只渲染当前页与上下邻页（cell 复用），iOS 15 安全

    private var swipeablePage: some View {
        // 注意：ignoresSafeArea 加在 GeometryReader 上，使 geo.size 等于全屏尺寸，
        // 再以该尺寸显式构建每页，hosting view 才与屏幕完全一致（否则内容被安全区压缩，
        // 表现为"横版显示不全 / 背景不铺满 / 底部控制区消失"）。
        GeometryReader { geo in
            PagingPlayerScrollView(
                currentIndex: feedIndex,
                pageCount: max(feedQueue.count, 1),
                pageBuilder: { index in
                    pageView(forIndex: index, width: geo.size.width, height: geo.size.height)
                },
                onIndexChange: { newIndex in
                    if newIndex != feedIndex {
                        feedIndex = newIndex
                    }
                }
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.black)
        }
        .ignoresSafeArea()
    }

    // 每页视图：当前页完整播放页，邻页为对齐布局的预览（对齐汽水 AudioPlayItemViewController）
    @ViewBuilder
    private func pageView(forIndex index: Int, width: CGFloat, height: CGFloat) -> some View {
        if feedQueue.indices.contains(index) {
            if index == feedIndex {
                songPage(song: feedQueue[index], width: width, height: height)
            } else {
                previewPage(song: feedQueue[index], width: width, height: height)
            }
        } else {
            songPage(song: displaySong, width: width, height: height)
        }
    }

    // 翻页落定（原生分页吸附完成）→ 切歌。由 feedIndex 的 onChange 触发
    private func handlePageSettled() {
        guard feedQueue.indices.contains(feedIndex) else { return }
        let song = feedQueue[feedIndex]
        guard playerManager.currentSong?.id != song.id else { return }
        displaySong = song
        playerManager.play(song: song, in: feedQueue, index: feedIndex, presentPlayer: false)
    }

    // 当前完整页：模糊沉浸背景铺满 + 封面（高度约束）+ 歌词 + 底部控制区（对齐汽水页面结构）。
    // 背景固定铺满，封面/歌词/控制区用弹性 Spacer 撑开，控制区始终贴底可见。
    private func songPage(song: LXSong?, width: CGFloat, height: CGFloat) -> some View {
        let coverSize = min(width - 60, height * 0.42)
        return ZStack {
            BlurredCoverBackground(url: coverURL(for: song))

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                coverCard(song: song, size: coverSize)

                Spacer(minLength: 22)

                currentLyricView

                Spacer(minLength: 14)

                trackInfoAndControls(song: song)

                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .background(Color.black)
        .clipped()
    }

    // 邻页预览：与当前页同一套整页布局（铺满背景 + 封面 + 歌名/歌手），跟随滚动带平移
    private func previewPage(song: LXSong?, width: CGFloat, height: CGFloat) -> some View {
        let coverSize = min(width - 60, height * 0.42)
        return ZStack {
            BlurredCoverBackground(url: coverURL(for: song))

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                coverCard(song: song, size: coverSize)

                Spacer(minLength: 22)

                VStack(alignment: .leading, spacing: 6) {
                    Text(song?.name ?? "未知歌曲")
                        .font(.title2.bold())
                        .lineLimit(1)
                    Text(song?.singer ?? "未知歌手")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: width, height: height)
        .background(Color.black)
        .clipped()
    }

    // MARK: - 全屏歌词（点击封面进入，抖音式覆盖层）：当前行高亮居中，可滚动，点击/下滑退出

    private var fullLyricsView: some View {
        ZStack {
            BlurredCoverBackground(url: coverURL(for: playerManager.currentSong))
                .ignoresSafeArea()

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

            // 全屏歌词顶栏（对齐汽水 LongLyricView backButton）
            VStack {
                HStack {
                    Button(action: {
                        HapticManager.shared.selection()
                        showingFullLyrics = false
                    }) {
                        Image(systemName: "chevron.down")
                            .font(.title2.bold())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
                Spacer()
            }
            .foregroundColor(.white)

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
        GeometryReader { geo in
            VStack {
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                            .font(.title2.bold())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }

                    Spacer()

                    modeButton

                    Spacer()

                    topMenu
                }
                .padding(.horizontal)
                .padding(.top, geo.safeAreaInsets.top + 8)
                Spacer()
            }
        }
        .foregroundColor(.white)
    }

    // MARK: - 三模式侧边栏（汽水式：点击顶栏呼出 / 屏幕右缘右滑呼出）

    private var sidebarView: some View {
        ZStack {
            if showingSidebar || sidebarDragging {
                Color.black.opacity(0.45 * sidebarDimmingProgress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        closeSidebar()
                    }
                    .animation(.easeInOut(duration: 0.22), value: sidebarOffset)
            }

            if showingSidebar || sidebarDragging {
                ModeSidebarView(
                    mode: engine.mode,
                    onSelect: { m in
                        selectFeedMode(m)
                        closeSidebar()
                    },
                    onRefresh: {
                        refreshSidebarFeed()
                    },
                    onBackToDefault: {
                        HapticManager.shared.selection()
                        engine.setMode(.recommend)
                        feedActive = true
                        Task {
                            await engine.loadCurrentMode()
                            await MainActor.run { rebuildFeedQueue() }
                        }
                        closeSidebar()
                    },
                    onClose: {
                        closeSidebar()
                    }
                )
                .offset(x: sidebarOffset)
                .transition(.move(edge: .trailing))
            }
        }
        .zIndex(20)
        .animation(.easeInOut(duration: 0.28), value: showingSidebar)
    }

    private var sidebarWidth: CGFloat { 300 }

    private var sidebarDimmingProgress: Double {
        let hidden = -sidebarWidth
        let shown: CGFloat = 0
        let p = (sidebarOffset - hidden) / (shown - hidden)
        return Double(min(max(p, 0), 1))
    }

    // 右缘右滑呼出侧边栏
    private var sidebarPanGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !showingFullLyrics else { return }
                let screenW = UIScreen.main.bounds.width
                let startX = value.startLocation.x
                let dx = value.translation.width
                if !showingSidebar && !sidebarDragging {
                    // 仅当从右缘开始且右滑时开始跟踪
                    if startX > screenW - 38 && dx > 0 {
                        sidebarDragging = true
                    }
                }
                if sidebarDragging {
                    sidebarOffset = max(dx - sidebarWidth, -sidebarWidth)
                }
            }
            .onEnded { value in
                guard !showingFullLyrics else { return }
                if sidebarDragging {
                    sidebarDragging = false
                    let velocity = value.predictedEndTranslation.width
                    if sidebarOffset > -sidebarWidth * 0.6 || velocity > 400 {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            sidebarOffset = 0
                            showingSidebar = true
                        }
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            sidebarOffset = -sidebarWidth
                            showingSidebar = false
                        }
                    }
                }
            }
    }

    private func closeSidebar() {
        HapticManager.shared.selection()
        withAnimation(.easeInOut(duration: 0.25)) {
            sidebarOffset = -sidebarWidth
            showingSidebar = false
        }
    }

    // 换一换：保持当前模式，重新加载推荐
    private func refreshSidebarFeed() {
        HapticManager.shared.selection()
        feedActive = true
        Task {
            await engine.loadCurrentMode()
            await MainActor.run { rebuildFeedQueue() }
        }
    }

    // 模式呼出（点击打开三模式侧边栏）
    private var modeButton: some View {
        Button(action: {
            HapticManager.shared.selection()
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarOffset = 0
                showingSidebar = true
            }
        }) {
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

    // MARK: - 歌词：封面下方上下 2 行居中（当前行 + 下一行），对齐汽水 ShortLyricView

    private var currentLyricView: some View {
        Group {
            if playerManager.parsedLyrics.isEmpty {
                Text(playerManager.lyrics.isEmpty ? "暂无歌词" : playerManager.lyrics)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                let lines = playerManager.parsedLyrics
                let idx = max(playerManager.currentLyricIndex, 0)
                let current = lines.indices.contains(idx) ? lines[idx].text : ""
                let next = lines.indices.contains(idx + 1) ? lines[idx + 1].text : ""
                VStack(spacing: 8) {
                    Text(current.isEmpty ? " " : current)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                    Text(next.isEmpty ? " " : next)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 74, alignment: .center)
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

// MARK: - 沉浸背景已由 BlurredCoverBackground.swift 实现（对齐 BNPlayBackgroundView）

#Preview {
    PlayerView()
        .environmentObject(PlayerManager.shared)
        .environmentObject(PlaylistStore.shared)
        .environmentObject(DownloadService.shared)
}
