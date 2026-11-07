//
//  AppPaths.swift
//  Wado's MAA
//
//  去沙盒后 `.documentDirectory` / `.applicationSupportDirectory` 会落到 `~/Documents`、
//  `~/Library/Application Support` 根目录。App 自己写的东西一律收进专属目录。
//

import Foundation

enum AppPaths {
    /// 固定的 bundle id，不随构建配置变化：Core 的用户目录、GUI 日志、作业缓存都在它下面。
    static let bundleID = "io.github.ffkiyo7.MaaRemoteGui"

    /// `~/Library/Application Support/io.github.ffkiyo7.MaaRemoteGui/`，不存在就建。
    static let support: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: bundleID, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// 子目录，不存在就建。
    static func directory(_ name: String) -> URL {
        let url = support.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// MaaCore 的 `AsstSetUserDir`：`debug/`、`cache/` 写在这里，不和 maa-cli 的目录共用。
    static var coreUserDirectory: URL { support }

    /// GUI 自己的日志（`gui.log`）与 Core 的 `asst.log` 同在 `debug/`。
    static var debugDirectory: URL { directory("debug") }

    /// 用户导入的作业文件。
    static var copilotDirectory: URL { directory("copilot") }

    /// 用户导入的基建排班文件。
    static var infrastDirectory: URL { directory("infrast") }
}
