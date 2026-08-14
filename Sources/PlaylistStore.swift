import Foundation
import Combine

private func storedSongID(_ dict: [String: Any]) -> String {
    if let v = dict["id"] as? String { return v }
    if let s = dict["songmid"] as? String { return s }
    if let i = dict["songmid"] as? Int { return String(i) }
    if let meta = dict["meta"] as? [String: Any] {
        if let s = meta["songId"] as? String { return s }
        if let i = meta["songId"] as? Int { return String(i) }
    }
    return ""
}

private func isSameSong(_ dict: [String: Any], _ song: LXSong) -> Bool {
    let storedID = storedSongID(dict)
    if !storedID.isEmpty, storedID == song.songmid { return true }
    if let id = dict["id"] as? String, id == song.id { return true }
    return false
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published var listData: LXListData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isPushing = false
    @Published var lastPushFailed = false

    private var pushTask: Task<Void, Never>?
    private var pendingRaw: [String: Any]?
    private let pushDebounceSeconds: TimeInterval = 1.5

    private init() {}

    @MainActor
    func refresh() async {
        isLoading = true
        do {
            listData = try await LXAPIClient.shared.getData()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var playlists: [LXPlaylist] { listData?.userList ?? [] }

    func playlist(id: String) -> LXPlaylist? {
        listData?.userList.first { $0.id == id }
    }

    // MARK: - Reading songs

    func songs(kind: LXListKind, playlistID: String) -> [LXSong] {
        listData?.songs(kind: kind, playlistID: playlistID) ?? []
    }

    // MARK: - Mutations (then push to server)

    func addSongToLove(_ song: LXSong) async throws {
        apply { raw in
            var songs = raw["loveList"] as? [[String: Any]] ?? []
            if !songs.contains(where: { isSameSong($0, song) }) {
                songs.append(song.songInfoPayload)
            }
            raw["loveList"] = songs
        }
    }

    func addSongsToLove(_ songs: [LXSong]) async throws {
        guard !songs.isEmpty else { return }
        apply { raw in
            var existing = raw["loveList"] as? [[String: Any]] ?? []
            for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
                existing.append(song.songInfoPayload)
            }
            raw["loveList"] = existing
        }
    }

    func addSongsToDefault(_ songs: [LXSong]) async throws {
        guard !songs.isEmpty else { return }
        apply { raw in
            var existing = raw["defaultList"] as? [[String: Any]] ?? []
            for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
                existing.append(song.songInfoPayload)
            }
            raw["defaultList"] = existing
        }
    }

    func addSongsToPlaylist(_ songs: [LXSong], toPlaylistID pid: String) async throws {
        guard !songs.isEmpty else { return }
        apply { raw in
            var userLists = raw["userList"] as? [[String: Any]] ?? []
            for i in userLists.indices where userLists[i]["id"] as? String == pid {
                var existing = userLists[i]["list"] as? [[String: Any]] ?? []
                for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
                    existing.append(song.songInfoPayload)
                }
                userLists[i]["list"] = existing
                raw["userList"] = userLists
                break
            }
        }
    }

    func removeSongFromLove(_ song: LXSong) async throws {
        apply { raw in
            var songs = raw["loveList"] as? [[String: Any]] ?? []
            songs.removeAll { isSameSong($0, song) }
            raw["loveList"] = songs
        }
    }

    /// 批量从「我喜欢的音乐」移除（按索引，倒序删除）。
    func removeSongsFromLove(at indices: [Int]) async throws {
        guard !indices.isEmpty else { return }
        apply { raw in
            var list = raw["loveList"] as? [[String: Any]] ?? []
            let sorted = indices.sorted(by: >)
            for i in sorted where list.indices.contains(i) {
                list.remove(at: i)
            }
            raw["loveList"] = list
        }
    }

    /// 批量从「默认列表」移除（按索引，倒序删除）。
    func removeSongsFromDefault(at indices: [Int]) async throws {
        guard !indices.isEmpty else { return }
        apply { raw in
            var list = raw["defaultList"] as? [[String: Any]] ?? []
            let sorted = indices.sorted(by: >)
            for i in sorted where list.indices.contains(i) {
                list.remove(at: i)
            }
            raw["defaultList"] = list
        }
    }

    /// 批量从用户歌单移除（按索引，倒序删除）。
    func removeSongs(at indices: [Int], fromPlaylistID pid: String) async throws {
        guard !indices.isEmpty else { return }
        apply { raw in
            var userLists = raw["userList"] as? [[String: Any]] ?? []
            for i in userLists.indices where userLists[i]["id"] as? String == pid {
                var existing = userLists[i]["list"] as? [[String: Any]] ?? []
                let sorted = indices.sorted(by: >)
                for j in sorted where existing.indices.contains(j) {
                    existing.remove(at: j)
                }
                userLists[i]["list"] = existing
                raw["userList"] = userLists
                break
            }
        }
    }

    func isLoved(_ song: LXSong) -> Bool {
        listData?.loveSongs.contains { $0.id == song.id } ?? false
    }

    func addSongToDefault(_ song: LXSong) async throws {
        apply { raw in
            var songs = raw["defaultList"] as? [[String: Any]] ?? []
            if !songs.contains(where: { isSameSong($0, song) }) {
                songs.append(song.songInfoPayload)
            }
            raw["defaultList"] = songs
        }
    }

    func removeSongFromDefault(at index: Int) async throws {
        apply { raw in
            var songs = raw["defaultList"] as? [[String: Any]] ?? []
            if songs.indices.contains(index) { songs.remove(at: index) }
            raw["defaultList"] = songs
        }
    }

    func addSong(_ song: LXSong, toPlaylistID pid: String) async throws {
        apply { raw in
            var userLists = raw["userList"] as? [[String: Any]] ?? []
            for i in userLists.indices where userLists[i]["id"] as? String == pid {
                var songs = userLists[i]["list"] as? [[String: Any]] ?? []
                if !songs.contains(where: { isSameSong($0, song) }) {
                    songs.append(song.songInfoPayload)
                }
                userLists[i]["list"] = songs
                raw["userList"] = userLists
                break
            }
        }
    }

    func removeSong(at index: Int, fromPlaylistID pid: String) async throws {
        apply { raw in
            var userLists = raw["userList"] as? [[String: Any]] ?? []
            for i in userLists.indices where userLists[i]["id"] as? String == pid {
                var songs = userLists[i]["list"] as? [[String: Any]] ?? []
                if songs.indices.contains(index) { songs.remove(at: index) }
                userLists[i]["list"] = songs
                raw["userList"] = userLists
                break
            }
        }
    }

    func createPlaylist(name: String) async throws {
        var raw = try await freshRaw()
        let pid = "webplayer_\(Int(Date().timeIntervalSince1970 * 1000))"
        let newList: [String: Any] = [
            "id": pid,
            "name": name,
            "source": "webplayer",
            "list": [[String: Any]](),
        ]
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        userLists.insert(newList, at: 0)
        raw["userList"] = userLists
        try await push(raw)
    }

    /// 一键整单加入：同名歌单已存在则加入其中，否则新建同名歌单再加入。
    func addSongsToNamedPlaylist(_ songs: [LXSong], name: String) async throws -> String {
        guard !songs.isEmpty else { throw LXAPIError.decoding("歌单为空") }
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        let pid: String
        if let existing = userLists.first(where: { ($0["name"] as? String) == name }) {
            pid = existing["id"] as? String ?? ""
        } else {
            pid = "webplayer_\(Int(Date().timeIntervalSince1970 * 1000))"
            let newList: [String: Any] = [
                "id": pid,
                "name": name,
                "source": "webplayer",
                "list": [[String: Any]](),
            ]
            userLists.insert(newList, at: 0)
        }
        guard !pid.isEmpty else { throw LXAPIError.decoding("歌单不存在") }
        var found = false
        for i in userLists.indices where userLists[i]["id"] as? String == pid {
            var existing = userLists[i]["list"] as? [[String: Any]] ?? []
            for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
                existing.append(song.songInfoPayload)
            }
            userLists[i]["list"] = existing
            raw["userList"] = userLists
            found = true
            break
        }
        if !found { throw LXAPIError.decoding("歌单不存在") }
        try await push(raw)
        return pid
    }

    /// 一键收藏在线歌单（红心收藏）。已收藏则直接返回 true，否则新建带
    /// sourceListId + Album 封面的 userList 项（与 web player 收藏格式一致）。
    /// 返回是否处于已收藏状态。
    @discardableResult
    func collectOnlinePlaylist(playlist: LXOnlinePlaylist, source: String, songs: [LXSong]) async throws -> Bool {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        let onlineID = String(describing: playlist.id)
        if let existing = userLists.first(where: { String(describing: $0["sourceListId"] ?? "") == onlineID && ($0["source"] as? String) == source }) {
            return true
        }
        let randomHex = { String(format: "%08x", UInt32.random(in: 0...UInt32.max)) }
        let newID = "\(source)_\(randomHex())\(randomHex())\(randomHex())\(randomHex())"
        let payloads = songs.map { $0.songInfoPayload }
        let newList: [String: Any] = [
            "id": newID,
            "name": playlist.name,
            "source": source,
            "sourceListId": onlineID,
            "Album": playlist.imageURL,
            "locationUpdateTime": NSNull(),
            "list": payloads,
        ]
        userLists.insert(newList, at: 0)
        raw["userList"] = userLists
        try await push(raw)
        return true
    }

    /// 取消收藏在线歌单（红心取消），按 sourceListId+source 匹配。
    @discardableResult
    func uncollectOnlinePlaylist(playlistID: String, source: String) async throws -> Bool {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        let onlineID = String(describing: playlistID)
        userLists.removeAll { String(describing: $0["sourceListId"] ?? "") == onlineID && ($0["source"] as? String) == source }
        raw["userList"] = userLists
        try await push(raw)
        return false
    }

    /// 在线歌单是否已收藏（红心状态）
    func isOnlinePlaylistCollected(playlistID: String, source: String) -> Bool {
        guard let listData = listData else { return false }
        let onlineID = String(describing: playlistID)
        return listData.userList.contains { String(describing: $0.raw["sourceListId"] ?? "") == onlineID && ($0.raw["source"] as? String) == source }
    }

    func renamePlaylist(id pid: String, newName: String) async throws {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        var found = false
        for i in userLists.indices where userLists[i]["id"] as? String == pid {
            userLists[i]["name"] = newName
            raw["userList"] = userLists
            found = true
            break
        }
        if found { try await push(raw) }
    }

    func deletePlaylist(id pid: String) async throws {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        userLists.removeAll { $0["id"] as? String == pid }
        raw["userList"] = userLists
        try await push(raw)
    }

    /// Fetch the latest server data before mutating, so edits never overwrite
    /// changes made elsewhere (CarPlay / web / other devices).
    private func freshRaw() async throws -> [String: Any] {
        do {
            let fresh = try await LXAPIClient.shared.getData()
            await MainActor.run { self.listData = fresh }
            return fresh.raw
        } catch {
            if let raw = listData?.raw {
                return raw
            }
            throw error
        }
    }

    /// 乐观变更：直接改本地 listData 立即生效（UI 秒反馈），随后防抖批量推到服务器。
    /// 若失败，稍后带退避自动重试，不影响本地体验。
    @MainActor
    private func apply(_ modifier: (inout [String: Any]) -> Void) {
        var raw = listData?.raw ?? [:]
        modifier(&raw)
        listData = LXListData(raw)
        schedulePush(raw)
    }

    private func schedulePush(_ raw: [String: Any]) {
        pendingRaw = raw
        lastPushFailed = false
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(pushDebounceSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.flushPush()
        }
    }

    @MainActor
    private func flushPush() async {
        guard let raw = pendingRaw else { return }
        pendingRaw = nil
        isPushing = true
        let updated = LXListData(raw)
        listData = updated
        do {
            try await LXAPIClient.shared.saveData(updated)
            Log.write("📤 [Playlist] push ok lists=\(updated.userList.count) love=\(updated.loveSongs.count) default=\(updated.defaultSongs.count)")
            lastPushFailed = false
        } catch {
            Log.write("❌ [Playlist] push failed: \(error.localizedDescription)")
            lastPushFailed = true
            errorMessage = error.localizedDescription
            // 失败重试（指数退避，最多 3 次）
            for attempt in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                do {
                    try await LXAPIClient.shared.saveData(updated)
                    Log.write("📤 [Playlist] push ok (retry \(attempt))")
                    lastPushFailed = false
                    break
                } catch {
                    Log.write("❌ [Playlist] push retry \(attempt) failed: \(error.localizedDescription)")
                }
            }
        }
        isPushing = false
    }

    @MainActor
    private func push(_ raw: [String: Any]) async throws {
        let updated = LXListData(raw)
        listData = updated
        do {
            try await LXAPIClient.shared.saveData(updated)
            Log.write("📤 [Playlist] push ok lists=\(updated.userList.count) love=\(updated.loveSongs.count) default=\(updated.defaultSongs.count)")
        } catch {
            Log.write("❌ [Playlist] push failed: \(error.localizedDescription)")
            throw error
        }
    }
}
