import CoreGraphics
import Foundation

// 用法: window_scroll <x> <y> [lines]
// 在全局坐标 (x,y) 处发送滚轮事件（模拟向下滚动列表到底部）。
// lines 默认 -20（一次滚动量），负值代表向下滚动内容。
// 发送到桌面/Simulator 窗口之上。
let args = CommandLine.arguments
guard args.count >= 3,
      let x = Double(args[1]),
      let y = Double(args[2]) else {
    print("usage: window_scroll <x> <y> [lines]")
    exit(2)
}
let lines = Int32(args.count > 3 ? args[3] : "-20")!

// 先把鼠标移到滚动位置（保证滚轮事件落在目标窗口上）
let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
move?.post(tap: .cghidEventTap)
usleep(80_000)

// 发送滚轮事件（line 滚动，1 轴）
if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
    ev.location = CGPoint(x: x, y: y)
    ev.post(tap: .cghidEventTap)
}
usleep(80_000)

print("scrolled \(lines) lines at \(x),\(y)")