import Foundation
import SwiftData

@Model
final class RecentTrackEntity {
    @Attribute(.unique) var id: String
    var name: String
    var singer: String
    var albumName: String?
    var imageUrl: String?
    var source: String
    var rawJSON: Data
    var lrc: String?
    var lastPlayed: Date

    init(id: String, name: String, singer: String, albumName: String? = nil, imageUrl: String? = nil, source: String = "kw", rawJSON: Data, lrc: String? = nil, lastPlayed: Date = Date()) {
        self.id = id
        self.name = name
        self.singer = singer
        self.albumName = albumName
        self.imageUrl = imageUrl
        self.source = source
        self.rawJSON = rawJSON
        self.lrc = lrc
        self.lastPlayed = lastPlayed
    }

    var song: LXSong? {
        LXSong(jsonData: rawJSON)
    }
}
