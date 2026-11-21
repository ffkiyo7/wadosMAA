//
//  LastRunText.swift
//  WadosMAAShared
//
//  `last_run.json` 给人看的说法。判成败只看 `status`，不读 `ok`（DEV_GUIDE §12.3）。
//

import Foundation

public enum LastRunText {
    /// 还没出结果的状态。
    public static let ongoing: Set<String> = ["", "running", "dispatched", "pending", "queued"]

    public static func isCopilot(_ run: [String: JSONValue]) -> Bool {
        (run["phase"]?.string ?? "").hasPrefix("copilot-")
    }

    public static func kind(_ run: [String: JSONValue]) -> String {
        kind(phase: run["phase"]?.string)
    }

    /// `am` / `pm` / `now` / `copilot-<token>`（`last_run.json` 和 `runs/index.jsonl` 同一套）。
    public static func kind(phase: String?) -> String {
        switch phase {
        case "am": "早场日常"
        case "pm": "晚场日常"
        case let phase? where phase.hasPrefix("copilot-"): "抄作业"
        default: "手动日常"
        }
    }

    /// 日常读 `plan.stage`，抄作业读顶层 `stage`。
    public static func stage(_ run: [String: JSONValue]) -> String {
        (isCopilot(run) ? run["stage"]?.string : run["plan"]?.object?["stage"]?.string) ?? ""
    }

    /// 「早场日常 · TL-7」。
    public static func title(_ run: [String: JSONValue]) -> String {
        let stage = stage(run)
        return kind(run) + (stage.isEmpty ? "" : " · \(stage)")
    }

    /// 原始状态不直接上界面：认不出的终态一律算「没完成」。
    public static func statusWord(_ status: String) -> String {
        switch status {
        case "success": "完成"
        case "skipped": "已跳过"
        case "canceled", "cancelled": "已取消"
        case _ where ongoing.contains(status): "进行中"
        default: "没完成"
        }
    }
}
