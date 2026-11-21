//
//  RunProgressFile.swift
//  WadosMAAShared
//
//  `runs/<场>.progress.json` 的纯解析（DEV_GUIDE §12.3）。日常和抄作业同一个文件格式：
//  Mac 从磁盘读，iOS 从 `/api/v1/snapshot` 和 SSE `progress` 事件拿。
//

import Foundation

/// 步骤条上的一格。
public struct RunProgressStep: Identifiable, Equatable, Sendable {
    public enum State: String, Sendable {
        case pending, running, done, failed, skipped
    }

    public let key: String
    public let label: String
    public var state: State
    public var startedAt: Date?
    public var finishedAt: Date?

    public var id: String { key }

    public init(key: String, label: String, state: State = .pending, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.key = key
        self.label = label
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// 比较只看 key、label、state：时间戳变化不算步骤条变了。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.label == rhs.label && lhs.state == rhs.state
    }
}

/// maa-remote 记下的恢复动作（重试、重启、摆窗、补跑……），给玩家看的原话。
public struct RunProgressNote: Identifiable, Equatable, Sendable {
    public let id: Int
    public let date: Date?
    public let text: String

    public init(id: Int, date: Date?, text: String) {
        self.id = id
        self.date = date
        self.text = text
    }
}

/// 抄作业这一批的进度（`copilot` 字段）。
public struct RunProgressCopilot: Equatable, Sendable {
    public let done: Int
    public let total: Int
    public let currentStage: String?
    public let currentMode: String?
    public let elapsedSeconds: Int?

    public init(done: Int, total: Int, currentStage: String?, currentMode: String?, elapsedSeconds: Int?) {
        self.done = done
        self.total = total
        self.currentStage = currentStage
        self.currentMode = currentMode
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct RunProgressFile: Equatable, Sendable {
    public let kind: String
    public let runId: String?
    public let status: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let steps: [RunProgressStep]
    /// 正在做的那一格，已换成界面用的 key。
    public let currentKey: String?
    public let fightsDone: Int
    public let fightEstimate: Int?
    public let sanity: Sanity?
    public let drops: [RunFightResult.Drop]
    public let notes: [RunProgressNote]
    public let eta: Date?
    public let copilot: RunProgressCopilot?

    public struct Sanity: Equatable, Sendable {
        public let current: Int
        public let max: Int

        public init(current: Int, max: Int) {
            self.current = current
            self.max = max
        }
    }

    /// 进度文件的步骤 key → 界面里一直用的 key。
    public static let fileKeys: [String: String] = [
        "startup": "StartUp", "annihilation": "Annihilation", "fight": "Fight", "infrast": "Infrast",
        "recruit": "Recruit", "mall": "Mall", "award": "Award",
    ]

    public static func doing(_ key: String, _ label: String) -> String {
        switch key {
        case "StartUp": "正在启动游戏"
        case "Annihilation": "正在打剿灭"
        case "Fight": "正在刷理智"
        case "Infrast": "正在基建换班"
        case "Recruit": "正在公开招募"
        case "Mall": "正在逛信用商店"
        case "Award": "正在领取奖励"
        default: "正在\(label)"
        }
    }

    public init?(data: Data) {
        guard case let .object(file)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.init(file: file)
    }

    public init(file: [String: JSONValue]) {
        kind = file["kind"]?.string ?? "daily"
        runId = file["run_id"]?.string
        status = file["status"]?.string
        startedAt = file["started_at"]?.string.flatMap(BeijingTime.parseISO)
        updatedAt = file["updated_at"]?.string.flatMap(BeijingTime.parseISO)
        steps = (file["steps"]?.array ?? []).compactMap { item in
            guard let object = item.object, let raw = object["key"]?.string else { return nil }
            let key = Self.fileKeys[raw] ?? raw
            return RunProgressStep(
                key: key,
                label: object["label"]?.string ?? key,
                state: RunProgressStep.State(rawValue: object["state"]?.string ?? "") ?? .pending,
                startedAt: object["started_at"]?.string.flatMap(BeijingTime.parseISO),
                finishedAt: object["finished_at"]?.string.flatMap(BeijingTime.parseISO))
        }
        currentKey = file["current"]?.string.map { Self.fileKeys[$0] ?? $0 }

        let fight = file["fight"]?.object ?? [:]
        fightsDone = Int(fight["done"]?.number ?? 0)
        fightEstimate = fight["estimate"]?.number.map { Int($0) }
        let sanityObject = fight["sanity"]?.object
        if let current = sanityObject?["current"]?.number, let max = sanityObject?["max"]?.number, max > 0 {
            sanity = Sanity(current: Int(current), max: Int(max))
        } else {
            sanity = nil
        }
        drops = RunFightResult.drops(fight)
        notes = (file["notes"]?.array ?? []).enumerated().compactMap { index, item in
            guard let object = item.object, let text = object["text"]?.string, !text.isEmpty else { return nil }
            return RunProgressNote(id: index, date: object["at"]?.string.flatMap(BeijingTime.parseISO), text: text)
        }
        eta = file["eta"]?.string.flatMap(BeijingTime.parseISO)
        if let object = file["copilot"]?.object {
            copilot = RunProgressCopilot(
                done: Int(object["done"]?.number ?? 0),
                total: Int(object["total"]?.number ?? 0),
                currentStage: object["current_stage"]?.string,
                currentMode: object["current_mode"]?.string,
                elapsedSeconds: object["elapsed_seconds"]?.number.map { Int($0) })
        } else {
            copilot = nil
        }
    }
}
