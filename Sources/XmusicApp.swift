import SwiftUI

// @main 使用纯 SwiftUI App 生命周期 + WindowGroup(手机 UI 自动由 WindowGroup 提供,
// 与 CarTube 完全一致:CarTube = SwiftUI @main + WindowGroup,Info.plist 只声明
// UIWindowSceneSessionRoleCarPlay -> CarPlaySceneDelegate)。
// 之前用 UIApplicationDelegate @main + 手动声明双场景,iOS 15 在 CarPlay 场景连接时
// 系统创建 FBSSceneParameters 崩溃(见崩溃日志 BackboardServices/frontboard)。

@main
struct XMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            makeRootView()
        }
    }
}

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
