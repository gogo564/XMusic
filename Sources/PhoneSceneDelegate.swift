import UIKit
import SwiftUI

// 手机 UIWindowScene 的 SceneDelegate,把 SwiftUI 根视图包进 UIHostingController。
// Info.plist 中 UIWindowSceneSessionRoleApplication 显式指向本类(参考音流/汽水/vanities)。

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: makeRootView())
        self.window = window
        window.makeKeyAndVisible()
    }
}