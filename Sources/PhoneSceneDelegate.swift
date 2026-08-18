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
        Log.write("[Phone] willConnectToSession role=\(session.role.rawValue)")
        guard let windowScene = scene as? UIWindowScene else {
            Log.write("[Phone] scene is not UIWindowScene")
            return
        }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: makeRootView())
        self.window = window
        window.makeKeyAndVisible()
        Log.write("[Phone] window shown bounds=\(window.bounds)")
    }
}