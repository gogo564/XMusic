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

final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published var listData: LXListData?
    @Published var isLoading = false
    @Published var errorMessage: String?

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
        var raw = try await freshRaw()
        var songs = raw["loveList"] as? [[String: Any]] ?? []
        if !songs.contains(where: { isSameSong($0, song) }) {
            songs.append(song.songInfoPayload)
        }
        raw["loveList"] = songs
        try await push(raw)
    }

    func addSongsToLove(_ songs: [LXSong]) async throws {
        guard !songs.isEmpty else { return }
        var raw = try await freshRaw()
        var existing = raw["loveList"] as? [[String: Any]] ?? []
        for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
            existing.append(song.songInfoPayload)
        }
        raw["loveList"] = existing
        try await push(raw)
    }

    func addSongsToDefault(_ songs: [LXSong]) async throws {
        guard !songs.isEmpty else { return }
        var raw = try await freshRaw()
        var existing = raw["defaultList"] as? [[String: Any]] ?? []
        for song in songs where !existing.contains(where: { isSameSong($0, song) }) {
            existing.append(song.songInfoPayload)
        }
        raw["defaultList"] = existing
        try await push(raw)
    }

    func addSongsToPlaylist(_ songs: [LXSong], toPlaylistID pid: String) async throws {
        guard !songs.isEmpty else { return }
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
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
    }

    func removeSongFromLove(_ song: LXSong) async throws {
        var raw = try await freshRaw()
        var songs = raw["loveList"] as? [[String: Any]] ?? []
        songs.removeAll { isSameSong($0, song) }
        raw["loveList"] = songs
        try await push(raw)
    }

    func isLoved(_ song: LXSong) -> Bool {
        listData?.loveSongs.contains { $0.id == song.id } ?? false
    }

    func addSongToDefault(_ song: LXSong) async throws {
        var raw = try await freshRaw()
        var songs = raw["defaultList"] as? [[String: Any]] ?? []
        if !songs.contains(where: { isSameSong($0, song) }) {
            songs.append(song.songInfoPayload)
        }
        raw["defaultList"] = songs
        try await push(raw)
    }

    func removeSongFromDefault(at index: Int) async throws {
        var raw = try await freshRaw()
        var songs = raw["defaultList"] as? [[String: Any]] ?? []
        if songs.indices.contains(index) { songs.remove(at: index) }
        raw["defaultList"] = songs
        try await push(raw)
    }

    func addSong(_ song: LXSong, toPlaylistID pid: String) async throws {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        var found = false
        for i in userLists.indices where userLists[i]["id"] as? String == pid {
            var songs = userLists[i]["list"] as? [[String: Any]] ?? []
            if !songs.contains(where: { isSameSong($0, song) }) {
                songs.append(song.songInfoPayload)
            }
            userLists[i]["list"] = songs
            raw["userList"] = userLists
            found = true
            break
        }
        if !found { throw LXAPIError.decoding("歌单不存在") }
        try await push(raw)
    }

    func removeSong(at index: Int, fromPlaylistID pid: String) async throws {
        var raw = try await freshRaw()
        var userLists = raw["userList"] as? [[String: Any]] ?? []
        var found = false
        for i in userLists.indices where userLists[i]["id"] as? String == pid {
            var songs = userLists[i]["list"] as? [[String: Any]] ?? []
            if songs.indices.contains(index) { songs.remove(at: index) }
            userLists[i]["list"] = songs
            raw["userList"] = userLists
            found = true
            break
        }
        if !found { throw LXAPIError.decoding("歌单不存在") }
        try await push(raw)
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

    @MainActor
    private func push(_ raw: [String: Any]) async throws {
        let updated = LXListData(raw)
        listData = updated
        try await LXAPIClient.shared.saveData(updated)
    }
}
