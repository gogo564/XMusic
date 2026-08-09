import Foundation

// 汽水音乐 API 客户端：对接自部署的 qishui-api（Node 服务）。
// 提供推荐歌单、歌单详情（内嵌歌曲）、电台、搜索、播放 URL、歌词。
struct SodaAPIClient {
    static let shared = SodaAPIClient()

    private init() {}

    /// 汽水服务是否已配置（baseURL 非空）
    var isConfigured: Bool {
        !AppConfigStore.shared.config.sodaBaseURL.isEmpty
    }

    private var baseURL: String {
        var url = AppConfigStore.shared.config.sodaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }

    private func makeURL(_ path: String, query: [String: String] = [:]) -> URL? {
        var comps = URLComponents(string: baseURL + path)
        comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps?.url
    }

    private func getJSON(_ url: URL?) async throws -> Any {
        guard let url = url else { throw SodaError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SodaError.http(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any], (dict["code"] as? Int) == 0 else {
            throw SodaError.upstream
        }
        return dict["data"] ?? [:]
    }

    private func postJSON(_ url: URL?, body: [String: Any]) async throws -> Any {
        guard let url = url else { throw SodaError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SodaError.http(http.statusCode)
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any], (dict["code"] as? Int) == 0 else {
            throw SodaError.upstream
        }
        return dict["data"] ?? [:]
    }

    /// 原始 JSON（不要求 code == 0），用于登录状态检测/更新，需读取错误 message
    private func rawJSON(_ url: URL?, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = url else { throw SodaError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SodaError.http(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SodaError.upstream
        }
        return obj
    }

    // MARK: - 推荐歌单

    struct SodaPlaylist: Identifiable, Codable {
        let id: String
        let title: String
        let coverURL: String
        let trackCount: Int
    }

    func recommendPlaylists(count: Int = 20) async throws -> [SodaPlaylist] {
        let data = try await getJSON(makeURL("/recommend/playlist", query: ["count": String(count)]))
        guard let dict = data as? [String: Any],
              let list = dict["playlists"] as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return SodaPlaylist(
                id: id,
                title: p["title"] as? String ?? "",
                coverURL: p["cover_url"] as? String ?? "",
                trackCount: p["count_tracks"] as? Int ?? 0
            )
        }
    }

    /// 我的汽水歌单（qishui-api 注入登录态后返回账号歌单，如"我喜欢的音乐"）
    func myPlaylists() async throws -> [SodaPlaylist] {
        let data = try await postJSON(makeURL("/me/playlists"), body: [:])
        guard let dict = data as? [String: Any],
              let list = dict["playlists"] as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return SodaPlaylist(
                id: id,
                title: p["title"] as? String ?? "",
                coverURL: p["cover_url"] as? String ?? "",
                trackCount: p["count_tracks"] as? Int ?? 0
            )
        }
    }

    // MARK: - 汽水云收藏（歌单 / 专辑）

    struct SodaCollection: Identifiable {
        let id: String
        let type: String
        let title: String
        let subtitle: String
        let coverURL: String
        let trackCount: Int
    }

    func myCollections() async throws -> [SodaCollection] {
        let data = try await postJSON(makeURL("/me/collection/mixed"), body: [:])
        guard let dict = data as? [String: Any],
              let list = dict["mixed_collections"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let type = item["item_type"] as? String ?? ""
            if type == "playlist", let p = item["playlist"] as? [String: Any], let id = p["id"] as? String {
                let count = p["count_tracks"] as? Int ?? 0
                return SodaCollection(
                    id: id,
                    type: "playlist",
                    title: p["title"] as? String ?? "",
                    subtitle: "歌单 · \(count) 首",
                    coverURL: p["cover_url"] as? String ?? "",
                    trackCount: count
                )
            }
            if type == "album", let a = item["album"] as? [String: Any], let id = a["id"] as? String {
                let count = a["count_tracks"] as? Int ?? 0
                let artist = a["artist_name"] as? String ?? ""
                return SodaCollection(
                    id: id,
                    type: "album",
                    title: a["title"] as? String ?? "",
                    subtitle: artist.isEmpty ? "专辑" : artist,
                    coverURL: a["cover_url"] as? String ?? "",
                    trackCount: count
                )
            }
            return nil
        }
    }

    // MARK: - 场景模式

    struct SodaFeedMode: Identifiable {
        let id: String
        let text: String
        let type: String          // preference_mode / scene_mode
        let mode: String          // 偏好模式: default/familiar/fresh
        let sceneModeID: Int      // 场景模式: 48 等
        let subQueueType: String
        let coverURI: String
    }

