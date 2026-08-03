import SwiftUI
import SwiftData

@main
struct XmusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var downloader = DownloadService.shared
    @State private var needsConfig = false

    let modelContainer: ModelContainer = {
        let schema = Schema([RecentTrackEntity.self])
        let container: ModelContainer
        if let c = try? ModelContainer(for: schema) {
            container = c
        } else {
            print("⚠️ [SwiftData] 磁盘容器创建失败，回退为内存容器（最近播放将不持久化）")
            container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        }
        PlayerManager.shared.modelContext = container.mainContext
        return container
    }()

    var body: some Scene {
        WindowGroup {
            RootView(needsConfig: $needsConfig)
                .environmentObject(player)
                .environmentObject(playlistStore)
                .environmentObject(downloader)
                .onAppear {
                    needsConfig = AppConfigStore.shared.token == nil
                    if !needsConfig {
                        Task { await playlistStore.refresh() }
                    }
                }
                .preferredColorScheme(.dark)
        }
        .modelContainer(modelContainer)
    }
}

struct RootView: View {
    @Binding var needsConfig: Bool

    var body: some View {
        if needsConfig {
            NavigationStack {
                SettingsView(needsConfig: $needsConfig)
            }
        } else {
            ContentView()
                .sheet(isPresented: $needsConfig) {
                    NavigationStack {
                        SettingsView(needsConfig: $needsConfig)
                    }
                }
        }
    }
}
