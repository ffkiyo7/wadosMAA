//
//  RemoteGate.swift
//  Wado's MAA
//
//  GUI 进程内的上游手动功能（自动战斗、肉鸽、识别等）开跑前的闸门（S3）：
//
//  1. 进程里的 MaaCore 还是盘上那份（maa-cli 没换过 Core）；
//  2. 定时场优先：离开着的场次不足 `manual_run_blackout_minutes` 就拒，30 秒内再点一次算确认；
//  3. `upstream status`（离线）：更新正在跑、源被改了、上次更新不自洽都拒；不新鲜只提醒；
//  4. 抢 `run.lock`（持有者 gui）。
//
//  maa-remote 自己的流程（`run local`、`copilot go`）不走这里：它们在子进程里自己过闸门、抢锁。
//

import Foundation

struct UpstreamStatus: Decodable, Sendable {
    struct Versions: Decodable, Sendable {
        let maaCli: String?
        let maaCore: String?
        let maaCoreRecorded: String?
        let resourceLastUpdated: String?
        let maaResourceHead: String?
        let betaCoreLatest: String?
        let betaCoreCheckedAt: String?
    }

    struct Check: Decodable, Sendable {
        let ok: Bool
        let problems: [String]?
        let reason: String?
    }

    struct Lock: Decodable, Sendable {
        let held: Bool
        let text: String?
    }

    struct Online: Decodable, Sendable {
        let maaCliLatest: String?
        let maaResourceRemoteHead: String?
        let maaCliOutdated: Bool?
        let maaResourceOutdated: Bool?
        let errors: [String]?
    }

    let verdict: String
    let blockReason: String?
    let running: Bool
    let fresh: Bool
    let lastSuccessAt: String?
    let gameDayStart: String?
    let updateBlocked: String?
    let versions: Versions
    let pinned: Check
    let consistent: Check
    let lock: Lock
    let online: Online?
}

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
    /// 最近一次 `upstream status` 的结果，状态面板（S5）也读它。
    static private(set) var lastStatus: UpstreamStatus?
    static private(set) var lastStatusError: String?

    private static var blackoutWarnedAt: Date?
    static let confirmWindow: TimeInterval = 30

    /// 离线查一次上游状态（< 2 秒）。
    @discardableResult
    static func refreshStatus(online: Bool = false) async -> UpstreamStatus? {
        do {
            let receipt = try await RemoteBridge.run(
                online ? ["upstream", "status", "--online"] : ["upstream", "status"],
                timeout: online ? 40 : 20)
            let status = try receipt.decode(UpstreamStatus.self)
            lastStatus = status
            lastStatusError = nil
            return status
        } catch {
            lastStatusError = error.localizedDescription
            return nil
        }
    }

    /// 进程里的 Core 已经不是盘上那份：上游功能整体停用，等重启。
    static func coreMismatch(_ status: UpstreamStatus?) -> String? {
        if CorePreflight.coreReplacedOnDisk {
            return "MaaCore 已被 maa-cli 换过（或正在更新），重启 Wado's MAA 后再用上游功能"
        }
        if let loaded = CorePreflight.loadedVersion, let disk = status?.versions.maaCore, !disk.isEmpty,
            loaded != disk
        {
            return "进程里的 MaaCore 是 \(loaded)，盘上已是 \(disk)：重启 Wado's MAA 后再用上游功能"
        }
        return nil
    }

    /// 上游功能开跑前调：通过就持有 `run.lock` 并返回要提醒的话；不通过抛 `RemoteGateError`。
    static func prepareUpstreamRun(detail: String, at now: Date = Date()) async throws -> [String] {
        var warnings: [String] = []
        if let reason = coreMismatch(nil) { throw RemoteGateError.refused(reason) }

        let sessions = SessionGate.load()
        if let slot = sessions.upcoming(within: sessions.blackoutMinutes, at: now) {
            if let warned = blackoutWarnedAt, now.timeIntervalSince(warned) <= confirmWindow {
                blackoutWarnedAt = nil
                warnings.append("已确认在\(slot.label)前强行开跑")
            } else {
                blackoutWarnedAt = now
                throw RemoteGateError.refused(
                    "距\(slot.label) 不足 \(sessions.blackoutMinutes) 分钟，定时场优先。"
                        + "确实要跑，\(Int(confirmWindow)) 秒内再点一次开始。")
            }
        }

        if let status = await refreshStatus() {
            if status.running { throw RemoteGateError.refused("上游更新正在跑，等它跑完再开") }
            if status.verdict == "blocked" {
                throw RemoteGateError.refused("上游状态不对：\(status.blockReason ?? "未知原因")")
            }
            if let reason = coreMismatch(status) { throw RemoteGateError.refused(reason) }
            if !status.fresh {
                warnings.append("本游戏日还没成功更新过 maa-cli / MaaCore / 资源，按现有版本继续")
            }
        } else {
            warnings.append("查不到上游状态（\(lastStatusError ?? "未知错误")），按现有版本继续")
        }

        if let holder = RunLock.shared.acquire(detail: detail) {
            throw RemoteGateError.refused("\(holder.text)正在用游戏，等它跑完再开")
        }
        return warnings
    }

    /// 回到空闲时放锁。
    static func finishUpstreamRun() {
        RunLock.shared.release()
    }

    // MARK: - 启动检查

    /// App 启动时（加载资源之前）：查上游；不新鲜且闸门放行就先更新，更新完再继续（spike §6(b)）。
    /// 返回 `(级别, 话)`，由调用方写进日志。
    static func startupCheck(log: (String, Bool) -> Void) async {
        guard let status = await refreshStatus() else {
            log("查不到上游状态：\(lastStatusError ?? "未知错误")", true)
            return
        }
        let versions = status.versions
        log("maa-cli \(versions.maaCli ?? "未知") · MaaCore \(versions.maaCore ?? "未知") · "
            + "MaaResource \(versions.maaResourceHead.map { String($0.prefix(8)) } ?? "未知")", false)
        if status.verdict == "blocked" {
            log("上游状态不对：\(status.blockReason ?? "未知原因")。日常和上游功能都会被挡住", true)
            return
        }
        guard !status.fresh, !status.running else { return }
        if let blocked = status.updateBlocked, !blocked.isEmpty {
            log("本游戏日还没成功更新过，但现在不更新：\(blocked)", true)
            return
        }
        log("本游戏日还没成功更新过，先更新 maa-cli / MaaCore / 资源…", false)
        do {
            let receipt = try await RemoteBridge.run(["upstream", "update"])
            guard receipt.ok else {
                log(receipt.message, true)
                return
            }
        } catch {
            log(error.localizedDescription, true)
            return
        }
        let final = await waitForUpdate()
        if let last = final, last.fresh {
            log("上游更新完成", false)
        } else {
            log("上游更新没成功，按现有版本继续", true)
        }
        if let reason = coreMismatch(final) { log(reason, true) }
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
