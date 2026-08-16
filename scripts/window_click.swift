import CoreGraphics
import Foundation

// 用法: window_click <x> <y>
// 用 CGEvent 在全局坐标 (x,y) 发送一次鼠标点击。
// 不依赖辅助功能权限（CGEventPost 到 HID 层），相比 System Events click at 更可靠。
let args = CommandLine.arguments
guard args.count >= 3,
      let x = Double(args[1]),
      let y = Double(args[2]) else {
    print("usage: window_click <x> <y>")
    exit(2)
}

// 移动鼠标
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(80_000)

// 按下
let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
down?.post(tap: .cghidEventTap)
usleep(80_000)

// 松开
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
up?.post(tap: .cghidEventTap)

print("clicked \(x),\(y)")
