//
//  ConfigModels.swift
//  WadosMAAShared
//
//  配置、默认项和时间表的数据形状（DEV_GUIDE §12）。
//

import Foundation

public struct ConfigField: Decodable, Identifiable, Sendable {
    public let key: String
    public let group: String
    public let label: String
    public let kind: String
    public let `default`: JSONValue?
    public let min: Double?
    public let max: Double?
    public let help: String?

    public var id: String { key }
}

public struct ChangeMeta: Decodable, Sendable, Equatable {
    public let source: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case source
        case updatedAt = "updated_at"
    }

    public init(source: String?, updatedAt: String?) {
        self.source = source
        self.updatedAt = updatedAt
    }

    /// 「由 Wado's MAA 于 11-06 14:03 改」。
    public var text: String {
        let who: String
        switch source {
        case "gui": who = "Wado's MAA"
        case "ios": who = "Wado's MAA (iOS)"
        case "discord": who = "Discord"
        default: who = source ?? "未知"
        }
        guard let updatedAt, let date = BeijingTime.parseISO(updatedAt) else { return "由 \(who) 改" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BeijingTime.zone
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "由 %@ 于 %02d-%02d %@ 改", who, parts.month ?? 0, parts.day ?? 0,
                      BeijingTime.clock(date))
    }
}

public struct ConfigSnapshot: Decodable, Sendable {
    public let groups: [String]
    public let fields: [ConfigField]
    public let values: [String: JSONValue]
    public let meta: [String: ChangeMeta]
}

public struct DefaultsSnapshot: Decodable, Sendable {
    public let stage: String?
    public let tasks: [String: Bool]?
    public let source: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case stage, tasks, source
        case updatedAt = "updated_at"
    }

    public var meta: ChangeMeta? {
        guard let source, !source.isEmpty else { return nil }
        return ChangeMeta(source: source, updatedAt: updatedAt)
    }
}

public struct ScheduleReport: Decodable, Sendable {
    public struct CronJob: Decodable, Sendable {
        public let id: String
        public let expr: String
        public let expectedExpr: String
        public let enabled: Bool
        public let inSync: Bool
        public let nextRunAt: String?
        public let lastStatus: String?

        enum CodingKeys: String, CodingKey {
            case id, expr, enabled
            case expectedExpr = "expected_expr"
            case inSync = "in_sync"
            case nextRunAt = "next_run_at"
            case lastStatus = "last_status"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            expr = try c.decodeIfPresent(String.self, forKey: .expr) ?? ""
            expectedExpr = try c.decodeIfPresent(String.self, forKey: .expectedExpr) ?? expr
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            inSync = try c.decodeIfPresent(Bool.self, forKey: .inSync) ?? true
            nextRunAt = try c.decodeIfPresent(String.self, forKey: .nextRunAt)
            lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
        }
    }

    public struct ScheduledJob: Decodable, Sendable {
        public let id: String
        public let enabled: Bool
        public let nextRunAt: String?
        public let lastRunAt: String?
        public let lastStatus: String?
        public let lastDetail: String?

        enum CodingKeys: String, CodingKey {
            case id, enabled
            case nextRunAt = "next_run_at"
            case lastRunAt = "last_run_at"
            case lastStatus = "last_status"
            case lastDetail = "last_detail"
        }
    }

    public struct Session: Decodable, Sendable {
        public let time: String
        public let enabled: Bool
        public let planCardTime: String?
        public let dailyTime: String?
        public let cron: [String: CronJob]

        enum CodingKeys: String, CodingKey {
            case time, enabled, cron
            case planCardTime = "plan_card_time"
            case dailyTime = "daily_time"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            time = try c.decode(String.self, forKey: .time)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            planCardTime = try c.decodeIfPresent(String.self, forKey: .planCardTime)
            dailyTime = try c.decodeIfPresent(String.self, forKey: .dailyTime)
            cron = try c.decodeIfPresent([String: CronJob].self, forKey: .cron) ?? [:]
        }
    }

    public let backend: String?
    public let timezone: String
    public let depotEnabled: Bool?
    public let schedulerPath: String?
    public let jobsPath: String?
    public let sessions: [String: Session]
    public let jobs: [String: ScheduledJob]?

    public var displayPath: String {
        schedulerPath ?? jobsPath ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case backend, timezone, sessions, jobs
        case depotEnabled = "depot_enabled"
        case schedulerPath = "scheduler_path"
        case jobsPath = "jobs_path"
    }
}
