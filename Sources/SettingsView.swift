import SwiftUI
import SafariServices

struct SettingsView: View {
    @Binding var needsConfig: Bool
    @EnvironmentObject private var playlistStore: PlaylistStore

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
    @State private var sodaCookie = ""
    @State private var sodaHelios = ""
    @State private var sodaMedusa = ""
    @State private var sodaUpdating = false
    @State private var sodaUpdateMessage: String?

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
                    HStack {
                        Text("登录状态")
                        Spacer()
                        if sodaAuthLoading {
                            ProgressView()
                        } else if let status = sodaAuthStatus {
                            Text(status)
                                .font(.system(size: 13))
                                .foregroundColor(status.hasPrefix("✅") ? .green : .red)
                        }
                    }
                    Button {
                        checkSodaAuth()
                    } label: {
                        Label(sodaAuthStatus == nil ? "检测汽水登录状态" : "重新检测", systemImage: "arrow.clockwise")
                    }
                    DisclosureGroup("更新汽水登录签名（失效时粘贴新值）") {
                        TextField("Cookie（含 sessionid，抓包整段复制）", text: $sodaCookie)
                            .font(.system(size: 12))
                            .autocapitalization(.none)
                        TextField("X-Helios", text: $sodaHelios)
                            .font(.system(size: 12))
                            .autocapitalization(.none)
                        TextField("X-Medusa", text: $sodaMedusa)
                            .font(.system(size: 12))
                            .autocapitalization(.none)
                        Button {
                            updateSodaAuth()
                        } label: {
                            HStack {
                                if sodaUpdating { ProgressView().scaleEffect(0.7) }
                                Text(sodaUpdating ? "校验中…" : "校验并保存")
                            }
                        }
                        .disabled(sodaUpdating)
                        if let msg = sodaUpdateMessage {
                            Text(msg)
                                .font(.system(size: 12))
                                .foregroundColor(msg.hasPrefix("✅") ? .green : .red)
                        }
                    }
                }
            }
            Section(header: Text("播放")) {
                Picker("默认音质", selection: $quality) {
                    ForEach(qualities, id: \.self) { Text($0) }
                }
                Toggle("源失效自动切换", isOn: $autoSwitch)
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
            let result = (try? await SodaAPIClient.shared.authStatus())
                ?? SodaAPIClient.SodaAuthStatus(valid: false, nickname: "", message: "检测失败")
            sodaAuthStatus = result.valid
                ? "✅ 正常（\(result.nickname)）"
                : "⚠️ \(result.message)"
        }
    }

    private func updateSodaAuth() {
        guard !sodaBaseURL.isEmpty else {
            sodaUpdateMessage = "请先填写汽水服务地址"
            return
        }
        guard !sodaCookie.isEmpty || !sodaHelios.isEmpty || !sodaMedusa.isEmpty else {
            sodaUpdateMessage = "请至少粘贴 Cookie 或签名中的一项"
            return
        }
        sodaUpdating = true
        sodaUpdateMessage = nil
        Task {
            defer { sodaUpdating = false }
            let result = (try? await SodaAPIClient.shared.updateAuth(cookie: sodaCookie, helios: sodaHelios, medusa: sodaMedusa))
                ?? SodaAPIClient.SodaAuthStatus(valid: false, nickname: "", message: "更新失败")
            sodaUpdateMessage = result.valid ? "✅ \(result.message)" : "⚠️ \(result.message)"
            if result.valid {
                sodaCookie = ""
                sodaHelios = ""
                sodaMedusa = ""
                sodaAuthStatus = "✅ 正常（\(result.nickname)）"
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
