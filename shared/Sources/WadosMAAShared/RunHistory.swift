//
//  RunHistory.swift
//  WadosMAAShared
//
//  场次索引 `runs/index.jsonl` 的一行（DEV_GUIDE §12.3，不变量 #66）。读文件的事留给各端。
//

import Foundation

/// 索引里的一场。
public struct RunRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let phase: String
    public let stage: String
    public let status: String
    public let failure: String
    public let skipReason: String
    public let startedAt: Date?
    public let finishedAt: Date?
    public let durationSeconds: Int?
    /// 这一场的进度文件（`runs/<场>.progress.json`）；旧行或抄作业没有。
    public let progressPath: String?
    /// 抄作业这一轮通过几关、一共几关；日常和旧行没有。
    public let won: Int?
    public let total: Int?

    public var isCopilot: Bool { phase.hasPrefix("copilot-") }

    public init(
        id: String, phase: String, stage: String, status: String, failure: String, skipReason: String,
        startedAt: Date?, finishedAt: Date?, durationSeconds: Int?, progressPath: String?,
        won: Int? = nil, total: Int? = nil
    ) {
        self.won = won
        self.total = total
        self.id = id
        self.phase = phase
        self.stage = stage
        self.status = status
        self.failure = failure
        self.skipReason = skipReason
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.progressPath = progressPath
    }

    /// 读索引的一行；缺关键字段或版本更高就返回 nil。
    public init?(row: [String: JSONValue]) {
        if let version = row["schema_version"]?.number, Int(version) > RunHistory.knownSchemaVersion { return nil }
        guard let id = row["id"]?.string, let phase = row["phase"]?.string, let status = row["status"]?.string
        else { return nil }
        self.init(
            id: id,
            phase: phase,
            stage: row["stage"]?.string ?? "",
            status: status,
            failure: row["failure"]?.string ?? "",
            skipReason: row["skip_reason"]?.string ?? "",
            startedAt: row["started_at"]?.string.flatMap(BeijingTime.parseISO),
            finishedAt: row["finished_at"]?.string.flatMap(BeijingTime.parseISO),
            durationSeconds: row["duration_seconds"]?.number.map { Int($0) },
            progressPath: row["progress"]?.string,
            won: row["won"]?.number.map { Int($0) },
            total: row["total"]?.number.map { Int($0) })
    }

    /// 结束时刻：有 `finished_at` 用它，没有就按耗时推。
    public var endedAt: Date? {
        finishedAt ?? startedAt.flatMap { start in durationSeconds.map { start.addingTimeInterval(TimeInterval($0)) } }
    }

    /// 「早场日常 · 1-7」。
    public var title: String {
        let kind = LastRunText.kind(phase: phase)
        return kind + (stage.isEmpty ? "" : " · \(stage)")
    }

    /// 没成功 / 跳过的原因。
    public var reason: String {
        switch status {
        case "failed": RunHistory.failureText[failure] ?? ""
        case "skipped": RunHistory.skipText[skipReason] ?? ""
        default: ""
        }
    }
}

/// 一场的刷理智结果（DEV_GUIDE §12.3 `fight.done` / `fight.drops`）。
public struct RunFightResult: Equatable, Sendable {
    public struct Drop: Equatable, Sendable, Hashable {
        public let name: String
        public let count: Int

        public init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    public let done: Int
    public let drops: [Drop]

    public init(done: Int, drops: [Drop]) {
        self.done = done
        self.drops = drops
    }

    /// `fight.drops`：`[{name, count}]`，按文件里的顺序。
    public static func drops(_ fight: [String: JSONValue]) -> [Drop] {
        (fight["drops"]?.array ?? []).compactMap { item in
            guard let object = item.object, let name = object["name"]?.string, !name.isEmpty,
                let count = object["count"]?.number
            else { return nil }
            return Drop(name: name, count: Int(count))
        }
    }
}

public enum RunHistory {
    public static let knownSchemaVersion = 1

    public static let failureText: [String: String] = [
        "startup": "游戏没打开",
        "upstream": "游戏资源状态不对，没有开始",
        "offline": "游戏一直没登录上",
        "game_exited": "游戏中途退出了，没能接着跑完",
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

    public static let skipText: [String: String] = [
        "plan": "今天设成了跳过",
        "game_busy": "你在玩，没去抢游戏",
    ]

    /// 解析 `index.jsonl` 全文，最新的在前；读不懂的行（写到一半、更高版本）跳过。
    public static func parse(_ data: Data) -> [RunRecord] {
        var rows: [RunRecord] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard case let .object(row)? = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                let record = RunRecord(row: row)
            else { continue }
            rows.append(record)
        }
        return rows.reversed()
    }

    /// 「23 分钟」「1 小时 5 分钟」「不到 1 分钟」。
    public static func durationText(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded())
        if seconds < 60 { return "不到 1 分钟" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "\(minutes) 分钟"
    }
}
