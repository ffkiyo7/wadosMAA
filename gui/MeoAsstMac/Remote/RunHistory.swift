//
//  RunHistory.swift
//  Wado's MAA
//
//  最近几场：读 `$HERMES_HOME/state/maa/runs/index.jsonl`（DEV_GUIDE §12.3，不变量 #66）。
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
    let durationSeconds: Int?

    /// 「早场日常 · 1-7」。
    var title: String {
        let kind = LastRunText.kind(phase: phase)
        return kind + (stage.isEmpty ? "" : " · \(stage)")
    }

    /// 没成功 / 跳过的原因，给悬停提示用。
    var reason: String {
        switch status {
        case "failed": RunHistory.failureText[failure] ?? ""
        case "skipped": RunHistory.skipText[skipReason] ?? ""
        default: ""
        }
    }
}

enum RunHistory {
    static let knownSchemaVersion = 1
    /// 首页列几场。
    static let shown = 6
    /// 成功率看最近多少场。
    static let rateWindow = 30

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
                durationSeconds: row["duration_seconds"]?.number.map { Int($0) }))
        }
        return rows.reversed()
    }

    /// 最近 `rateWindow` 场里成功了几场：只算成功和没成功的，跳过和停下的不算。一场都没有就是 nil。
    static func successRate(_ rows: [RunRecord]) -> (ok: Int, total: Int)? {
        let counted = rows.filter { $0.status == "success" || $0.status == "failed" }.prefix(rateWindow)
        guard !counted.isEmpty else { return nil }
        return (counted.filter { $0.status == "success" }.count, counted.count)
    }

    /// 「23 分钟」「1 小时 5 分钟」「不到 1 分钟」。
    static func durationText(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if seconds < 60 { return "不到 1 分钟" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}
