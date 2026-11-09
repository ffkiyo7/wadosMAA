//
//  AppPaths.swift
//  Wado's MAA
//
//  去沙盒后 `.documentDirectory` / `.applicationSupportDirectory` 会落到 `~/Documents`、
//  `~/Library/Application Support` 根目录。App 自己写的东西一律收进专属目录。
//

import Foundation

enum AppPaths {
    /// 固定的 bundle id，不随构建配置变化：App 的日志在它下面。
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

    /// App 自己的日志（`gui.log`）。
    static var debugDirectory: URL { directory("debug") }
}
