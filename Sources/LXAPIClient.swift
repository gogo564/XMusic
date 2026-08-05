import Foundation

enum LXAPIError: LocalizedError {
    case notConfigured
    case invalidURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置服务器"
        case .invalidURL: return "服务器地址无效"
        case .http(let code, let msg): return "HTTP \(code): \(msg)"
        case .decoding(let msg): return "数据解析失败: \(msg)"
        }
    }
}

struct PlaybackURLResult {
    let url: String
    let type: String
    let sourceName: String
    let requestedSource: String
}

struct LyricResult {
    let lyric: String?
    let translated: String?
}

final class LXAPIClient {
    static let shared = LXAPIClient()

    private init() {}

    private func headers(_ cfg: ServerConfig, authed: Bool = true) -> [String: String] {
        var h: [String: String] = [
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
        if authed {
            h["x-frontend-auth"] = cfg.frontendPassword
            h["x-user-name"] = cfg.username
            if let token = AppConfigStore.shared.token {
                h["x-user-token"] = token
            }
        }
        return h
    }

    // MARK: - Login

    @discardableResult
    func login() async throws -> String {
        let cfg = AppConfigStore.shared.config
        guard let url = cfg.resolvedURL("/api/user/login") else { throw LXAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": cfg.username, "password": cfg.password])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LXAPIError.decoding("登录响应")
        }
        guard status == 200, let token = obj["token"] as? String else {
            let msg = obj["message"] as? String ?? "账号或密码错误"
            throw LXAPIError.http(status, msg)
        }
        AppConfigStore.shared.token = token
        return token
    }

    // MARK: - Search

    func search(name: String, source: String, page: Int = 1, pages: Int = 1) async throws -> [LXSong] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/search")!
        comps.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "type", value: "song"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "pages", value: "\(pages)"),
        ]
        guard let url = comps.url else { throw LXAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw LXAPIError.decoding("搜索")
        }
        return arr.map(LXSong.init)
    }

    func tipSearch(name: String, source: String = "kw") async throws -> [String] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/tipSearch")!
        comps.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "source", value: source),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    }

    // MARK: - Playback URL

    func getPlaybackURL(for song: LXSong, quality: String, autoSwitch: Bool = true) async throws -> PlaybackURLResult {
        do {
            return try await getPlaybackURLOnce(for: song, quality: quality, autoSwitch: autoSwitch)
        } catch let LXAPIError.http(code, _) where code == 401 {
            _ = try? await login()
            return try await getPlaybackURLOnce(for: song, quality: quality, autoSwitch: autoSwitch)
        }
    }

    private func getPlaybackURLOnce(for song: LXSong, quality: String, autoSwitch: Bool) async throws -> PlaybackURLResult {
        let cfg = AppConfigStore.shared.config
        guard let url = cfg.resolvedURL("/api/music/url") else { throw LXAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers(cfg)
        let body: [String: Any] = [
            "songInfo": song.songInfoPayload,
            "quality": quality,
            "enableAutoSwitchApiSource": autoSwitch,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playURL = obj["url"] as? String else {
            let errMsg = try (JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "解析失败"
            throw LXAPIError.decoding(errMsg)
        }
        return PlaybackURLResult(
            url: playURL,
            type: obj["type"] as? String ?? quality,
            sourceName: obj["sourceName"] as? String ?? song.source,
            requestedSource: obj["requestedSource"] as? String ?? song.source
        )
    }

    // MARK: - Lyric

    func getLyric(for song: LXSong) async throws -> LyricResult {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/lyric")!
        comps.queryItems = [
            URLQueryItem(name: "source", value: song.source),
            URLQueryItem(name: "songmid", value: song.songmid ?? ""),
            URLQueryItem(name: "name", value: song.name),
            URLQueryItem(name: "singer", value: song.singer),
            URLQueryItem(name: "interval", value: song.interval),
            URLQueryItem(name: "hash", value: song.hash),
        ]
        guard let url = comps.url else { throw LXAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        try ensureOK(response)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LXAPIError.decoding("歌词")
        }
        return LyricResult(
            lyric: obj["lyric"] as? String,
            translated: obj["tlyric"] as? String
        )
    }

    // MARK: - Data / playlists

    /// 401 时自动重新登录并重试一次（session token 7 天过期）。
    private func withAuthRetry<T>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch let LXAPIError.http(code, _) where code == 401 {
            _ = try? await login()
            return try await op()
        }
    }

    func getData(user: String? = nil) async throws -> LXListData {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/data")!
            comps.queryItems = [URLQueryItem(name: "user", value: user ?? cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers(cfg)
            let (data, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LXAPIError.decoding("歌单")
            }
            return LXListData(obj)
        }
    }

    func saveData(_ listData: LXListData) async throws {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/user/list")!
            comps.queryItems = [URLQueryItem(name: "user", value: cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = headers(cfg)
            request.httpBody = try JSONSerialization.data(withJSONObject: listData.raw)
            let (_, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
        }
    }

    // MARK: - Library (收藏歌手 / 收藏专辑)

    func getLibraryArtists() async throws -> [[String: Any]] {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/user/library/artists")!
            comps.queryItems = [URLQueryItem(name: "user", value: cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers(cfg)
            let (data, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw LXAPIError.decoding("收藏歌手")
            }
            return arr
        }
    }

    func getLibraryAlbums() async throws -> [[String: Any]] {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/user/library/albums")!
            comps.queryItems = [URLQueryItem(name: "user", value: cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers(cfg)
            let (data, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw LXAPIError.decoding("收藏专辑")
            }
            return arr
        }
    }

    func saveLibraryArtists(_ artists: [[String: Any]]) async throws {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/user/library/artists")!
            comps.queryItems = [URLQueryItem(name: "user", value: cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = headers(cfg)
            request.httpBody = try JSONSerialization.data(withJSONObject: artists)
            let (_, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
        }
    }

    func saveLibraryAlbums(_ albums: [[String: Any]]) async throws {
        try await withAuthRetry {
            let cfg = AppConfigStore.shared.config
            var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/user/library/albums")!
            comps.queryItems = [URLQueryItem(name: "user", value: cfg.username)]
            guard let url = comps.url else { throw LXAPIError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.allHTTPHeaderFields = headers(cfg)
            request.httpBody = try JSONSerialization.data(withJSONObject: albums)
            let (_, response) = try await URLSession.shared.data(for: request)
            try ensureOK(response)
        }
    }

    // MARK: - Browse

    func getLeaderBoards(source: String = "kg") async throws -> [[String: Any]] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/leaderboard/boards")!
        comps.queryItems = [URLQueryItem(name: "source", value: source)]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return [] }
        return list
    }

    func getLeaderBoardSongs(source: String = "kg", bangid: String, page: Int = 1) async throws -> [LXSong] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/leaderboard/list")!
        comps.queryItems = [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "bangid", value: bangid),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return [] }
        return list.map(LXSong.init)
    }

    func getHotSearch(source: String = "mg") async throws -> [String] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/hotSearch")!
        comps.queryItems = [URLQueryItem(name: "source", value: source)]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [String] else { return [] }
        return list
    }

    // MARK: - 歌单广场 (songList)

    func searchPlaylists(name: String, source: String) async throws -> [LXOnlinePlaylist] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/songList/search")!
        comps.queryItems = [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "text", value: name),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return [] }
        return list.map(LXOnlinePlaylist.init)
    }

    // tagGroup: [[name, id]...] flattened from the first-level category list
    func getSongListTags(source: String = "wy") async throws -> [(name: String, id: String)] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/songList/tags")!
        comps.queryItems = [URLQueryItem(name: "source", value: source)]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tags = obj["tags"] as? [[String: Any]],
              let first = tags.first,
              let list = first["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { tag in
            if let id = tag["id"] as? String, let name = tag["name"] as? String {
                return (name, id)
            }
            return nil
        }
    }

    func getSongListByTag(source: String = "wy", tagId: String?, page: Int = 1) async throws -> [LXOnlinePlaylist] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/songList/list")!
        var items = [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "sortId", value: "hot"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        if let tagId = tagId, !tagId.isEmpty {
            items.append(URLQueryItem(name: "tagId", value: tagId))
        }
        comps.queryItems = items
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return [] }
        return list.map(LXOnlinePlaylist.init)
    }

    func getSongListDetail(source: String = "wy", playlistID: String, page: Int = 1) async throws -> [LXSong] {
        let cfg = AppConfigStore.shared.config
        var comps = URLComponents(string: cfg.normalizedBaseURL + "/api/music/songList/detail")!
        comps.queryItems = [
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "id", value: playlistID),
            URLQueryItem(name: "page", value: "\(page)"),
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["list"] as? [[String: Any]] else { return [] }
        return list.map(LXSong.init)
    }

    // MARK: - Download

    func downloadURL(for song: LXSong, quality: String) async throws -> String {
        let result = try await getPlaybackURL(for: song, quality: quality)
        return result.url
    }

    private func ensureOK(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LXAPIError.http(http.statusCode, HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
        }
    }
}
