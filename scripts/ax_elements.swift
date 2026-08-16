import ApplicationServices
import Foundation

// 用法: ax_elements <pid_或_app名>
// 遍历指定进程(默认 Simulator)的 AX 树，输出所有按钮/图标的标题与坐标。
// 用于定位 CarPlay 主屏窗口内真实的 app 图标按钮坐标（替代盲猜像素）。
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Simulator"

func element(_ el: AXUIElement, _ attr: String) -> AnyObject? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    guard err == .success else { return nil }
    return value as AnyObject?
}

func attributeString(_ el: AXUIElement, _ attr: String) -> String {
    return (element(el, attr) as? String) ?? ""
}

func walk(_ el: AXUIElement, _ depth: Int, _ path: String) {
    if depth > 12 { return }
    let role = attributeString(el, kAXRoleAttribute)
    let title = attributeString(el, kAXTitleAttribute)
    let desc = attributeString(el, kAXDescriptionAttribute)
    var pos = ""
    if let p = element(el, kAXPositionAttribute) {
        let pt = p as! AXValue
        var point = CGPoint.zero
        AXValueGetValue(pt, .cgPoint, &point)
        pos = String(format: "%.0f,%.0f", point.x, point.y)
    }
    var size = ""
    if let s = element(el, kAXSizeAttribute) {
        let sv = s as! AXValue
        var sz = CGSize.zero
        AXValueGetValue(sv, .cgSize, &sz)
        size = String(format: "%.0fx%.0f", sz.width, sz.height)
    }
    if role == kAXButtonRole || role == kAXImageRole || role == kAXCellRole {
        print("\(path) role=\(role) title=\(title) desc=\(desc) pos=\(pos) size=\(size)")
    }
    if let children = element(el, kAXChildrenAttribute) as? [AXUIElement] {
        var i = 0
        for child in children {
            walk(child, depth + 1, "\(path)/\(i)")
            i += 1
        }
    }
}

// 查找进程
func pidFor(_ name: String) -> pid_t? {
    let apps = NSWorkspace.shared.runningApplications
    for app in apps where app.localizedName == name || app.bundleIdentifier?.contains(name) == true {
        return app.processIdentifier
    }
    return nil
}

guard let pid = pidFor(target) else {
    print("no process: \(target)")
    exit(1)
}
print("pid=\(pid)")
let app = AXUIElementCreateApplication(pid)
walk(app, 0, "app")
print("=== done ===")