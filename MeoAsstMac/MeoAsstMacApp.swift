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
    @StateObject private var appViewModel: MAAViewModel
    @State private var newViewModel: NewViewModel

    init() {
        let viewModel = MAAViewModel()
        let newModel = NewViewModel(parent: viewModel)
        _appViewModel = StateObject(wrappedValue: viewModel)
        _newViewModel = State(wrappedValue: newModel)
        appDelegate.beforeTermination = {
            await newModel.waitLogStoreToFinish()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appViewModel)
                .environment(newViewModel)
                .environment(RemoteStore.shared)
                // 上游的「定时一键长草」（TaskTimerManager）不启动：调度只认 maa-remote 的 cron（K6 / K8）。
                .frame(minWidth: 900, minHeight: 600)
                .background(ScreenSafeWindow())
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenLogFileView()
            }
            SidebarCommands()
            TaskCommands(viewModel: appViewModel)
        }

        Settings {
            TabView {
                ConnectionSettingsView()
                    .tabItem {
                        Label("连接设置", systemImage: "rectangle.connected.to.line.below")
                    }

                GameSettingsView()
                    .tabItem {
                        Label("游戏设置", systemImage: "gamecontroller")
                    }

                SystemSettingsView()
                    .tabItem {
                        Label("系统设置", systemImage: "wrench.adjustable")
                    }

                AppearanceSettingsView()
                    .tabItem {
                        Label("外观", systemImage: "paintbrush")
                    }

                RemoteSettingsView()
                    .tabItem {
                        Label("maa-remote", systemImage: "point.3.connected.trianglepath.dotted")
                    }
            }
            .environmentObject(appViewModel)
            .frame(minWidth: 360, maxWidth: 520, minHeight: 240)
        }
    }
}

/// 主窗口不伸到 Dock 和菜单栏下面。
/// 系统只挡标题栏越过菜单栏，拖底边 / 侧边照样能拉到 Dock 下面。所以开始拖边时，按拖的是哪条边，
/// 把 maxSize 设成「对边不动、这条边最远到当前屏幕 visibleFrame 的边」；松手还原。
/// 打开窗口、换屏时窗口比可用区还大，就缩进可用区。
private struct ScreenSafeWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private weak var observed: NSWindow?
        private var savedMaxSize: NSSize?

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
            // 窗口恢复上次的大小在这之后，下一轮再量。
            DispatchQueue.main.async { [weak self] in self?.shrinkIntoScreen() }
        }

        @objc private func willStartLiveResize() {
            guard let window, let screen = window.screen,
                !window.styleMask.contains(.fullScreen)
            else { return }
            let area = screen.visibleFrame
            let frame = window.frame
            let mouse = NSEvent.mouseLocation
            // 鼠标离哪条边近，拖的就是哪条边；另一条边不动。
            let width =
                abs(mouse.x - frame.minX) < abs(mouse.x - frame.maxX)
                ? frame.maxX - area.minX : area.maxX - frame.minX
            let height =
                abs(mouse.y - frame.minY) < abs(mouse.y - frame.maxY)
                ? frame.maxY - area.minY : area.maxY - frame.minY
            savedMaxSize = window.maxSize
            window.maxSize = NSSize(
                width: max(width, window.minSize.width),
                height: max(height, window.minSize.height))
        }

        @objc private func didEndLiveResize() {
            guard let window, let savedMaxSize else { return }
            window.maxSize = savedMaxSize
            self.savedMaxSize = nil
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
    fileprivate var beforeTermination: (() async -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let beforeTermination else { return .terminateNow }
        if terminationTask != nil { return .terminateLater }

        terminationTask = Task {
            await beforeTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
