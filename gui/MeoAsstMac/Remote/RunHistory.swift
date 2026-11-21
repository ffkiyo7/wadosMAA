//
//  RunHistory.swift
//  Wado's MAA
//
//  场次索引：读 `$HERMES_HOME/state/maa/runs/index.jsonl`（DEV_GUIDE §12.3，不变量 #66）。
//  maa-remote 每场结束往里追加一行，GUI 只读不写。读不懂的行（写到一半、更高版本）跳过。
//

import Foundation

/// 索引里的一场。
struct RunRecord: Identifiable, Equatable, Sendable {
    let id: String
    let phase: String
    let stage: String
    let status: String
    let failure: String
    let skipReason: String
    let startedAt: Date?
    let finishedAt: Date?
    let durationSeconds: Int?
    /// 这一场的进度文件（`runs/<场>.progress.json`）；旧行或抄作业没有。
    let progressPath: String?

    /// 结束时刻：有 `finished_at` 用它，没有就按耗时推。
    var endedAt: Date? {
        finishedAt ?? startedAt.flatMap { start in durationSeconds.map { start.addingTimeInterval(TimeInterval($0)) } }
    }

    /// 「早场日常 · 1-7」。
    var title: String {
        let kind = LastRunText.kind(phase: phase)
        return kind + (stage.isEmpty ? "" : " · \(stage)")
    }

    /// 没成功 / 跳过的原因。
    var reason: String {
        switch status {
        case "failed": RunHistory.failureText[failure] ?? ""
        case "skipped": RunHistory.skipText[skipReason] ?? ""
        default: ""
        }
    }
}

/// 一场的刷理智结果：读那一场的进度文件（DEV_GUIDE §12.3 `fight.done` / `fight.drops`）。
/// 首页场卡、近况热力格的气泡用；文件不在、读不懂、开始时刻对不上（同名旧场）都当没有。
struct RunFightResult: Equatable, Sendable {
    struct Drop: Equatable, Sendable, Hashable {
        let name: String
        let count: Int
    }

    let done: Int
    let drops: [Drop]

    /// 路径 → (修改时间, 结果)。界面每次重画都会问，文件没变就不重读。
    @MainActor private static var cache: [String: (Date, RunFightResult?)] = [:]

    @MainActor static func read(_ path: String?, started: Date?) -> RunFightResult? {
        guard let path, !path.isEmpty,
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let key = path + "|" + (started.map { String($0.timeIntervalSince1970) } ?? "")
        if let hit = cache[key], hit.0 == modified { return hit.1 }
        let result = parse(URL(fileURLWithPath: path), started: started)
        cache[key] = (modified, result)
        return result
    }

    private static func parse(_ url: URL, started: Date?) -> RunFightResult? {
        guard let data = try? Data(contentsOf: url),
            case let .object(file)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            let fight = file["fight"]?.object
        else { return nil }
        if let version = file["schema_version"]?.number, Int(version) > RunHistory.knownSchemaVersion { return nil }
        if let started, let fileStart = file["started_at"]?.string.flatMap(RunLock.parseISO),
            abs(fileStart.timeIntervalSince(started)) > 2
        {
            return nil
        }
        return RunFightResult(done: Int(fight["done"]?.number ?? 0), drops: drops(fight))
    }

    /// `fight.drops`：`[{name, count}]`，按文件里的顺序。
    static func drops(_ fight: [String: JSONValue]) -> [Drop] {
        (fight["drops"]?.array ?? []).compactMap { item in
            guard let object = item.object, let name = object["name"]?.string, !name.isEmpty,
                let count = object["count"]?.number
            else { return nil }
            return Drop(name: name, count: Int(count))
        }
    }
}

enum RunHistory {
    static let knownSchemaVersion = 1

    static var file: URL { RemoteConfig.stateDirectory.appending(path: "runs/index.jsonl") }

    static let failureText: [String: String] = [
        "startup": "游戏没打开",
        "upstream": "游戏资源状态不对，没有开始",
        "offline": "游戏一直没登录上",
        "screen_lost": "游戏画面一直拿不到",
        "timeout": "超时了",
        "proxy": "代理指挥失误，一关没打成",
        "task_failed": "有的事没做完",
        "not_home": "最后没回到游戏主页",
        "cleanup": "关游戏时出了问题",
        "inventory": "掉落没记进仓库",
        "prefight": "开打前出了问题",
        "stopped": "中途停下了",
        "stage_failed": "有的关没打过",
    ]

    static let skipText: [String: String] = [
        "plan": "今天设成了跳过",
        "game_busy": "你在玩，没去抢游戏",
    ]

    /// 最新的在前。文件不在、读不了就是空。
    static func read() -> [RunRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        var rows: [RunRecord] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard case let .object(row)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else {
                continue
            }
            if let version = row["schema_version"]?.number, Int(version) > knownSchemaVersion { continue }
            guard let id = row["id"]?.string, let phase = row["phase"]?.string,
                let status = row["status"]?.string
            else { continue }
            rows.append(RunRecord(
                id: id,
                phase: phase,
                stage: row["stage"]?.string ?? "",
                status: status,
                failure: row["failure"]?.string ?? "",
                skipReason: row["skip_reason"]?.string ?? "",
                startedAt: row["started_at"]?.string.flatMap(RunLock.parseISO),
                finishedAt: row["finished_at"]?.string.flatMap(RunLock.parseISO),
                durationSeconds: row["duration_seconds"]?.number.map { Int($0) },
                progressPath: row["progress"]?.string))
        }
        return rows.reversed()
    }

    /// 「23 分钟」「1 小时 5 分钟」「不到 1 分钟」。
    static func durationText(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if seconds < 60 { return "不到 1 分钟" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}
