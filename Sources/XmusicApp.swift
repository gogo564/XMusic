import SwiftUI

@main
struct XmusicApp: App {
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var downloader = DownloadService.shared
    @StateObject private var recentStore = RecentStore.shared
    @State private var needsConfig = false

    var body: some Scene {
        WindowGroup {
            RootView(needsConfig: $needsConfig)
                .environmentObject(player)
                .environmentObject(playlistStore)
                .environmentObject(downloader)
                .environmentObject(recentStore)
                .onAppear {
                    needsConfig = AppConfigStore.shared.token == nil
                    if !needsConfig {
                        Task { await playlistStore.refresh() }
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Binding var needsConfig: Bool

    var body: some View {
        if needsConfig {
            NavigationView {
                SettingsView(needsConfig: $needsConfig)
            }
            .navigationViewStyle(.stack)
        } else {
            ContentView()
                .sheet(isPresented: $needsConfig) {
                    NavigationView {
                        SettingsView(needsConfig: $needsConfig)
                    }
                    .navigationViewStyle(.stack)
                }
        }
    }
}
