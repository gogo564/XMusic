import UIKit
import SwiftUI

// 主窗口（iPhone 屏幕）场景委托：承载 SwiftUI 界面。
// 配合 UIKit 生命周期使用，避免 SwiftUI @main 自动生成的主窗口
// scene configuration 与 CarPlay scene 争抢 foreground。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: XmusicApp())
        window.makeKeyAndVisible()
        self.window = window
    }
}