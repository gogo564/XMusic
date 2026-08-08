import Foundation

enum MusicSources {
    static let all: [(id: String, name: String)] = [
        ("kw", "酷我"),
        ("wy", "网易"),
        ("tx", "腾讯"),
        ("kg", "酷狗"),
        ("mg", "咪咕"),
        ("soda", "汽水"),
    ]

    static func name(_ id: String) -> String {
        all.first(where: { $0.id == id })?.name ?? id
    }

    /// 音质友好名称（与 web 端 Hi-Res/SQ/HQ 对应）
    static func qualityName(_ q: String) -> String {
        switch q.lowercased() {
        case "flac24bit": return "Hi-Res"
        case "flac": return "SQ 无损"
        case "320k": return "HQ 高品"
        case "128k": return "128K"
        case "192k": return "192K"
        case "96k": return "96K"
        case "ogg": return "OGG"
        default: return q
        }
    }
}
