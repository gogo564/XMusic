import Foundation
import Combine

// 汽水音乐式三种推荐模式
enum RecommendMode: String, CaseIterable, Identifiable {
    case recommend = "推荐模式"
    case fresh = "新鲜模式"
    case familiar = "熟悉模式"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .recommend: return "sparkles"
        case .fresh: return "leaf"
        case .familiar: return "heart"
        }
    }
}

// 从 最近播放 + 我喜欢的音乐 提炼的口味画像
struct TasteProfile {
    var topSources: [String: Double] = [:]   // 来源 -> 归一化权重
    var topSingers: [String: Double] = [:]   // 歌手 -> 权重
    var heardIDs: Set<String> = []           // 听过的（推荐/新鲜模式排除）
    var lovedIDs: Set<String> = []           // 收藏的

    var isEmpty: Bool { topSources.isEmpty && topSingers.isEmpty }
}

final class RecommendationEngine: ObservableObject {
    static let shared = RecommendationEngine()

    @Published private(set) var recommendations: [LXSong] = []
    @Published private(set) var isLoading = false
    @Published private(set) var mode: RecommendMode = .recommend
    @Published var errorMessage: String?

    private var profile = TasteProfile()

    private init() {}

    // MARK: - Public

    func setMode(_ m: RecommendMode) {
        mode = m
    }

    /// 基于最新数据（最近播放 + 收藏）构建画像并加载当前模式的推荐
    func load(recent: [RecentTrack], loved: [LXSong]) async {
        profile = buildProfile(recent: recent, loved: loved)
        await loadCurrentMode()
    }

    func loadCurrentMode() async {
        await MainActor.run { isLoading = true; errorMessage = nil }
        let songs: [LXSong]
        switch mode {
        case .recommend:
            songs = await loadRecommend()
        case .fresh:
            songs = await loadFresh()
        case .familiar:
            songs = await loadFamiliar()
        }
        await MainActor.run {
            recommendations = songs
            isLoading = false
        }
    }

    // MARK: - Profile

    private func buildProfile(recent: [RecentTrack], loved: [LXSong]) -> TasteProfile {
        var sources: [String: Double] = [:]
        var singers: [String: Double] = [:]
        var heard: Set<String> = []
        var lovedIDs: Set<String> = []

        // 最近播放：越新权重越高（线性衰减）
        for (i, track) in recent.enumerated() {
            heard.insert(track.id)
            let w = Double(recent.count - i) / Double(max(recent.count, 1))
            addSourceWeight(&sources, key: track.source, weight: w)
            addSingerWeights(&singers, from: track.singer, weight: w)
        }
        // 收藏：权重最高
        for song in loved {
            heard.insert(song.id)
            lovedIDs.insert(song.id)
            addSourceWeight(&sources, key: song.source, weight: 1.0)
            addSingerWeights(&singers, from: song.singer, weight: 1.0)
        }

        // 归一化到 0...1
        normalize(&sources)
        normalize(&singers)

        return TasteProfile(topSources: sources, topSingers: singers, heardIDs: heard, lovedIDs: lovedIDs)
    }

    private func addSourceWeight(_ dict: inout [String: Double], key: String, weight: Double) {
        guard !key.isEmpty else { return }
        dict[key, default: 0] += weight
    }

    private func addSingerWeights(_ dict: inout [String: Double], from singer: String, weight: Double) {
        for s in splitSingers(singer) {
            dict[s, default: 0] += weight
        }
    }

    private func normalize(_ dict: inout [String: Double]) {
        guard let max = dict.values.max(), max > 0 else { return }
        for k in dict.keys { dict[k] = dict[k]! / max }
    }

