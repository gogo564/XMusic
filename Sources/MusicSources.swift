import Foundation

enum MusicSources {
    static let all: [(id: String, name: String)] = [
        ("kw", "酷我"),
        ("wy", "网易"),
        ("tx", "腾讯"),
        ("kg", "酷狗"),
        ("mg", "咪咕"),
    ]

    static func name(_ id: String) -> String {
        all.first(where: { $0.id == id })?.name ?? id
    }
}
