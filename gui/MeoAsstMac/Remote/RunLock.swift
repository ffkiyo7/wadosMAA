//
//  RunLock.swift
//  Wado's MAA
//
//  maa-remote 的 `run.lock`（DEV_GUIDE §12.2）：本 App 只读，看现在谁在用游戏。
//  调 maa-remote 的流程（`run local`、`copilot go`）时**不能**拿着它，那些子进程自己要抢这把锁。
//

import Darwin
import Foundation

struct LockHolder: Decodable, Sendable, Equatable {
    let holder: String
    let detail: String?
    let pid: Int?
    let since: String?

    /// 给人看的名字：「早场日常」「抄作业 SR-8」「更新游戏资源」。
    /// `daily` 的 detail 是 `maa_daily.PHASE_LABELS`（早 / 晚 / 手动）。
    var name: String {
        let detail = String((detail ?? "").prefix(30))
        switch holder {
        case "daily":
            switch detail {
            case "早": return "早场日常"
            case "晚": return "晚场日常"
            case "手动": return "手动日常"
            default: return "日常"
            }
        case "copilot": return detail.isEmpty ? "抄作业" : "抄作业 \(detail)"
        case "depot": return "清点仓库"
        case "update": return "更新游戏资源"
        default: return "另一个任务"
        }
    }

    /// 「早场日常（08:00 开始）」。
    var text: String {
        guard let since, let date = RunLock.parseISO(since) else { return name }
        return "\(name)（\(RunLock.beijingClock(date)) 开始）"
    }
}

enum RunLock {
    /// 现在谁占着；锁空着返回 nil。
    static func currentHolder() -> LockHolder? {
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

    // MARK: - 时间格式

    static let beijing = TimeZone(identifier: "Asia/Shanghai")!

    static func parseISO(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func beijingClock(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = beijing
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
