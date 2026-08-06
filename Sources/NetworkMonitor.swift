import Foundation
import Network
import Combine

/// 网络状态监听：NWPathMonitor（iOS 12+ 可用，兼容 iOS 15）。
/// 在线/离线切换时发布 isConnected，供 RootView 自动切换界面。
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isConnected = path.status == .satisfied
                self.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: queue)
    }
}
