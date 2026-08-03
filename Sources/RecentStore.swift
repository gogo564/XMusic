import Foundation
import Combine

struct RecentTrack: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var singer: String
    var albumName: String?
    var imageUrl: String?
    var source: String
    var rawJSON: Data
    var lrc: String?
    var lastPlayed: Date

    init(song: LXSong, lrc: String? = nil) {
        self.id = song.id
        self.name = song.name
        self.singer = song.singer
        self.albumName = song.albumName.isEmpty ? nil : song.albumName
        self.imageUrl = song.imageURL.isEmpty ? nil : song.imageURL
        self.source = song.source
        self.rawJSON = song.jsonData ?? Data()
        self.lrc = lrc
        self.lastPlayed = Date()
    }

    var song: LXSong? {
        LXSong(jsonData: rawJSON)
    }
}

final class RecentStore: ObservableObject {
    static let shared = RecentStore()

    private let key = "recentTracks"
    private let limit = 50

    @Published private(set) var items: [RecentTrack] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([RecentTrack].self, from: data) {
            items = arr
        }
    }

    func upsert(_ song: LXSong, lrc: String? = nil) {
        var track = RecentTrack(song: song, lrc: lrc)
        track.lastPlayed = Date()
        items.removeAll { $0.id == song.id }
        items.insert(track, at: 0)
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        persist()
    }

    func remove(_ track: RecentTrack) {
        items.removeAll { $0.id == track.id }
        persist()
    }

    func remove(songID: String) {
        items.removeAll { $0.id == songID }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
