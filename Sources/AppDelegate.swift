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