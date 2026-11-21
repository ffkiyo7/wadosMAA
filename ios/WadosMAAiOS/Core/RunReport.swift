//
//  RunReport.swift
//  Wado's MAA (iOS)
//
//  `/api/v1/runs/<id>/report`：抄作业是结构化战报，日常是 Discord Embed 原文。
//  字段缺了就少显示一块，不让整页失败。
//

import Foundation
import WadosMAAShared

struct RunReport: Equatable, Sendable {
    struct StageResult: Identifiable, Equatable, Sendable {
        let id: Int
        let stage: String
        let mode: String
        let outcome: String
        let detail: String
        let startedAt: Date?
        let finishedAt: Date?

        var modeTitle: String { mode == "raid" ? "突袭" : "普通" }

        var outcomeTitle: String {
            switch outcome {
            case "won": "通关"
            case "failed": "失败"
            case "skipped": "跳过"
            default: "没确认"
            }
        }
    }

    let isCopilot: Bool
    let status: String
    let won: Int?
    let total: Int?
    let durationSeconds: Int?
    let results: [StageResult]
    let stopReason: String?
    /// 日常战报里的「执行结果」。
    let summary: String?
    let notes: [String]

    var failedCount: Int {
        results.filter { $0.outcome == "failed" || $0.outcome == "unknown" }.count
    }

    init?(data: Data) {
        guard case let .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        isCopilot = root["kind"]?.string == "copilot"
        status = root["status"]?.string ?? ""
        won = root["won"]?.number.map { Int($0) }
        total = root["total"]?.number.map { Int($0) }
        durationSeconds = root["duration_seconds"]?.number.map { Int($0) }
        stopReason = root["stop_reason"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        results = (root["results"]?.array ?? []).enumerated().compactMap { index, item in
            guard let object = item.object, let stage = object["stage"]?.string else { return nil }
            return StageResult(
                id: index,
                stage: stage,
                mode: object["mode"]?.string ?? "normal",
                outcome: object["outcome"]?.string ?? "",
                detail: object["detail"]?.string ?? "",
                startedAt: object["started_at"]?.string.flatMap(BeijingTime.parseISO),
                finishedAt: object["finished_at"]?.string.flatMap(BeijingTime.parseISO))
        }
        let fields = root["embeds"]?.array?.first?.object?["fields"]?.array?.compactMap(\.object) ?? []
        func field(_ needle: String) -> String? {
            fields.first { ($0["name"]?.string ?? "").contains(needle) }?["value"]?.string
        }
        summary = field("执行结果")
        notes = (field("备注") ?? "").split(separator: "\n").map(String.init)
    }
}
