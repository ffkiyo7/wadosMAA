//
//  AppLog.swift
//  Wado's MAA
//
//  本 App 自己的运行日志：每条回执（成功或失败）都记一行，日志检查器的「App」一段显示它，
//  同时追加写进 `debug/gui.log`。
//

import AppKit
import Foundation
import Observation
import WadosMAAShared

@MainActor @Observable final class AppLog {
    static let shared = AppLog()

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let text: String
        let ok: Bool
    }

    /// 界面上最多留这么多条，文件里不删。
    static let limit = 500

    static var fileURL: URL { AppPaths.debugDirectory.appending(path: "gui.log") }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let handle: FileHandle?

    private init() {
        let url = Self.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func add(_ ok: Bool, _ text: String) {
        let entry = Entry(date: Date(), text: text, ok: ok)
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        let stamp = entry.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
        let line = "[\(stamp)][\(ok ? "info" : "error")]\(text.replacingOccurrences(of: "\n", with: " "))\n"  // copy-guard: ignore
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    /// 在 Finder 里选中 `gui.log`。
    func revealInFinder() {
        let url = Self.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    /// 最近一场的日志（`last_run.json` 的 `log`）；文件不在就是 nil。
    static func runLogURL(_ run: [String: JSONValue]) -> URL? {
        guard let path = run["log"]?.string, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
