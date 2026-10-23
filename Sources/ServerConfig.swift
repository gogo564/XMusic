import Foundation
import Security

struct ServerConfig: Codable, Equatable {
    var baseURL: String = ""
    var username: String = ""
    var password: String = ""
    var frontendPassword: String = ""
    var playerPassword: String = ""
    var defaultQuality: String = "128k"
    var autoSwitchSource: Bool = true
    // 汽水音乐 API 服务（自部署 qishui-api），为空则不启用汽水源
    var sodaBaseURL: String = ""

    var normalizedBaseURL: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return "" }
        while url.hasSuffix("/") { url.removeLast() }
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url
    }

    // 账号登录服务（lx-api-server）地址：默认与主服务器同主机、8081 端口
    var loginBaseURL: String {
        guard let u = URL(string: normalizedBaseURL), let host = u.host else { return "" }
        let scheme = u.scheme ?? "http"
        return "\(scheme)://\(host):8081"
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
                return cfg
            }
            return ServerConfig()
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.serverConfig)
            }
        }
    }

    var token: String? {
        get { defaults.string(forKey: Keys.token) }
        set { defaults.set(newValue, forKey: Keys.token) }
    }

    func clearToken() {
        defaults.removeObject(forKey: Keys.token)
    }
}
