//
//  LockHolder.swift
//  WadosMAAShared
//
//  `run.lock` 里记的占用者（DEV_GUIDE §12.2）。
//

import Foundation

public struct LockHolder: Decodable, Sendable, Equatable {
    public let holder: String
    public let detail: String?
    public let pid: Int?
    public let since: String?
    /// 这一场的 `run_id`；停止时带上，防止停错场。旧版后端没有。
    public let runId: String?

    enum CodingKeys: String, CodingKey {
        case holder, detail, pid, since
        case runId = "run_id"
    }

    public init(holder: String, detail: String?, pid: Int?, since: String?, runId: String? = nil) {
        self.holder = holder
        self.detail = detail
        self.pid = pid
        self.since = since
        self.runId = runId
    }

    /// 给人看的名字：「早场日常」「抄作业 SR-8」「更新游戏资源」。
    /// `daily` 的 detail 是 `maa_daily.PHASE_LABELS`（早 / 晚 / 手动）。
    public var name: String {
        let detail = String((detail ?? "").prefix(30))
        switch holder {
        case "daily":
            switch detail {
            case "早": return "早场日常"
            case "晚": return "晚场日常"
            case "手动": return "手动日常"
            default: return "日常"
            }
        case "copilot": return detail.isEmpty ? "抄作业" : "抄作业 \(detail)"
        case "depot": return "清点仓库"
        case "update": return "更新游戏资源"
        default: return "另一个任务"
        }
    }

    /// 「早场日常（08:00 开始）」。
    public var text: String {
        guard let since, let date = BeijingTime.parseISO(since) else { return name }
        return "\(name)（\(BeijingTime.clock(date)) 开始）"
    }
}
