import Foundation

// LX music song. Keeps the raw dictionary so it can be passed back to the
// server's /api/music/url (which accepts both flat search results and
// meta-wrapped playlist songs).
struct LXSong: Identifiable {
    let raw: [String: Any]

    init(_ dict: [String: Any]) {
        raw = dict
    }

    var id: String {
        let base = source + "_" + (songmid ?? "")
        return base.isEmpty ? (name + singer) : base
    }

    var name: String {
        raw["name"] as? String ?? (meta["name"] as? String) ?? ""
    }
    var singer: String {
        raw["singer"] as? String ?? (meta["singer"] as? String) ?? ""
    }
    var source: String {
        raw["source"] as? String ?? (meta["source"] as? String) ?? "kw"
    }
    var songmid: String? {
        if let v = raw["songmid"] as? String { return v }
        if let v = raw["songmid"] as? Int { return String(v) }
        if let v = meta["songId"] { return String(describing: v) }
        return nil
    }
    var interval: String {
        raw["interval"] as? String ?? (meta["interval"] as? String) ?? ""
    }
    var albumName: String {
        raw["albumName"] as? String ?? (meta["albumName"] as? String) ?? ""
    }
    var albumId: String? {
        if let v = raw["albumId"] as? String { return v }
        if let v = raw["albumId"] as? Int { return String(v) }
        return (meta["albumId"] as? String)
    }
    var imageURL: String {
        raw["img"] as? String ?? (meta["picUrl"] as? String) ?? (raw["albumImg"] as? String) ?? ""
    }
    var hash: String {
        raw["hash"] as? String ?? (meta["hash"] as? String) ?? ""
    }

    var meta: [String: Any] {
        raw["meta"] as? [String: Any] ?? [:]
    }

    // quality options: [[type, size]...] or _types dict
    var qualities: [(type: String, size: String)] {
        var result: [(String, String)] = []
        if let types = raw["types"] as? [[String: Any]] {
            for t in types {
                let type = t["type"] as? String ?? ""
                let size = t["size"] as? String ?? ""
                if !type.isEmpty { result.append((type, size)) }
            }
        }
        if result.isEmpty, let _types = raw["_types"] as? [String: Any] {
            for (type, v) in _types {
                let size = (v as? [String: Any])?["size"] as? String ?? ""
                result.append((type, size))
            }
        }
        if result.isEmpty, let qs = meta["qualitys"] as? [[String: Any]] {
            for t in qs {
                let type = t["type"] as? String ?? ""
                let size = t["size"] as? String ?? ""
                if !type.isEmpty { result.append((type, size)) }
            }
        }
        if result.isEmpty {
            result = [("128k", ""), ("320k", ""), ("flac", "")]
        }
        return result
    }

    // Payload for /api/music/url
    var songInfoPayload: [String: Any] { raw }
}

struct LXPlaylist: Identifiable {
    let raw: [String: Any]
    let songs: [LXSong]

    init(_ dict: [String: Any]) {
        raw = dict
        let list = dict["list"] as? [[String: Any]] ?? []
        songs = list.map(LXSong.init)
    }

    var id: String {
        raw["id"] as? String ?? name
    }
    var name: String {
        raw["name"] as? String ?? "未命名歌单"
    }
    var source: String {
        raw["source"] as? String ?? ""
    }
    var cover: String {
        raw["img"] as? String ?? (raw["Album"] as? String) ?? ""
    }
    var songCount: Int { songs.count }
}

// Persistence helpers: LXSong keeps the raw dict, which serializes to JSON.
extension LXSong {
    var jsonData: Data? {
        try? JSONSerialization.data(withJSONObject: raw)
    }

    init?(jsonData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return nil }
        self.init(obj)
    }
}

// 收藏歌手 (server /api/user/library/artists)
struct LXLibraryArtist: Identifiable {
    let raw: [String: Any]

    init(_ dict: [String: Any]) {
        raw = dict
    }

    var id: String { (source + "_" + String(describing: raw["id"] ?? "")).isEmpty ? name : source + "_" + String(describing: raw["id"] ?? "") }
    var artistID: String { String(describing: raw["id"] ?? "") }
    var name: String { raw["name"] as? String ?? "未知歌手" }
    var source: String { raw["source"] as? String ?? "wy" }
    var picUrl: String { raw["picUrl"] as? String ?? "" }

    func toPayload() -> [String: Any] { raw }
}

// 收藏专辑 (server /api/user/library/albums), songs embedded in `list`
struct LXLibraryAlbum: Identifiable {
    let raw: [String: Any]
    let songs: [LXSong]

