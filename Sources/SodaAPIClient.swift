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

    // MARK: - 推荐歌单

    struct SodaPlaylist: Identifiable {
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

    // MARK: - 歌曲

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
            let track = r["track"] as? [String: Any] ?? r
            guard let id = track["id"] as? String else { return nil }
            let album = track["album"] as? [String: Any] ?? [:]
            let artists = track["artists"] as? [[String: Any]] ?? []
            let artistName = artists.compactMap { $0["name"] as? String }.joined(separator: " / ")
            return SodaTrack(
                id: id,
                name: track["name"] as? String ?? "",
                artist: artistName,
                coverURL: album["cover_url"] as? String ?? "",
                duration: track["duration"] as? Int ?? 0,
                albumName: album["name"] as? String ?? ""
            )
        }
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

    // MARK: - 播放 URL 与歌词

    struct SodaPlayback {
        let url: String
        let name: String
        let artist: String
    }

    func playbackURL(trackID: String) async throws -> SodaPlayback {
        let data = try await getJSON(makeURL("/song/detail", query: ["track_id": trackID]))
        guard let dict = data as? [String: Any], let url = dict["audio_url"] as? String, !url.isEmpty else {
            throw SodaError.upstream
        }
        let artist = dict["artists"] as? [[String: Any]] ?? []
        return SodaPlayback(
            url: url,
            name: dict["name"] as? String ?? "",
            artist: artist.compactMap { $0["name"] as? String }.joined(separator: " / ")
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
