//
//  RunLock.swift
//  Wado's MAA
//
//  maa-remote 的 `run.lock`（DEV_GUIDE §12.2）：本 App 只读，看现在谁在用游戏。
//  调 maa-remote 的流程（`run local`、`copilot go`）时**不能**拿着它，那些子进程自己要抢这把锁。
//

import Darwin
import Foundation
import WadosMAAShared

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

    static var beijing: TimeZone { BeijingTime.zone }

    static func parseISO(_ text: String) -> Date? { BeijingTime.parseISO(text) }

    static func beijingClock(_ date: Date) -> String { BeijingTime.clock(date) }
}
