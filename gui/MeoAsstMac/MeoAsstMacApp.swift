//
//  MeoAsstMacApp.swift
//  MeoAsstMac
//
//  Created by hguandl on 8/10/2022.
//

import SwiftUI

@main
struct MeoAsstMacApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            // 自绘边栏 + 状态条 + 日志检查器；整个窗口一张背景图，侧栏和工具栏是系统的 Liquid Glass（K9）。
            RedesignRoot()
                .containerBackground(for: .window) {
                    WindowBackground()
                }
                .environment(RemoteStore.shared)
                .frame(minWidth: 900, minHeight: 600)
                .background(ScreenSafeWindow())
                // maa-remote 的状态文件一变就重读（K3）。
                .task { RemoteStore.shared.startWatching() }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开本场日志") {
                    if let url = AppLog.runLogURL(RemoteStore.shared.lastRun) { NSWorkspace.shared.open(url) }
                }
                .disabled(AppLog.runLogURL(RemoteStore.shared.lastRun) == nil)
                Button("在 Finder 中显示 App 日志") { AppLog.shared.revealInFinder() }
            }
            SidebarCommands()
        }
    }
}

/// 背景图一换（或填充方式一换），就把窗口缩放成「不露边的最大尺寸」（`WindowBackground.snugSize`）。
private struct ScreenSafeWindow: View {
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(AppearanceKeys.fill) private var fill = BackgroundFill.fill

    var body: some View {
        WindowProbe(wallpaper: "\(lightPath)|\(darkPath)|\(fill.rawValue)")
    }
}

