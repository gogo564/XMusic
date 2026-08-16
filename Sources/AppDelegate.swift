import UIKit
import AVFoundation

// AppDelegate 由 XmusicApp 通过 @UIApplicationDelegateAdaptor 注入。
// CarPlay 场景配置完全走 Info.plist 的 UIApplicationSceneManifest（与成功案例
// RadioCarPlay 一致：纯 SwiftUI @main + Info.plist，不实现 configurationForConnecting）。
// 这里只保留全局一次性的音频会话配置。

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        configureAudioSession()
        return true
    }

    // CarPlay 音频 App 必须有 playback 类别 + 激活，否则车机不显示/无响应。
    // .allowBluetooth 只对 playAndRecord/record 有效，配 .playback 会抛 kAudioSessionUnspecifiedError。
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