    /// 获取汽水 feed 模式列表（推荐 + 场景模式），来自 /feed/mode
    func feedModes() async throws -> [SodaFeedMode] {
        let data = try await postJSON(makeURL("/feed/mode"), body: [:])
        guard let dict = data as? [String: Any] else { return [] }
        // 服务器 data 结构: { supported_without_app_context, upstream }
        let source = (dict["upstream"] as? [String: Any]) ?? dict
        var modes: [SodaFeedMode] = []

        // feed_mode_bar：顶部横条（推荐 + 常用场景）
        if let bar = source["feed_mode_bar"] as? [String: Any],
           let barModes = bar["feed_mode"] as? [[String: Any]] {
            for m in barModes {
                modes.append(parseFeedMode(m))
            }
        }
        // feed_mode_block：完整分组（场景音乐等）
        if let blocks = source["feed_mode_block"] as? [[String: Any]] {
            for block in blocks {
                if let blockModes = block["feed_mode"] as? [[String: Any]] {
                    for m in blockModes {
                        modes.append(parseFeedMode(m))
                    }
                }
            }
        }
        // 去重（bar 与 block 可能重复）
        var seen = Set<String>()
        var result: [SodaFeedMode] = []
        for m in modes {
            guard seen.insert(m.id).inserted else { continue }
            result.append(m)
        }
        return result
    }

    private func parseFeedMode(_ m: [String: Any]) -> SodaFeedMode {
        let text = m["text"] as? String ?? ""
        let type = m["type"] as? String ?? ""
        let entity = m["entity"] as? [String: Any] ?? [:]
        let pref = entity["feed_preference_mode"] as? [String: Any] ?? [:]
        let scene = entity["feed_scene_mode"] as? [String: Any] ?? [:]
        let mode = pref["mode"] as? String ?? ""
        let sceneID = scene["scene_mode_id"] as? Int ?? 0
        let subQueue = scene["sub_queue_type"] as? String ?? ""
        let coverURI = (m["url_info"] as? [String: Any])?["uri"] as? String ?? ""
        let id = type == "preference_mode" ? "pref_\(mode)" : "scene_\(sceneID)"
        return SodaFeedMode(id: id, text: text, type: type, mode: mode,
                            sceneModeID: sceneID, subQueueType: subQueue, coverURI: coverURI)
    }

    /// 按模式拉取每日推荐歌曲（/daily/mix，需汽水登录态）
    func dailyMixTracks(sceneModeID: Int?, mode: String?, count: Int = 10) async throws -> [SodaTrack] {
        var body: [String: Any] = ["count": count]
        if let sceneModeID { body["scene_mode_id"] = sceneModeID }
        if let mode { body["mode"] = mode }
        let data = try await postJSON(makeURL("/daily/mix"), body: body)
        guard let dict = data as? [String: Any] else { return [] }
        // 服务器 data 结构: { supported_without_app_context, upstream }
        let source = (dict["upstream"] as? [String: Any]) ?? dict
        if let items = source["items"] as? [[String: Any]] {
            return parseTracks(from: items)
        }
        return []
    }

    // MARK: - 歌曲

    /// 收藏歌曲到汽水账号「我喜欢的音乐」（写接口，用 QISHUI_PLAYLIST_COOKIE）
    func addToCollection(trackIDs: [String]) async throws -> Bool {
        let media = trackIDs.map { ["type": "track", "id": $0] as [String: Any] }
        // postJSON 已返回服务器 data 字段：{ collected, playlist, upstream }
        let data = try await postJSON(makeURL("/me/collection/add"), body: ["media": media, "scene": ""])
        guard let dict = data as? [String: Any] else {
            Log.write("❌ [Soda] addToCollection unexpected resp tracks=\(trackIDs.count)")
            return false
        }
        let collected = dict["collected"] as? [[String: Any]] ?? []
        Log.write("📤 [Soda] addToCollection ok tracks=\(trackIDs.count) collected=\(collected.count)")
        return !collected.isEmpty
    }

    struct SodaTrack: Identifiable {
        let id: String
        let name: String
        let artist: String
        let coverURL: String
        let duration: Int
        let albumName: String

