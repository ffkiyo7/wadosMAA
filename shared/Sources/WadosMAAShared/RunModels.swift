//
//  RunModels.swift
//  WadosMAAShared
//
//  maa-remote 回给界面的几份列表：手动日常选项、今日计划、抄作业关卡与候选。
//

import Foundation

// MARK: - 手动日常

public struct RunChoices: Decodable, Sendable {
    public struct Choice: Decodable, Sendable, Hashable {
        public let label: String
        public let stage: String
        public let description: String
    }

    public let choices: [Choice]
    public let switches: [String]
    public let taskNames: [String: String]
    public let busy: String
    public let blackout: String
    /// 此刻开放的活动；没有活动、或旧版 maa-remote 没有这个键时是 nil。
    public let activity: Activity?

    /// `run choices` 的 `activity`（DEV_GUIDE §12）：名字、起止（北京时间 ISO）、首页前置的活动关。
    public struct Activity: Decodable, Sendable, Hashable {
        public let name: String
        public let startAt: String
        public let endAt: String
        public let stages: [String]

        public var start: Date? { Self.parse(startAt) }
        public var end: Date? { Self.parse(endAt) }

        private static func parse(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        enum CodingKeys: String, CodingKey {
            case name, stages
            case startAt = "start_at"
            case endAt = "end_at"
        }
    }

    enum CodingKeys: String, CodingKey {
        case choices, switches, busy, blackout, activity
        case taskNames = "task_names"
    }
}

// MARK: - 今天两场的计划（`plan today`，DEV_GUIDE §12.1）

public struct TodayPlan: Decodable, Sendable {
    public struct Drop: Decodable, Sendable, Hashable {
        public let itemId: String
        public let name: String
        public let count: Int

        enum CodingKeys: String, CodingKey {
            case name, count
            case itemId = "item_id"
        }
    }

    public struct Session: Decodable, Sendable, Identifiable {
        public let phase: String
        public let name: String
        public let time: String
        public let enabled: Bool
        public let stage: String
        /// `auto`（按材料缺口自动定的）/ `discord`（手动选的，App 里选的也算）/ 空（默认关）。
        public let stageSource: String
        public let skip: Bool
        public let tasks: [String: Bool]
        public let drops: [Drop]
        public let fallbackStage: String
        public let choices: [RunChoices.Choice]

        public var id: String { phase }
        public var fight: Bool { tasks["fight"] ?? true }

        enum CodingKeys: String, CodingKey {
            case phase, name, time, enabled, stage, skip, tasks, drops, choices
            case stageSource = "stage_source"
            case fallbackStage = "fallback_stage"
        }
    }

    public let date: String
    public let sessions: [Session]
    public let taskNames: [String: String]

    enum CodingKeys: String, CodingKey {
        case date, sessions
        case taskNames = "task_names"
    }
}

// MARK: - 自动抄作业

public struct CopilotStageRow: Decodable, Sendable, Identifiable, Hashable {
    public let stage: String
    public let code: String?
    public let nav: Bool?
    public let reason: String?
    public let status: String?
    public let statusText: String?
    /// 本地记账里有通关记录（MAA 打赢的或手动标的），可以撤销。旧版 maa-remote 没有这个键。
    public let ledgerCleared: Bool?
    /// `normal` / `ex` / `s`。旧版 maa-remote 没有这个键，用 `stageCategory` 读。
    public let category: String?

    public var id: String { stage }

    /// 优先用后端给的分组，缺失时按关卡名判断（和 `maa_copilot.stage_category` 同一规则）。
    public var stageCategory: String {
        if let category, ["normal", "ex", "s"].contains(category) { return category }
        let parts = stage.uppercased().split(separator: "-")
        guard parts.count == 3 else { return "normal" }
        switch parts[1] {
        case "EX": return "ex"
        case "S": return "s"
        default: return "normal"
        }
    }

    enum CodingKeys: String, CodingKey {
        case stage, code, nav, reason, status, category
        case statusText = "status_text"
        case ledgerCleared = "ledger_cleared"
    }
}

public struct CopilotStages: Decodable, Sendable {
    public let stages: [CopilotStageRow]
    public let inActivity: Bool

    enum CodingKeys: String, CodingKey {
        case stages
        case inActivity = "in_activity"
    }
}

public struct CopilotCandidate: Decodable, Sendable, Identifiable, Hashable {
    public let id: Int
    public let title: String?
    public let uploader: String?
    public let ratio: Double?
    public let gaps: [String]?
    public let softGaps: [String]?
    public let views: Int?
    public let ratingRatio: Double?
    public let perfect: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, ratio, gaps, views, perfect
        case softGaps = "soft_gaps"
        case ratingRatio = "rating_ratio"
    }
}

public struct CopilotPreview: Decodable, Sendable {
    public let token: String
    public let stage: String
    public let modes: [String]?
    public let sanityCost: Int?
    public let bestId: Int?
    public let blocker: String?
    public let expiresAt: String?
    public let total: Int?
    public let candidates: [CopilotCandidate]

    enum CodingKeys: String, CodingKey {
        case token, stage, modes, blocker, total, candidates
        case sanityCost = "sanity_cost"
        case bestId = "best_id"
        case expiresAt = "expires_at"
    }
}
