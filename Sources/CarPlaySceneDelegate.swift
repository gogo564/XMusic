import UIKit
import SwiftUI

// 参考 CarTube(TrollStore 上可行的 CarPlay app):不用 CPTemplateApplicationScene 模板系统
// (carplay-audio entitlement 是 Apple 审批的 managed capability,需要 provisioning profile,
//  TrollStore/ldid 注入的字符串只让图标出现,didConnect 后模板不被车机接受 -> 黑屏)。
// 改用 UIWindowSceneSessionRoleCarPlay + UIWindowSceneDelegate 在 CarPlay 窗口自绘 UI。

final class CarPlaySceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    private func log(_ message: String) {
        Log.write("[CarPlay] \(message)")
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        log("willConnectToSession role=\(session.role.rawValue)")
        guard let windowScene = scene as? UIWindowScene else {
            log("scene is not UIWindowScene")
            return
        }
        log("creating CarPlay window")
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: CarPlayRootView())
        self.window = window
        window.makeKeyAndVisible()
        log("CarPlay window shown, bounds=\(window.bounds)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        log("sceneDidBecomeActive role=\(scene.session.role.rawValue)")
    }

    func sceneWillResignActive(_ scene: UIScene) {
        log("sceneWillResignActive role=\(scene.session.role.rawValue)")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        log("sceneDidEnterBackground role=\(scene.session.role.rawValue)")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        log("sceneDidDisconnect role=\(scene.session.role.rawValue)")
    }
}