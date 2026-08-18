import SwiftUI

// @main 已移至 AppDelegate(参考音流/flutter_carplay 与 vanities/carplay-swiftui:
// CarPlay 模板场景在纯 SwiftUI @main App 生命周期下可能不被车机正常接受)。
// 这里只保留根视图与工厂方法,供 SceneDelegate 包装进 UIHostingController。

func makeRootView() -> some View {
    let theme = ThemeManager.shared
    return RootView()
        .environmentObject(PlayerManager.shared)
        .environmentObject(PlaylistStore.shared)
        .environmentObject(DownloadService.shared)
        .environmentObject(RecentStore.shared)
        .environmentObject(LibraryStore.shared)
        .environmentObject(NetworkMonitor.shared)
        .environmentObject(theme)
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
}

struct RootView: View {
    @State private var needsConfig = false
    @EnvironmentObject var networkMonitor: NetworkMonitor

    var body: some View {
        Group {
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
        .onAppear {
            needsConfig = AppConfigStore.shared.token == nil
            if !needsConfig {
                Task {
                    await PlaylistStore.shared.refresh()
                    await LibraryStore.shared.loadIfNeeded()
                }
            }
        }
    }
}