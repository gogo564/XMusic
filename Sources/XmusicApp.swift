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
    /// 启动引导中：先静默登录拿 token，再决定进首页还是进设置页，
    /// 避免"token 失效时先闪一下设置页"。
    @State private var isBootstrapping = true
    @EnvironmentObject var networkMonitor: NetworkMonitor
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        Group {
            if isBootstrapping {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if needsConfig {
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
        // 主题动态生效：theme 是 @EnvironmentObject，其 @Published(color/mode/isDark)
        // 任一变化都会让 body 重算，从而带 .tint/.preferredColorScheme 一起重新求值，
        // 实现切主题色/深浅立即生效（避免 .id 整树重建打断播放）。
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            Task { await bootstrap() }
        }
    }

    /// 启动引导：只要服务器地址/账号已填好，就静默登录一次换新 token。
    /// 服务端重启会清空内存里的 session（token 7 天过期 + 重启即失效），
    /// 这里主动换取新 token，用户不用再手点"测试连接并登录"。
    @MainActor
    private func bootstrap() async {
        let cfg = AppConfigStore.shared.config
        let hasConfig = !cfg.normalizedBaseURL.isEmpty
            && !cfg.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !cfg.password.isEmpty

        if hasConfig {
            do {
                _ = try await LXAPIClient.shared.login()
                Log.write("🔑 [启动] 自动登录成功")
            } catch {
                Log.write("⚠️ [启动] 自动登录失败：\(error.localizedDescription)")
            }
        }

        needsConfig = AppConfigStore.shared.token == nil
        isBootstrapping = false

        if !needsConfig {
            await PlaylistStore.shared.refresh()
            await LibraryStore.shared.loadIfNeeded()
        }
    }
}
