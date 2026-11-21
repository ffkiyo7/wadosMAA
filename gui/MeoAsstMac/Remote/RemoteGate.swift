//
//  RemoteGate.swift
//  Wado's MAA
//
//  `upstream status` 的结果（首页「游戏资源」卡片），和「定时场优先」要用的场次时间（`SessionGate`）。
//  更新只在用户点了首页的「现在更新」时才跑，App 启动时不自动更新。
//
//  会动游戏的流程（`run local`、`copilot go`、`upstream update`）都在 maa-remote 的子进程里自己过闸门、
//  抢 `run.lock`；本 App 不持锁。
//

import Foundation
import WadosMAAShared

enum RemoteGateError: LocalizedError {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case let .refused(reason): return reason
        }
    }
}

/// `config.json` 里闸门要用的几项。读不到就按默认（早 08:00 / 晚 22:00、30 分钟）。
struct SessionGate: Sendable {
    struct Slot: Sendable {
        let phase: String
        let hour: Int
        let minute: Int
        let enabled: Bool

        var label: String { "\(phase == "am" ? "早场" : "晚场") \(String(format: "%02d:%02d", hour, minute))" }
    }

    let slots: [Slot]
    let blackoutMinutes: Int

    static func load() -> SessionGate {
        let object = (try? Data(contentsOf: RemoteConfig.configFile))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let schedule = object["session_schedule"] as? [String: Any] ?? [:]
        let defaults = ["am": "08:00", "pm": "22:00"]
        let slots = ["am", "pm"].compactMap { phase -> Slot? in
            let raw = schedule[phase] as? [String: Any] ?? [:]
            let time = raw["time"] as? String ?? defaults[phase]!
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return Slot(phase: phase, hour: parts[0], minute: parts[1], enabled: raw["enabled"] as? Bool ?? true)
        }
        let minutes = object["manual_run_blackout_minutes"] as? Int ?? 30
        return SessionGate(slots: slots, blackoutMinutes: max(0, minutes))
    }

    /// `minutes` 分钟内要开跑的那场；和 `maa_common.session_within()` 同一个算法（北京时间）。
    func upcoming(within minutes: Int, at now: Date = Date()) -> Slot? {
        guard minutes > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RunLock.beijing
        var best: (Slot, Date)?
        for slot in slots where slot.enabled {
            guard var target = calendar.date(bySettingHour: slot.hour, minute: slot.minute, second: 0, of: now)
            else { continue }
            if now > target { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target }
            if best == nil || target < best!.1 { best = (slot, target) }
        }
        guard let (slot, target) = best, target.timeIntervalSince(now) / 60 <= Double(minutes) else { return nil }
        return slot
    }
}

@MainActor enum RemoteGate {
    /// 查一次上游状态：离线 < 2 秒；`online` 时还查有没有新版本。
    @discardableResult
    static func refreshStatus(online: Bool = false) async -> UpstreamStatus? {
        do {
            let receipt = try await RemoteBridge.run(
                online ? ["upstream", "status", "--online"] : ["upstream", "status"],
                timeout: online ? 40 : 20)
            return try receipt.decode(UpstreamStatus.self)
        } catch {
            return nil
        }
    }

    /// 每 2 秒轮询一次，直到更新不再跑（上限 20 分钟）。
    static func waitForUpdate(limit: TimeInterval = 20 * 60) async -> UpstreamStatus? {
        let deadline = Date().addingTimeInterval(limit)
        var status: UpstreamStatus?
        repeat {
            try? await Task.sleep(for: .seconds(2))
            status = await refreshStatus()
        } while (status?.running ?? false) && Date() < deadline
        return status
    }
}
