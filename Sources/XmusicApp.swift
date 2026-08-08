import SwiftUI

@main
struct XmusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = PlayerManager.shared
    @StateObject private var playlistStore = PlaylistStore.shared
    @StateObject private var downloader = DownloadService.shared
    @StateObject private var recentStore = RecentStore.shared
    @StateObject private var libraryStore = LibraryStore.shared
    @StateObject private var networkMonitor = NetworkMonitor.shared
    @State private var needsConfig = false

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
