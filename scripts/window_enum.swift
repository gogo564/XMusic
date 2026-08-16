import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, owner == "Simulator" else { continue }
        let name = w[kCGWindowName as String] as? String ?? ""
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        let num = w[kCGWindowNumber as String] as? Int ?? 0
        if let b = w[kCGWindowBounds as String] as? [String: Any] {
            let x = b["X"] as? Double ?? 0
            let y = b["Y"] as? Double ?? 0
            let wd = b["Width"] as? Double ?? 0
            let ht = b["Height"] as? Double ?? 0
            print("name=\(name)|layer=\(layer)|id=\(num)|\(Int(x)),\(Int(y))|\(Int(wd)),\(Int(ht))")
        }
    }
}
