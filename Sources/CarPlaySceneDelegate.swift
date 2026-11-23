import UIKit
import SwiftUI

// 参考 CarTube(TrollStore 上可行的 CarPlay app):不用 CPTemplateApplicationScene 模板系统
// (carplay-audio entitlement 是 Apple 审批的 managed capability,需要 provisioning profile,
//  TrollStore/ldid 注入的字符串只让图标出现,didConnect 后模板不被车机接受 -> 黑屏)。
// 改用 UIWindowSceneSessionRoleCarPlay + UIWindowSceneDelegate 在 CarPlay 窗口自绘 UI。

final class CarPlayHostingController<Content: View>: UIHostingController<Content> {
    // 车机窗口不需要 iOS 状态栏(否则会出现 18:41 / 4G 图标占据画面)
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
}

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
        window.overrideUserInterfaceStyle = .dark
        window.backgroundColor = .black
        window.rootViewController = CarPlayHostingController(rootView: CarPlayRootView())
        self.window = window
        window.makeKeyAndVisible()

        // 车机屏幕是横屏,但 App 的 Info.plist 只声明了竖屏,系统会把 480×800 的画面
        // 旋转 90° 塞进 800×480 的车机屏(表现为所有文字侧躺)。
        // iOS 16+ 主动请求横屏几何更新,把窗口变成真正的 800×480。
        if #available(iOS 16.0, *) {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                self.log("requestGeometryUpdate error=\(error.localizedDescription)")
            }
        }
        log("CarPlay window shown, bounds=\(window.bounds), scene=\(windowScene.coordinateSpace.bounds), orient=\(windowScene.interfaceOrientation.rawValue)")
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