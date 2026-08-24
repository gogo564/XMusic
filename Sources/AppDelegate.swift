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
        applyGlobalNightModeAppearance()
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

    /// 全局外观刷新：ThemeManager 切换深/浅后调用，让 appearance 级背景实时跟随。
    static func refreshGlobalAppearance() {
        let dark = ThemeManager.shared.isDark
        let black = UIColor.black
        let cellDark = UIColor(white: 0.06, alpha: 1)
        let table = UITableView.appearance()
        table.backgroundColor = dark ? black : nil
        table.separatorColor = dark ? UIColor(white: 1.0, alpha: 0.12) : nil
        UITableViewCell.appearance().backgroundColor = dark ? cellDark : nil
    }

    /// 强制整机 UI 的 TableView/Cell/背景为「纯黑月亮模式」。
    /// iOS 15 的 .insetGrouped List 在深色下只给深灰 #1C1C1E,不是纯黑;
    /// 这里统一用 appearance 碾压成 #000,页面任何系统组件都会跟随纯黑。
    /// 仅在 ThemeManager 判定深色时启用;亮色模式走系统默认。
    private func applyGlobalNightModeAppearance() {
        let dark = ThemeManager.shared.isDark
        let black = UIColor.black
        let cellDark = UIColor(white: 0.06, alpha: 1)
        // 全局 UITableView —— 覆盖所有 List(.plain/.insetGrouped)
        let table = UITableView.appearance()
        table.backgroundColor = dark ? black : nil
        table.separatorColor = dark ? UIColor(white: 1.0, alpha: 0.12) : nil
        if #available(iOS 15.0, *) {
            table.sectionHeaderTopPadding = 0
        }
        // Cell 背景:深色下近黑,保证选中/默认都不露白
        UITableViewCell.appearance().backgroundColor = dark ? cellDark : nil
        // 深色下所有无明确背景的 UI 视图兜底为黑,杜绝漏网白底
        if dark {
            UIView.appearance(whenContainedInInstancesOf: [UITableView.self]).backgroundColor = black
        }
    }

}