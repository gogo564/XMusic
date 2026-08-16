import Foundation
import Security

struct ServerConfig: Codable, Equatable {
    var baseURL: String = "http://gogo564.x3322.net:9527"
    var username: String = "admin"
    var password: String = "password"
    var frontendPassword: String = "zhu3302872"
    var playerPassword: String = "3302872"
    var defaultQuality: String = "128k"
    var autoSwitchSource: Bool = true
    // 汽水音乐 API 服务（自部署 qishui-api），为空则不启用汽水源
    var sodaBaseURL: String = "http://gogo564.x3322.net:3310"

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }

    func resolvedURL(_ path: String) -> URL? {
        guard let base = URL(string: normalizedBaseURL) else { return nil }
        let full = base.absoluteString + (path.hasPrefix("/") ? path : "/" + path)
        return URL(string: full)
    }
}

final class AppConfigStore {
    static let shared = AppConfigStore()
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let serverConfig = "serverConfig"
        static let token = "userToken"
    }

    var config: ServerConfig {
        get {
            if let data = defaults.data(forKey: Keys.serverConfig),
               let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data) {
                return Self.migrated(cfg)
            }
            return ServerConfig()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.serverConfig)
            }
        }
    }

    // 旧版默认内网 IP → 新域名迁移（端口不变）
    private static func migrated(_ cfg: ServerConfig) -> ServerConfig {
        var c = cfg
        let oldHost = "192.168.1.85"
        let newHost = "gogo564.x3322.net"
        if c.baseURL.contains(oldHost) {
            c.baseURL = c.baseURL.replacingOccurrences(of: oldHost, with: newHost)
        }
        if c.sodaBaseURL.contains(oldHost) {
            c.sodaBaseURL = c.sodaBaseURL.replacingOccurrences(of: oldHost, with: newHost)
        }
        return c
    }

    var token: String? {
        get { defaults.string(forKey: Keys.token) }
        set { defaults.set(newValue, forKey: Keys.token) }
    }

    func clearToken() {
        defaults.removeObject(forKey: Keys.token)
    }
}