    init(_ dict: [String: Any]) {
        raw = dict
        let list = dict["list"] as? [[String: Any]] ?? []
        songs = list.map(LXSong.init)
    }

    var id: String {
        let base = source + "_" + String(describing: raw["id"] ?? "")
        return base.isEmpty ? name : base
    }
    var albumID: String { String(describing: raw["id"] ?? "") }
    var name: String { raw["name"] as? String ?? "未知专辑" }
    var artistName: String { raw["artistName"] as? String ?? "" }
    var source: String { raw["source"] as? String ?? "wy" }
    var picUrl: String { raw["picUrl"] as? String ?? "" }
    var interval: String { raw["interval"] as? String ?? "" }
    var songCount: Int { songs.count }

    func toPayload() -> [String: Any] { raw }
}

// 歌单广场 (online playlists from songList API)
struct LXOnlinePlaylist: Identifiable {
    let raw: [String: Any]

    init(_ dict: [String: Any]) {
        raw = dict
    }

    var id: String { String(describing: raw["id"] ?? "") }
    var name: String { raw["name"] as? String ?? "" }
    var author: String { raw["author"] as? String ?? "" }
    var imageURL: String { raw["picUrl"] as? String ?? (raw["img"] as? String) ?? "" }
    var playCount: String { raw["playCount"] as? String ?? (raw["play_count"] as? String) ?? "" }
    var songCount: Int {
        if let v = raw["trackCount"] as? Int { return v }
        if let v = raw["total"] as? Int { return v }
        if let s = raw["total"] as? String { return Int(s) ?? 0 }
        return 0
    }
    var desc: String { raw["desc"] as? String ?? "" }
    var source: String { raw["source"] as? String ?? "wy" }
}

// 搜索到的歌手 (type=singer)
struct LXArtist: Identifiable {
    let raw: [String: Any]

    init(_ dict: [String: Any]) {
        raw = dict
    }

    var id: String { String(describing: raw["id"] ?? "") }
    var name: String { raw["name"] as? String ?? "" }
    var picUrl: String { raw["picUrl"] as? String ?? "" }
    var albumSize: Int { (raw["albumSize"] as? Int) ?? 0 }
    var aliases: [String] { raw["alias"] as? [String] ?? [] }
    var source: String { raw["source"] as? String ?? "wy" }

    func toPayload() -> [String: Any] { raw }
}

// 搜索到的专辑 (type=album)
struct LXAlbum: Identifiable {
    let raw: [String: Any]

    init(_ dict: [String: Any]) {
        raw = dict
    }

    var id: String { String(describing: raw["id"] ?? "") }
    var name: String { raw["name"] as? String ?? "" }
    var picUrl: String { raw["picUrl"] as? String ?? "" }
    var artistName: String { raw["artistName"] as? String ?? "" }
    var artistId: String { String(describing: raw["artistId"] ?? "") }
    var size: Int {
        if let v = raw["size"] as? Int { return v }
        if let v = raw["total"] as? Int { return v }
        if let v = raw["total"] as? String { return Int(v) ?? 0 }
        return 0
    }
    var publishTime: Int64 { (raw["publishTime"] as? Int64) ?? 0 }
    var source: String { raw["source"] as? String ?? "wy" }

    func toPayload() -> [String: Any] { raw }
}

enum LXListKind: String {
    case defaultList
    case love
    case user
}

struct LXListData {
    let raw: [String: Any]
    let defaultSongs: [LXSong]
    let loveSongs: [LXSong]
    let userList: [LXPlaylist]

    init(_ dict: [String: Any]) {
        raw = dict
        defaultSongs = (dict["defaultList"] as? [[String: Any]] ?? []).map(LXSong.init)
        if let loveRaw = dict["loveList"] as? [[String: Any]] {
            if let first = loveRaw.first, let inner = first["list"] as? [[String: Any]] {
                loveSongs = inner.map(LXSong.init)
            } else {
                loveSongs = loveRaw.map(LXSong.init)
            }
        } else {
            loveSongs = []
        }
        userList = (dict["userList"] as? [[String: Any]] ?? []).map(LXPlaylist.init)
    }

    var playlists: [LXPlaylist] { userList }

    func songs(kind: LXListKind, playlistID: String) -> [LXSong] {
        switch kind {
        case .defaultList: return defaultSongs
        case .love: return loveSongs
        case .user:
            return userList.first { $0.id == playlistID }?.songs ?? []
        }
    }
}
