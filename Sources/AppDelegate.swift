import UIKit
import AVFoundation

// @main 已移至 XmusicApp(SwiftUI App + WindowGroup,见 XmusicApp.swift)。
// 本类通过 @UIApplicationDelegateAdaptor 注入,仅负责音频会话配置。

final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Log.write("[AppDelegate] didFinishLaunchingWithOptions")
        configureAudioSession()
        return true
    }

    // CarPlay 车机是横屏(800×480 等),但 App 本体需要保持竖屏。
    // 这里按窗口所属场景区分:CarPlay 场景只允许横屏,手机上的普通场景仍锁竖屏。
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if let role = window?.windowScene?.session.role,
           role.rawValue == "UIWindowSceneSessionRoleCarPlay" {
            return .landscape
        }
        return .portrait
    }

    // CarPlay 音频 App 必须有 playback 类别 + 激活,否则车机不显示/无响应。
    // .allowBluetooth 只对 playAndRecord/record 有效,配 .playback 会抛 kAudioSessionUnspecifiedError。
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            NSLog("AppDelegate AVAudioSession configure error: \(error)")
        }
    }
}