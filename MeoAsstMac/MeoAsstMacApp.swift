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
        }
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
            }
            .environmentObject(appViewModel)
            .frame(maxWidth: 360, minHeight: 240)
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