        /// 转为 LXSong（source = "soda"），供播放/队列/最近播放复用
        func toLXSong() -> LXSong {
            LXSong([
                "source": "soda",
                "songmid": id,
                "name": name,
                "singer": artist,
                "img": coverURL,
                "albumName": albumName,
                "interval": String(duration / 1000),
            ])
        }
    }

    private func parseTracks(from resources: [[String: Any]]) -> [SodaTrack] {
        resources.compactMap { r in
            // 兼容三种结构：{track}, {entity:{track_wrapper:{track}}}, 直接 track
            var track = r["track"] as? [String: Any] ?? r
            if track["id"] == nil, let entity = r["entity"] as? [String: Any],
               let wrapper = entity["track_wrapper"] as? [String: Any],
               let t = wrapper["track"] as? [String: Any] {
                track = t
            }
            guard let id = track["id"] as? String else { return nil }
            let album = track["album"] as? [String: Any] ?? [:]
            let artists = track["artists"] as? [[String: Any]] ?? []
            let artistName = artists.compactMap { $0["name"] as? String }.joined(separator: " / ")
            return SodaTrack(
                id: id,
                name: track["name"] as? String ?? "",
                artist: artistName,
                coverURL: coverURLString(from: album),
                duration: track["duration"] as? Int ?? 0,
                albumName: album["name"] as? String ?? ""
            )
        }
    }

    /// 兼容两种封面字段：album["cover_url"] 字符串 或 album["url_cover"] 对象
    private func coverURLString(from album: [String: Any]) -> String {
        if let s = album["cover_url"] as? String, !s.isEmpty { return s }
        if let obj = album["url_cover"] as? [String: Any] {
            if let uri = obj["uri"] as? String, !uri.isEmpty {
                if let urls = obj["urls"] as? [String], let first = urls.first {
                    if !first.hasSuffix("/") && uri.contains("/") {
                        return first + uri
                    }
                    return first + uri
                }
                return "https://p3-luna.douyinpic.com/img/" + uri
            }
            if let urls = obj["urls"] as? [String], let first = urls.first { return first }
        }
        if let uri = album["url_cover"] as? String { return uri }
        return ""
    }

    /// 歌单详情：返回歌单内嵌歌曲（media_resources，无需登录）
    func playlistSongs(playlistID: String) async throws -> [SodaTrack] {
        let data = try await getJSON(makeURL("/playlist/detail", query: ["playlist_id": playlistID]))
        guard let dict = data as? [String: Any] else { return [] }
        if let resources = dict["media_resources"] as? [[String: Any]] {
            return parseTracks(from: resources)
        }
        return []
    }

    /// 电台歌曲（无需登录）
    func radioTracks(radioID: String, count: Int = 30) async throws -> [SodaTrack] {
        let data = try await getJSON(makeURL("/radio/tracks", query: ["radio_id": radioID, "count": String(count)]))
        guard let dict = data as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else { return [] }
        return parseTracks(from: items)
    }

    /// 电台列表
    struct SodaRadio: Identifiable {
        let id: String
        let title: String
    }

