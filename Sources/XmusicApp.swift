import SwiftUI

@main
struct XmusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var downloader = DownloadService.shared
    @StateObject private var recentStore = RecentStore.shared
    @StateObject private var libraryStore = LibraryStore.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var needsConfig = false

    init() {
        // iOS 15 嵌套 ScrollView 会延迟内容触摸，导致内层横向标签行
        // 点击被判定为滚动而难以命中。关闭 delaysContentTouches 让子视图立即响应点击，
        // 滑动仍由 UIScrollView 的 pan 手势正常处理。
        UIScrollView.appearance().delaysContentTouches = false
    }

    var body: some Scene {
        WindowGroup {
            RootView(needsConfig: $needsConfig)
                .environmentObject(player)
                .environmentObject(playlistStore)
                .environmentObject(downloader)
                .environmentObject(recentStore)
                .environmentObject(libraryStore)
                .environmentObject(networkMonitor)
                .onAppear {
                    needsConfig = AppConfigStore.shared.token == nil
                    if !needsConfig {
                        Task {
                            await playlistStore.refresh()
                            await libraryStore.loadIfNeeded()
                        }
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Binding var needsConfig: Bool
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {
        if needsConfig {
            NavigationView {
                SettingsView(needsConfig: $needsConfig)
            }
            .navigationViewStyle(.stack)
        } else if networkMonitor.isConnected {
            ContentView()
                .sheet(isPresented: $needsConfig) {
                    NavigationView {
                        SettingsView(needsConfig: $needsConfig)
                    }
                    .navigationViewStyle(.stack)
                }
        } else {
            OfflineView()
        }
    }
}
