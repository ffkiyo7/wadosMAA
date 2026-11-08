// winmove <pid> <x> <y> — 把进程 pid 的第一个窗口挪到全局坐标 (x, y)（左上角原点，点）。
// winmove --front <pid>  — 把进程 pid 设为前台 App（AX `kAXFrontmostAttribute`）。
//
// 给 maa_playcover.settle_game_window() 用：PlayCover 每次拉起明日方舟都把窗口开在
// 当前活动的那块屏上，不会回到 MAA-Game 虚拟屏。`--front` 用来「切走再切回」：游戏已是
// 前台却被台前调度收进侧边栏时，激活它什么也不会发生，先把访达设成前台再激活游戏
// （2026-11-08 spike）。用 AX 而不是 `open -b com.apple.finder`：后者在访达没窗口时会
// 新开一个窗口，可能正好开在 MAA-Game 上把游戏挤走。
// 走辅助功能（AX）接口，需要调用方（Hermes gateway 的 Python）有「辅助功能」权限；
// 没有就退出码 3，不弹任何东西。
//
// 退出码：0 成功；1 参数错；2 找不到窗口；3 没有辅助功能权限；4 设置失败。

import ApplicationServices
import Foundation

let args = CommandLine.arguments

func usage() -> Never {
    FileHandle.standardError.write("usage: winmove <pid> <x> <y> | winmove --front <pid>\n".data(using: .utf8)!)
    exit(1)
}

if args.count == 3 && args[1] == "--front" {
    guard let pid = pid_t(args[2]) else { usage() }
    guard AXIsProcessTrusted() else {
        print("not trusted")
        exit(3)
    }
    let app = AXUIElementCreateApplication(pid)
    let result = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if result != .success {
        print("set frontmost failed: \(result.rawValue)")
        exit(4)
    }
    print("front")
    exit(0)
}

guard args.count == 4, let pid = pid_t(args[1]), let x = Double(args[2]), let y = Double(args[3]) else {
    usage()
}
guard AXIsProcessTrusted() else {
    print("not trusted")
    exit(3)
}
let app = AXUIElementCreateApplication(pid)
var value: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
      let windows = value as? [AXUIElement], let window = windows.first else {
    print("no window")
    exit(2)
}
var point = CGPoint(x: x, y: y)
guard let axPoint = AXValueCreate(.cgPoint, &point) else { exit(4) }
let result = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axPoint)
if result != .success {
    print("set position failed: \(result.rawValue)")
    exit(4)
}
print("moved")
