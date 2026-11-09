//
//  RunModels.swift
//  Wado's MAA
//
//  maa-remote 回给界面的几份列表：`run choices`（手动日常能刷哪关、能跳过哪些环节）、
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

    enum CodingKeys: String, CodingKey {
        case choices, switches, busy, blackout
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

    var id: String { stage }

    enum CodingKeys: String, CodingKey {
        case stage, code, nav, reason, status
        case statusText = "status_text"
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
