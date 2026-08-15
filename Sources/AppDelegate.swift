import UIKit
import AVFoundation
import SwiftUI

// CarPlay 音频 app 必须使用 UIKit 生命周期（@main AppDelegate + SceneDelegate），
// 纯 SwiftUI @main + WindowGroup 生命周期会自动生成主窗口 scene configuration，
// 与 CarPlay scene 争抢 foreground，导致 CarPlay scene 激活后几毫秒就被切回后台
// （sceneDidBecomeActive -> sceneWillResignActive -> sceneDidEnterBackground -> 黑屏）。
// 切到 UIKit 生命周期后：CarPlay 场景交给 CarPlaySceneDelegate，
// 主窗口场景交给 SceneDelegate（承载 SwiftUI 界面）。

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

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
        // 其余场景（主窗口）交给 SceneDelegate，它承载 SwiftUI 界面
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
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
