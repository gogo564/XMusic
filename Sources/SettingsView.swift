import SwiftUI
import SafariServices

struct SettingsView: View {
    @Binding var needsConfig: Bool
    @EnvironmentObject private var playlistStore: PlaylistStore
    @ObservedObject private var theme = ThemeManager.shared

    @State private var showQRLogin = false

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var frontendPassword = ""
    @State private var playerPassword = ""
    @State private var quality = "128k"
    @State private var autoSwitch = true
    @State private var sodaBaseURL = ""
    @State private var isTesting = false
    @State private var statusMessage: String?
    @State private var isError = false
    @State private var sodaAuthStatus: String?
    @State private var sodaAuthLoading = false
    @State private var sodaPlayCookie = ""
    @State private var sodaPlayHelios = ""
    @State private var sodaPlayMedusa = ""
    @State private var sodaPlayUpdating = false
    @State private var sodaPlayMessage: String?
    @State private var sodaPlaylistAuthStatus: String?
    @State private var sodaPlaylistCookie = ""
    @State private var sodaPlaylistUpdating = false
    @State private var sodaPlaylistMessage: String?

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
            Section(header: Text("汽水音乐服务")) {
                TextField("汽水服务地址（如 http://192.168.1.85:3310）", text: $sodaBaseURL)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                Text("清空则隐藏汽水源；推荐/电台/播放均通过该服务。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !sodaBaseURL.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("播放账号（会员）")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            if sodaAuthLoading {
                                ProgressView()
                            } else if let status = sodaAuthStatus {
                                Text(status)
                                    .font(.system(size: 12))
                                    .foregroundColor(status.hasPrefix("✅") ? .green : .red)
                            }
                        }
                        Button {
                            checkSodaAuth()
                        } label: {
                            Label(sodaAuthStatus == nil ? "检测播放账号" : "重新检测播放账号", systemImage: "arrow.clockwise")
                        }
                        DisclosureGroup("更新播放账号签名（失效时粘贴新值）") {
                            TextField("Cookie（含 sessionid，抓包整段复制）", text: $sodaPlayCookie)
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                            TextField("X-Helios", text: $sodaPlayHelios)
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                            TextField("X-Medusa", text: $sodaPlayMedusa)
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                            Button {
                                updateSodaAuth(role: "play")
                            } label: {
                                HStack {
                                    if sodaPlayUpdating { ProgressView().scaleEffect(0.7) }
                                    Text(sodaPlayUpdating ? "校验中…" : "校验并保存")
                                }
                            }
                            .disabled(sodaPlayUpdating)
                            if let msg = sodaPlayMessage {
                                Text(msg)
                                    .font(.system(size: 12))
                                    .foregroundColor(msg.hasPrefix("✅") ? .green : .red)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("歌单账号（展示/收藏）")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            if let status = sodaPlaylistAuthStatus {
                                Text(status)
                                    .font(.system(size: 12))
                                    .foregroundColor(status.hasPrefix("✅") ? .green : .red)
                            }
                        }
                        Button {
                            checkSodaPlaylistAuth()
                        } label: {
                            Label(sodaPlaylistAuthStatus == nil ? "检测歌单账号" : "重新检测歌单账号", systemImage: "arrow.clockwise")
                        }
                        DisclosureGroup("更新歌单账号签名（失效时粘贴新值）") {
                            TextField("Cookie（含 sessionid，抓包整段复制）", text: $sodaPlaylistCookie)
                                .font(.system(size: 12))
                                .autocapitalization(.none)
                            Button {
                                updateSodaAuth(role: "playlist")
                            } label: {
                                HStack {
                                    if sodaPlaylistUpdating { ProgressView().scaleEffect(0.7) }
                                    Text(sodaPlaylistUpdating ? "校验中…" : "校验并保存")
                                }
                            }
                            .disabled(sodaPlaylistUpdating)
                            if let msg = sodaPlaylistMessage {
                                Text(msg)
                                    .font(.system(size: 12))
                                    .foregroundColor(msg.hasPrefix("✅") ? .green : .red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section(header: Text("播放")) {
                Picker("默认音质", selection: $quality) {
                    ForEach(qualities, id: \.self) { Text($0) }
                }
                Toggle("源失效自动切换", isOn: $autoSwitch)
            }
            Section(header: Text("外观")) {
                Picker("模式", selection: $theme.mode) {
                    ForEach(ThemeMode.allCases) { m in
                        Text(m.name).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: theme.mode) { _ in
                    theme.updateForSystemAppearance()
                }
                HStack {
                    Text("主题色")
                    Spacer()
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ThemeColor.allCases) { c in
                                Button {
                                    theme.color = c
                                } label: {
                                    Circle()
                                        .fill(c.color)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Circle()
                                                .stroke(theme.color == c ? Color.accentColor : Color.clear, lineWidth: 2.5)
                                                .padding(-3)
                                        )
                                        .overlay(
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white)
                                                .opacity(theme.color == c ? 1 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(c.name)
                            }
                        }
                    }
                }
            }
            Section(header: Text("QQ 音乐账号")) {
                Button {
                    showQRLogin = true
                } label: {
                    HStack {
                        Label("扫码更换 QQ 音乐账号", systemImage: "qrcode")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Text("用手机 QQ 扫描二维码登录后立即生效，原账号将被替换。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
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
        .sheet(isPresented: $showQRLogin) {
            SafariView(url: URL(string: "http://gogo564.x3322.net:8081/login/tx")!)
        }
        .navigationTitle("设置")
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 120)
                .allowsHitTesting(false)
        }
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
        sodaBaseURL = cfg.sodaBaseURL
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
        cfg.sodaBaseURL = sodaBaseURL
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

    private func checkSodaAuth() {
        guard !sodaBaseURL.isEmpty else { return }
        sodaAuthLoading = true
        sodaAuthStatus = nil
        Task {
            defer { sodaAuthLoading = false }
            let result = (try? await SodaAPIClient.shared.authStatus(role: "play"))
                ?? SodaAPIClient.SodaAuthStatus(valid: false, nickname: "", message: "检测失败")
            sodaAuthStatus = result.valid
                ? "✅ 正常（\(result.nickname)）"
                : "⚠️ \(result.message)"
        }
    }

    private func checkSodaPlaylistAuth() {
        guard !sodaBaseURL.isEmpty else { return }
        sodaPlaylistAuthStatus = nil
        Task {
            let result = (try? await SodaAPIClient.shared.authStatus(role: "playlist"))
                ?? SodaAPIClient.SodaAuthStatus(valid: false, nickname: "", message: "检测失败")
            sodaPlaylistAuthStatus = result.valid
                ? "✅ 正常（\(result.nickname)）"
                : "⚠️ \(result.message)"
        }
    }

    private func updateSodaAuth(role: String) {
        guard !sodaBaseURL.isEmpty else {
            if role == "play" {
                sodaPlayMessage = "请先填写汽水服务地址"
            } else {
                sodaPlaylistMessage = "请先填写汽水服务地址"
            }
            return
        }
        let cookie: String
        let helios: String
        let medusa: String
        switch role {
        case "playlist":
            cookie = sodaPlaylistCookie
            helios = ""
            medusa = ""
        default:
            cookie = sodaPlayCookie
            helios = sodaPlayHelios
            medusa = sodaPlayMedusa
        }
        guard !cookie.isEmpty || !helios.isEmpty || !medusa.isEmpty else {
            if role == "play" {
                sodaPlayMessage = "请至少粘贴 Cookie 或签名中的一项"
            } else {
                sodaPlaylistMessage = "请至少粘贴 Cookie"
            }
            return
        }
        if role == "play" {
            sodaPlayUpdating = true
            sodaPlayMessage = nil
        } else {
            sodaPlaylistUpdating = true
            sodaPlaylistMessage = nil
        }
        Task {
            let result = (try? await SodaAPIClient.shared.updateAuth(role: role, cookie: cookie, helios: helios, medusa: medusa))
                ?? SodaAPIClient.SodaAuthStatus(valid: false, nickname: "", message: "更新失败")
            let text = result.valid ? "✅ \(result.message)" : "⚠️ \(result.message)"
            if role == "play" {
                sodaPlayUpdating = false
                sodaPlayMessage = text
                if result.valid {
                    sodaPlayCookie = ""
                    sodaPlayHelios = ""
                    sodaPlayMedusa = ""
                    sodaAuthStatus = "✅ 正常（\(result.nickname)）"
                }
            } else {
                sodaPlaylistUpdating = false
                sodaPlaylistMessage = text
                if result.valid {
                    sodaPlaylistCookie = ""
                    sodaPlaylistAuthStatus = "✅ 正常（\(result.nickname)）"
                }
            }
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