    private func splitSingers(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: "、&/，,;；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 候选池

    /// 拉取若干来源排行榜（可选按榜名关键字过滤，如"新歌"），并行请求。
    private func fetchLeaderboardPool(sources: [String], keyword: String?) async -> [LXSong] {
        var pool: [LXSong] = []
        await withTaskGroup(of: [LXSong].self) { group in
            for source in sources {
                group.addTask {
                    guard let boards = try? await LXAPIClient.shared.getLeaderBoards(source: source) else { return [] }
                    let picked = self.pickBoards(boards, keyword: keyword)
                    var songs: [LXSong] = []
                    for board in picked {
                        if let s = try? await LXAPIClient.shared.getLeaderBoardSongs(source: source, bangid: board.bangid) {
                            songs += s
                        }
                    }
                    return songs
                }
            }
            for await chunk in group {
                pool += chunk
            }
        }
        return pool
    }

    /// 用 Top 歌手的名字去搜索，补"因为喜欢 XX"的候选。
    private func fetchSingerSearchPool(sources: [String], count: Int) async -> [LXSong] {
        let topSingers = profile.topSingers.sorted { $0.value > $1.value }.prefix(count)
        guard !topSingers.isEmpty else { return [] }
        var pool: [LXSong] = []
        for (singer, _) in topSingers {
            for source in sources.prefix(1) {
                if let songs = try? await LXAPIClient.shared.search(name: singer, source: source, page: 1, pages: 1) {
                    pool += songs
                }
            }
        }
        return pool
    }

    private func pickBoards(_ boards: [[String: Any]], keyword: String?) -> [(bangid: String, name: String)] {
        let list = boards.compactMap { b -> (bangid: String, name: String)? in
            guard let bangid = b["bangid"] as? String, let name = b["name"] as? String else { return nil }
            return (bangid, name)
        }
        if let kw = keyword {
            let matched = list.filter { $0.name.contains(kw) }
            if !matched.isEmpty { return Array(matched.prefix(2)) }
        }
        return Array(list.prefix(2))
    }

    // MARK: - 各模式

    private func loadRecommend() async -> [LXSong] {
        let sources = preferredSources(limit: 3)
        async let leaderPool = fetchLeaderboardPool(sources: sources, keyword: nil)
        async let singerPool = fetchSingerSearchPool(sources: sources, count: 3)
        let pool = (await leaderPool) + (await singerPool)
        return rank(pool) {
            self.scoreRecommend($0)
        }
    }

    private func loadFresh() async -> [LXSong] {
        // 新鲜：用 新歌/飙升 榜，偏向用户少用的平台
        let sources = preferredSources(limit: 5)
        let pool = await fetchLeaderboardPool(sources: sources, keyword: "新歌") +
                   await fetchLeaderboardPool(sources: sources, keyword: "飙升")
        return rank(pool) {
            self.scoreFresh($0)
        }
    }

    private func loadFamiliar() async -> [LXSong] {
        var songs: [LXSong] = []
        var seen = Set<String>()

        // 主料：最近播放（新的在前），只保留 QQ/网易
        let recentStore = RecentStore.shared
        for track in recentStore.items {
            guard Self.allowedSources.contains(track.source),
                  let song = track.song, seen.insert(song.id).inserted else { continue }
            songs.append(song)
        }
        // 主料：我喜欢的音乐（只保留 QQ/网易）
        let loved = PlaylistStore.shared.listData?.loveSongs ?? []
        for song in loved where Self.allowedSources.contains(song.source) && seen.insert(song.id).inserted {
            songs.append(song)
        }
        // 补齐：Top 歌手热歌（不重复）
        if songs.count < 60 {
            let sources = preferredSources(limit: 1)
            let pool = await fetchSingerSearchPool(sources: sources, count: 4)
            for song in pool where seen.insert(song.id).inserted {
                songs.append(song)
            }
        }
        return Array(songs.prefix(80))
    }

    // MARK: - 打分

    private func scoreRecommend(_ song: LXSong) -> Double {
        guard !profile.heardIDs.contains(song.id) else { return -1 }
        let s = sourceAffinity(song.source)
        let g = singerAffinity(song.singer)
        return (s * 0.4 + g * 0.6) * Double.random(in: 0.9...1.1)
    }

    private func scoreFresh(_ song: LXSong) -> Double {
        guard !profile.heardIDs.contains(song.id) else { return -1 }
        // 少用的平台（novelty 高）更优先，实现"换口味"
        let usage = profile.topSources[song.source] ?? 0
        let novelty = 1.0 - min(usage, 1.0) * 0.6
        let g = singerAffinity(song.singer)
        return (novelty * 0.7 + g * 0.3) * Double.random(in: 0.9...1.1)
    }

    private func sourceAffinity(_ source: String) -> Double {
        if let w = profile.topSources[source] { return w }
        return profile.topSources.isEmpty ? 0.5 : 0.15
    }

    private func singerAffinity(_ singer: String) -> Double {
        guard !profile.topSingers.isEmpty else { return 0.5 }
        let total = splitSingers(singer).reduce(0.0) { $0 + (profile.topSingers[$1] ?? 0) }
        return min(total, 1.0)
    }

    private func rank(_ pool: [LXSong], scorer: (LXSong) -> Double) -> [LXSong] {
        var seen = Set<String>()
        let scored: [(song: LXSong, score: Double)] = pool.compactMap { song in
            guard seen.insert(song.id).inserted else { return nil }
            let s = scorer(song)
            return s > 0 ? (song, s) : nil
        }
        return scored
            .sorted { $0.score > $1.score }
            .prefix(60)
            .map { $0.song }
    }

    private static let allowedSources = ["tx", "wy"] // 推荐只用 QQ + 网易（QQ 有会员，优先）

    // MARK: - 工具

    private func preferredSources(limit: Int) -> [String] {
        let ranked = profile.topSources.sorted { $0.value > $1.value }.map { $0.key }.filter { Self.allowedSources.contains($0) }
        let base = ranked.isEmpty ? Self.allowedSources : ranked
        var result: [String] = []
        for s in base where result.count < limit {
            result.append(s)
        }
        // 兜底补齐：QQ 优先
        for s in Self.allowedSources where result.count < limit {
            if !result.contains(s) { result.append(s) }
        }
        return result
    }
}
