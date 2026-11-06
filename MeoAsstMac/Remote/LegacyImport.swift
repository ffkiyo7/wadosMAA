//
//  LegacyImport.swift
//  Wado's MAA
//
//  K10：官方 MAA.app 的配置目录先保留。第一次启动时问一次要不要导入之前的任务配置。
//  读别的 App 的容器会触发系统的「访问其他 App 的数据」授权，所以只在用户点了「导入」之后才去读，
//  启动时只看容器目录本身在不在。
//

import SwiftUI

enum LegacyImport {
    static let decidedKey = "LegacyImportDecided"

    private static var container: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.hguandl.MeoAsstMac", directoryHint: .isDirectory)
    }

    private static var legacyTasksDirectory: URL {
        container.appending(path: "Data/Library/Application Support/DailyTasks", directoryHint: .isDirectory)
    }

    /// 还没问过，且官方 App 的容器还在。
    static var shouldAsk: Bool {
        !UserDefaults.standard.bool(forKey: decidedKey)
            && FileManager.default.fileExists(atPath: container.path)
    }

    static func markDecided() {
        UserDefaults.standard.set(true, forKey: decidedKey)
    }

    /// 把官方 App 的 `DailyTasks/*.plist` 拷到本 App 的同名目录（同名文件覆盖），返回拷了几份。
    static func importTasks(into destination: URL) throws -> Int {
        let files = try FileManager.default.contentsOfDirectory(
            at: legacyTasksDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "plist" }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for file in files {
            try FileManager.default.copyItemOverwriting(
                at: file, to: destination.appending(path: file.lastPathComponent))
        }
        return files.count
    }
}

struct LegacyImportPrompt: ViewModifier {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear { isPresented = LegacyImport.shouldAsk }
            .alert("导入官方 MAA 的任务配置？", isPresented: $isPresented) {
                Button("导入") {
                    LegacyImport.markDecided()
                    do {
                        let count = try LegacyImport.importTasks(into: viewModel.tasksDirectory)
                        viewModel.reloadTasksFromDisk()
                        viewModel.logInfo(verbatim: "已导入 \(count) 份任务配置")
                    } catch {
                        viewModel.logError(verbatim: "导入失败: \(error.localizedDescription)")
                    }
                }
                Button("不导入", role: .cancel) {
                    LegacyImport.markDecided()
                }
            } message: {
                Text("检测到官方 MAA.app 留下的配置目录。导入只复制上游任务列表（肉鸽等），日常配置以 maa-remote 为准。系统可能会请求「访问其他 App 的数据」的授权。")
            }
    }
}