    func radioList() async throws -> [SodaRadio] {
        let data = try await getJSON(makeURL("/radio/list"))
        guard let dict = data as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            return SodaRadio(id: id, title: r["title"] as? String ?? "")
        }
    }

    // MARK: - 搜索

    func search(keyword: String, count: Int = 30) async throws -> [SodaTrack] {
        let data = try await getJSON(makeURL("/search", query: ["keyword": keyword, "count": String(count)]))
        guard let dict = data as? [String: Any] else { return [] }
        // /search 返回原始结构；依次尝试常见字段
        if let list = dict["tracks"] as? [[String: Any]] { return parseTracks(from: list) }
        if let list = dict["items"] as? [[String: Any]] { return parseTracks(from: list) }
        if let list = dict["songs"] as? [[String: Any]] { return parseTracks(from: list) }
        return []
    }

    func searchPlaylists(keyword: String, count: Int = 20) async throws -> [SodaPlaylist] {
        let data = try await getJSON(makeURL("/search", query: ["keyword": keyword, "count": String(count)]))
        guard let dict = data as? [String: Any],
              let list = dict["playlists"] as? [[String: Any]] else { return [] }
        return list.compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return SodaPlaylist(
                id: id,
                title: p["title"] as? String ?? "",
                coverURL: p["cover_url"] as? String ?? "",
                trackCount: p["count_tracks"] as? Int ?? 0
            )
        }
    }

    // MARK: - 登录状态

    struct SodaAuthStatus {
        let valid: Bool
        let nickname: String
        let message: String
    }

    /// 检测汽水登录态是否有效（qishui-api /auth/status）
    func authStatus() async throws -> SodaAuthStatus {
        let dict = try await rawJSON(makeURL("/auth/status"))
        if let data = dict["data"] as? [String: Any] {
            return SodaAuthStatus(
                valid: data["valid"] as? Bool ?? false,
                nickname: data["nickname"] as? String ?? "",
                message: data["message"] as? String ?? ""
            )
        }
        return SodaAuthStatus(valid: false, nickname: "", message: dict["message"] as? String ?? "检测失败")
    }

    /// 更新汽水登录签名（Cookie/X-Helios/X-Medusa），qishui-api 校验成功才持久化
    func updateAuth(cookie: String, helios: String, medusa: String) async throws -> SodaAuthStatus {
        let dict = try await rawJSON(makeURL("/auth/update"), method: "POST", body: [
            "cookie": cookie,
            "helios": helios,
            "medusa": medusa,
        ])
        if let data = dict["data"] as? [String: Any] {
            return SodaAuthStatus(
                valid: data["valid"] as? Bool ?? false,
                nickname: data["nickname"] as? String ?? "",
                message: data["message"] as? String ?? ""
            )
        }
        return SodaAuthStatus(valid: false, nickname: "", message: dict["message"] as? String ?? "更新失败")
    }

    // MARK: - 播放 URL 与歌词

    struct SodaPlayback {
        let url: String
        let name: String
        let artist: String
        let quality: String
    }

    /// 玩家音质（128k/320k/flac）→ qishui-api 档位
    private func mapQuality(_ q: String) -> String {
        switch q.lowercased() {
        case "flac", "flac24bit", "lossless": return "lossless"
        case "320k", "higher", "high": return "highest"
        default: return "medium"
        }
    }

    /// 汽水歌音质显示名
    static func qualityDisplayName(_ q: String) -> String {
        switch q.lowercased() {
        case "flac", "flac24bit", "lossless": return "无损"
        case "320k", "highest", "higher": return "320K"
        case "128k", "medium", "hi_res": return "128K"
        default: return q
        }
    }

    func playbackURL(trackID: String, quality: String) async throws -> SodaPlayback {
        let data = try await getJSON(makeURL("/song/detail", query: ["track_id": trackID]))
        guard let dict = data as? [String: Any] else {
            throw SodaError.upstream
        }
        let artist = dict["artists"] as? [[String: Any]] ?? []
        let mapped = mapQuality(quality)
        let playURL = baseURL + "/song/play?track_id=" + trackID + "&quality=" + mapped
        return SodaPlayback(
            url: playURL,
            name: dict["name"] as? String ?? "",
            artist: artist.compactMap { $0["name"] as? String }.joined(separator: " / "),
            quality: Self.qualityDisplayName(quality)
        )
    }

    /// 流式播放信息（客户端解密用）：返回 CDN 加密音频 URL + 解密密钥
    struct SodaStreamInfo {
        let trackID: String
        let mainURL: String
        let hexKey: String
        let spadeA: String
        let quality: String
        let durationMs: Int
    }

    func songStream(trackID: String, quality: String) async throws -> SodaStreamInfo {
        let data = try await getJSON(makeURL("/song/stream", query: ["track_id": trackID, "quality": mapQuality(quality)]))
        guard let dict = data as? [String: Any],
              let mainURL = dict["main_url"] as? String, !mainURL.isEmpty else {
            throw SodaError.upstream
        }
        return SodaStreamInfo(
            trackID: dict["track_id"] as? String ?? trackID,
            mainURL: mainURL,
            hexKey: dict["hex_key"] as? String ?? "",
            spadeA: dict["spade_a"] as? String ?? "",
            quality: dict["quality"] as? String ?? "",
            durationMs: dict["duration_ms"] as? Int ?? 0
        )
    }

    func lyric(trackID: String) async throws -> String {
        let data = try await getJSON(makeURL("/lyric", query: ["track_id": trackID]))
        if let dict = data as? [String: Any] {
            if let l = dict["lyric"] as? String { return l }
            if let l = dict["lyrics"] as? String { return l }
            if let l = dict["content"] as? String { return l }
        }
        return ""
    }
}

enum SodaError: LocalizedError {
    case invalidURL
    case http(Int)
    case upstream

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "汽水服务地址无效"
        case .http(let code): return "汽水服务错误 (\(code))"
        case .upstream: return "汽水服务返回异常"
        }
    }
}
