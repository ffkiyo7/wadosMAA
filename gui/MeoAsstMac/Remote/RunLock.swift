//
//  RunLock.swift
//  Wado's MAA
//
//  maa-remote 的 `run.lock`（DEV_GUIDE §12.2）。GUI 在进程内用上游功能动游戏之前抢它，
//  回到空闲就放。抢到后写持有者标记 `{"holder": "gui", …}`，定时场被挡住时 Discord 上
//  会说「Wado's MAA 正在用」（K15）。
//
//  注意：GUI 调 maa-remote 的流程（`run local`、`copilot go`）时**不能**拿着它，
//  那些子进程自己要抢这把锁。
//

import Darwin
import Foundation

struct LockHolder: Decodable, Sendable, Equatable {
    let holder: String
    let detail: String?
    let pid: Int?
    let since: String?

    static let labels = [
        "daily": "日常", "copilot": "抄作业", "depot": "仓库对表", "update": "上游更新", "gui": "Wado's MAA",
    ]

    /// 「日常·早场（自 08:00）」，和 `maa_common.lock_holder_text()` 一个说法。
    var text: String {
        var label = Self.labels[holder] ?? (holder.isEmpty ? "另一个任务" : String(holder.prefix(20)))
        if let detail, !detail.isEmpty {
            label += "·\(detail.prefix(30))"
        }
        if let since, let date = RunLock.parseISO(since) {
            label += "（自 \(RunLock.beijingClock(date))）"
        }
        return label
    }
}

@MainActor final class RunLock {
    static let shared = RunLock()

    private var descriptor: Int32 = -1

    var isHeld: Bool { descriptor >= 0 }

    /// 非阻塞地抢。抢到返回 nil；被占着返回占着的人（读不懂标记时是一个匿名持有者）。
    func acquire(detail: String) -> LockHolder? {
        if isHeld { return nil }
        let url = RemoteConfig.runLockFile
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return LockHolder(holder: "", detail: "打不开 \(url.path)", pid: nil, since: nil)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return Self.currentHolder() ?? LockHolder(holder: "", detail: nil, pid: nil, since: nil)
        }
        descriptor = fd
        let marker: [String: Any] = [
            "holder": "gui",
            "detail": detail,
            "pid": Int(getpid()),
            "since": Self.isoBeijing(Date()),
        ]
        if var data = try? JSONSerialization.data(withJSONObject: marker) {
            data.append(0x0A)
            ftruncate(fd, 0)
            _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        }
        return nil
    }

    /// 清掉标记再放锁。进程退出时内核也会放锁，但标记会留下（标记只在锁被占时可信）。
    func release() {
        guard isHeld else { return }
        ftruncate(descriptor, 0)
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    /// 现在谁占着；锁空着返回 nil。自己占着时也能读到（另开的 fd 抢不到）。
    nonisolated static func currentHolder() -> LockHolder? {
        let path = RemoteConfig.runLockFile.path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            let first = text.split(separator: "\n").first,
            let holder = try? JSONDecoder().decode(LockHolder.self, from: Data(first.utf8))
        else {
            return LockHolder(holder: "", detail: nil, pid: nil, since: nil)
        }
        return holder
    }

    // MARK: - 时间格式（Python 3.9 的 fromisoformat 不认 Z，统一写 +08:00）

    nonisolated static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    nonisolated static func isoBeijing(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = beijing
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    nonisolated static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    nonisolated static func beijingClock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
