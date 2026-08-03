import SwiftUI

struct SettingsView: View {
    @Binding var needsConfig: Bool
    @EnvironmentObject private var playlistStore: PlaylistStore

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var frontendPassword = ""
    @State private var playerPassword = ""
    @State private var quality = "128k"
    @State private var autoSwitch = true
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var isError = false

    private let qualities = ["128k", "320k", "flac"]

    var body: some View {
        Form {
            Section(header: Text("服务器")) {
                TextField("地址（如 http://192.168.1.85:9527）", text: $baseURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                TextField("用户名", text: $username)
                    .autocapitalization(.none)
                SecureField("密码", text: $password)
            }
            Section(header: Text("管理密码")) {
                TextField("前端密码 (x-frontend-auth)", text: $frontendPassword)
                    .autocapitalization(.none)
                TextField("播放器密码 (Web播放器)", text: $playerPassword)
                    .autocapitalization(.none)
            }
            Section(header: Text("播放")) {
                Picker("默认音质", selection: $quality) {
                    ForEach(qualities, id: \.self) { Text($0) }
                }
                Toggle("源失效自动切换", isOn: $autoSwitch)
            }
            Section {
                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Spacer()
                        if isTesting {
                            ProgressView()
                        } else {
                            Text("测试连接并登录")
                        }
                        Spacer()
                    }
                }
                .disabled(isTesting || baseURL.isEmpty)
            }
            if let msg = statusMessage {
                Section {
                    Text(msg)
                        .foregroundColor(isError ? .red : .green)
                        .font(.system(size: 13))
                }
            }
            if AppConfigStore.shared.token != nil {
                Section {
                    Button("退出登录（清除 Token）", role: .destructive) {
                        AppConfigStore.shared.clearToken()
                        statusMessage = "已退出登录"
                        isError = false
                    }
                }
            }
        }
        .navigationTitle("设置")
        .contentInset(EdgeInsets(top: 0, leading: 0, bottom: 120, trailing: 0))
        .onAppear(perform: load)
        .onChange(of: quality) { newQ in
            var cfg = AppConfigStore.shared.config
            cfg.defaultQuality = newQ
            AppConfigStore.shared.config = cfg
            PlayerManager.shared.quality = newQ
        }
        .onChange(of: autoSwitch) { newV in
            var cfg = AppConfigStore.shared.config
            cfg.autoSwitchSource = newV
            AppConfigStore.shared.config = cfg
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .font(.body.weight(.semibold))
            }
        }
    }

    private func load() {
        let cfg = AppConfigStore.shared.config
        baseURL = cfg.baseURL
        username = cfg.username
        password = cfg.password
        frontendPassword = cfg.frontendPassword
        playerPassword = cfg.playerPassword
        quality = cfg.defaultQuality
        autoSwitch = cfg.autoSwitchSource
    }

    private func save() {
        var cfg = AppConfigStore.shared.config
        cfg.baseURL = baseURL
        cfg.username = username
        cfg.password = password
        cfg.frontendPassword = frontendPassword
        cfg.playerPassword = playerPassword
        cfg.defaultQuality = quality
        cfg.autoSwitchSource = autoSwitch
        AppConfigStore.shared.config = cfg
        PlayerManager.shared.quality = quality
        statusMessage = "已保存"
        isError = false
        needsConfig = false
    }

    private func testConnection() async {
        isTesting = true
        statusMessage = nil
        save()
        do {
            _ = try await LXAPIClient.shared.login()
            await playlistStore.refresh()
            if playlistStore.errorMessage == nil {
                statusMessage = "连接成功，已获取歌单（\(playlistStore.playlists.count) 个）"
                isError = false
                needsConfig = false
            } else {
                statusMessage = "连接成功但获取歌单失败：\(playlistStore.errorMessage ?? "")"
                isError = true
            }
        } catch {
            statusMessage = "连接失败：\(error.localizedDescription)"
            isError = true
        }
        isTesting = false
    }
}