/// 主窗口不伸到 Dock 和菜单栏下面。
/// 系统只挡标题栏越过菜单栏，拖底边 / 侧边照样能拉到 Dock 下面。所以开始拖边时，按拖的是哪条边，
/// 把 maxSize 设成「对边不动、这条边最远到当前屏幕 visibleFrame 的边」；松手还原。
/// 打开窗口、换屏时窗口比可用区还大，就缩进可用区。
/// 有背景图时，拖边拖到「不露边的最大尺寸」附近会吸过去；继续拖就照常放大。
private struct WindowProbe: NSViewRepresentable {
    let wallpaper: String

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.wallpaper = wallpaper
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        guard nsView.wallpaper != wallpaper else { return }
        nsView.wallpaper = wallpaper
        // 等新图先画上，再改窗口大小。
        DispatchQueue.main.async { nsView.fitToWallpaper() }
    }

    final class Probe: NSView {
        var wallpaper = ""
        private weak var observed: NSWindow?
        private var savedMaxSize: NSSize?
        /// 这次拖边的起点，和拖的是不是左边 / 底边（AppKit 坐标，原点在左下）。
        private var resizeStart: NSRect?
        private var draggingLeft = false
        private var draggingBottom = false
        /// 离不露边尺寸多近就吸过去（pt）。
        private let snapDistance: CGFloat = 24

        private var isDark: Bool {
            (window?.effectiveAppearance ?? NSApp.effectiveAppearance)
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private func snugSize(on screen: NSScreen) -> NSSize? {
            guard let window else { return nil }
            return WindowBackground.snugSize(
                in: screen.visibleFrame.size, minSize: window.minSize, isDark: isDark)
        }

        /// 换了背景图：窗口变成不露边的最大尺寸，左上角尽量不动，放不下就挪进可用区。
        func fitToWallpaper() {
            guard let window, let screen = window.screen,
                !window.styleMask.contains(.fullScreen),
                let size = snugSize(on: screen)
            else { return }
            let area = screen.visibleFrame
            var frame = window.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            window.setFrame(frame, display: true, animate: true)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            if let observed { center.removeObserver(self, name: nil, object: observed) }
            observed = window
            guard let window else { return }
            center.addObserver(
                self, selector: #selector(willStartLiveResize),
                name: NSWindow.willStartLiveResizeNotification, object: window)
            center.addObserver(
                self, selector: #selector(didEndLiveResize),
                name: NSWindow.didEndLiveResizeNotification, object: window)
            center.addObserver(
                self, selector: #selector(shrinkIntoScreen),
                name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(
                self, selector: #selector(didResize),
                name: NSWindow.didResizeNotification, object: window)
            center.addObserver(
                self, selector: #selector(saveFrame),
                name: NSWindow.didMoveNotification, object: window)
            // SwiftUI 设默认大小在这之后，下一轮再恢复上次的位置大小、再量。
            DispatchQueue.main.async { [weak self] in
                self?.restoreFrame()
                self?.shrinkIntoScreen()
            }
        }

        // MARK: 记住窗口位置大小
        // SwiftUI 自己存的 key 里带私有类型的地址（"unknown context at $…"），每次构建都变，换版本后就恢复不了。

        private static let frameKey = "MainWindowFrame"
        /// 恢复之前 SwiftUI 设默认大小也会发 didResize，那时不存，免得把上次的记录盖掉。
        private var frameRestored = false

        private func restoreFrame() {
            defer { frameRestored = true }
            guard let window, !window.styleMask.contains(.fullScreen),
                let saved = UserDefaults.standard.string(forKey: Self.frameKey)
            else { return }
            let frame = NSRectFromString(saved)
            // 记录的位置要还在某块屏幕上（外接屏拔了就不恢复位置），尺寸不能小于最小尺寸。
            guard frame.width >= window.minSize.width, frame.height >= window.minSize.height,
                NSScreen.screens.contains(where: { $0.visibleFrame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
            else { return }
            window.setFrame(frame, display: true)
        }

        @objc private func saveFrame() {
            guard frameRestored, let window, !window.styleMask.contains(.fullScreen) else { return }
            UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
        }

        @objc private func willStartLiveResize() {
            guard let window, let screen = window.screen,
                !window.styleMask.contains(.fullScreen)
            else { return }
            let area = screen.visibleFrame
            let frame = window.frame
            let mouse = NSEvent.mouseLocation
            // 鼠标离哪条边近，拖的就是哪条边；另一条边不动。
            draggingLeft = abs(mouse.x - frame.minX) < abs(mouse.x - frame.maxX)
            draggingBottom = abs(mouse.y - frame.minY) < abs(mouse.y - frame.maxY)
            resizeStart = frame
            let width = draggingLeft ? frame.maxX - area.minX : area.maxX - frame.minX
            let height = draggingBottom ? frame.maxY - area.minY : area.maxY - frame.minY
            savedMaxSize = window.maxSize
            window.maxSize = NSSize(
                width: max(width, window.minSize.width),
                height: max(height, window.minSize.height))
        }

        @objc private func didEndLiveResize() {
            resizeStart = nil
            guard let window, let savedMaxSize else { return }
            window.maxSize = savedMaxSize
            self.savedMaxSize = nil
        }

        /// 拖边时，宽 / 高各自离不露边尺寸够近就吸过去；只吸这次真在拖的那一维，对边不动。
        @objc private func didResize() {
            defer { saveFrame() }
            guard let window, window.inLiveResize, let start = resizeStart,
                let screen = window.screen, let snug = snugSize(on: screen)
            else { return }
            var frame = window.frame
            var snapped = false
            if frame.width != start.width, frame.width != snug.width,
                abs(frame.width - snug.width) < snapDistance
            {
                if draggingLeft { frame.origin.x = frame.maxX - snug.width }
                frame.size.width = snug.width
                snapped = true
            }
            if frame.height != start.height, frame.height != snug.height,
                abs(frame.height - snug.height) < snapDistance
            {
                if draggingBottom { frame.origin.y = frame.maxY - snug.height }
                frame.size.height = snug.height
                snapped = true
            }
            if snapped { window.setFrame(frame, display: true) }
        }

        @objc private func shrinkIntoScreen() {
            guard let window, let screen = window.screen,
                !window.styleMask.contains(.fullScreen)
            else { return }
            let area = screen.visibleFrame
            var frame = window.frame
            guard frame.width > area.width || frame.height > area.height else { return }
            frame.size.width = min(frame.width, area.width)
            frame.size.height = min(frame.height, area.height)
            frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}

private class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
