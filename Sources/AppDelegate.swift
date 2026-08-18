import UIKit
import AVFoundation

// @main 入口使用 UIApplicationDelegate 生命周期(参考音流/flutter_carplay 与
// vanities/carplay-swiftui:纯 SwiftUI @main App 生命周期下 CarPlay 模板场景
// 可能不被车机正常接受)。
// 通过 application(_:configurationForConnecting:) 按角色显式返回场景配置,
// 与 Info.plist 的 UIApplicationSceneManifest 双保险。

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

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
        switch connectingSceneSession.role {
        case UISceneSessionRole.carPlay:
            let config = UISceneConfiguration(
                name: "CarPlayConfiguration",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        default:
            let config = UISceneConfiguration(
                name: "PhoneConfiguration",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = PhoneSceneDelegate.self
            return config
        }
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