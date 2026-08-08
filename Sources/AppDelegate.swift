import UIKit
import AVFoundation
import SwiftUI

// AppDelegate 由 XmusicApp 通过 @UIApplicationDelegateAdaptor 注入。
// 纯 SwiftUI 生命周期下 CarPlay scene 经常连不上（didConnect 不触发 -> 黑屏），
// 这里显式返回 CarPlay 场景配置，确保 CarPlaySceneDelegate 被正确实例化。

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == UISceneSession.Role.carTemplateApplication {
            let config = UISceneConfiguration(
                name: "CarPlayConfiguration",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        // 其余场景（窗口/主 UI）交给 SwiftUI 生命周期管理
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }

    // CarPlay 音频 App 必须有 playback 类别 + 激活，否则车机不显示/无响应
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            NSLog("AppDelegate AVAudioSession configure error: \(error)")
        }
    }
}
