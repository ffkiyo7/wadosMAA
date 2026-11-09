//
//  RunModels.swift
//  Wado's MAA
//
//  maa-remote 回给界面的几份列表：`run choices`（手动日常能刷哪关、能跳过哪些环节）、
//  `plan today`（今天早场、晚场各打算做什么）、
//  `copilot stages` / `copilot preview`（能抄的关、某关的候选作业）。
//

import Foundation

// MARK: - 手动日常

struct RunChoices: Decodable, Sendable {
    struct Choice: Decodable, Sendable, Hashable {
        let label: String
        let stage: String
        let description: String
    }

    let choices: [Choice]
    let switches: [String]
    let taskNames: [String: String]
    let busy: String
    let blackout: String
    /// 此刻开放的活动；没有活动、或旧版 maa-remote 没有这个键时是 nil。
    let activity: Activity?

    /// `run choices` 的 `activity`（DEV_GUIDE §12）：名字、起止（北京时间 ISO）、首页前置的活动关。
    struct Activity: Decodable, Sendable, Hashable {
        let name: String
        let startAt: String
        let endAt: String
        let stages: [String]

        var start: Date? { Self.parse(startAt) }
        var end: Date? { Self.parse(endAt) }

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

struct TodayPlan: Decodable, Sendable {
    struct Drop: Decodable, Sendable, Hashable {
        let itemId: String
        let name: String
        let count: Int

        enum CodingKeys: String, CodingKey {
            case name, count
            case itemId = "item_id"
        }
    }

    struct Session: Decodable, Sendable, Identifiable {
        let phase: String
        let name: String
        let time: String
        let enabled: Bool
        let stage: String
        /// `auto`（按材料缺口自动定的）/ `discord`（手动选的，App 里选的也算）/ 空（默认关）。
        let stageSource: String
        let skip: Bool
        let tasks: [String: Bool]
        let drops: [Drop]
        let fallbackStage: String
        let choices: [RunChoices.Choice]

        var id: String { phase }
        var fight: Bool { tasks["fight"] ?? true }

        enum CodingKeys: String, CodingKey {
            case phase, name, time, enabled, stage, skip, tasks, drops, choices
            case stageSource = "stage_source"
            case fallbackStage = "fallback_stage"
        }
    }

    let date: String
    let sessions: [Session]
    let taskNames: [String: String]

    enum CodingKeys: String, CodingKey {
        case date, sessions
        case taskNames = "task_names"
    }
}

// MARK: - 自动抄作业

struct CopilotStageRow: Decodable, Sendable, Identifiable, Hashable {
    let stage: String
    let code: String?
    let nav: Bool?
    let reason: String?
    let status: String?
    let statusText: String?
    /// 本地记账里有通关记录（MAA 打赢的或手动标的），可以撤销。旧版 maa-remote 没有这个键。
    let ledgerCleared: Bool?

    var id: String { stage }

    enum CodingKeys: String, CodingKey {
        case stage, code, nav, reason, status
        case statusText = "status_text"
        case ledgerCleared = "ledger_cleared"
    }
}

struct CopilotStages: Decodable, Sendable {
    let stages: [CopilotStageRow]
    let inActivity: Bool

    enum CodingKeys: String, CodingKey {
        case stages
        case inActivity = "in_activity"
    }
}

struct CopilotCandidate: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let uploader: String?
    let ratio: Double?
    let gaps: [String]?
    let softGaps: [String]?
    let views: Int?
    let ratingRatio: Double?
    let perfect: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, ratio, gaps, views, perfect
        case softGaps = "soft_gaps"
        case ratingRatio = "rating_ratio"
    }
}

struct CopilotPreview: Decodable, Sendable {
    let token: String
    let stage: String
    let modes: [String]?
    let sanityCost: Int?
    let bestId: Int?
    let blocker: String?
    let expiresAt: String?
    let total: Int?
    let candidates: [CopilotCandidate]

    enum CodingKeys: String, CodingKey {
        case token, stage, modes, blocker, total, candidates
        case sanityCost = "sanity_cost"
        case bestId = "best_id"
        case expiresAt = "expires_at"
    }
}
