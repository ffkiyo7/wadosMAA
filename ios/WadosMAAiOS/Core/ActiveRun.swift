//
//  ActiveRun.swift
//  Wado's MAA (iOS)
//
//  从 `lock` + `progress` 推出「现在正在跑什么」，全局胶囊和实时进度都看它。
//

import Foundation
import WadosMAAShared

struct ActiveRun: Equatable {
    enum Kind: Equatable {
        case daily, copilot, other
    }

    let kind: Kind
    /// 「晚场」「手动场」「抄作业」「更新游戏资源」。
    let title: String
    let runID: String?
    let progress: RunProgressFile?

    init(lock: LockHolder, progress: RunProgressFile?) {
        runID = lock.runId
        self.progress = progress
        switch lock.holder {
        case "daily":
            kind = .daily
            switch lock.detail {
            case "早": title = "早场"
            case "晚": title = "晚场"
            case "手动": title = "手动场"
            default: title = "日常"
            }
        case "copilot":
            kind = .copilot
            title = "抄作业"
        default:
            kind = .other
            title = lock.name
        }
    }

    /// 只有带 `run_id` 的日常和抄作业能停：服务端靠它防止停错场。
    var canStop: Bool {
        kind != .other && runID?.isEmpty == false
    }

    var currentDailyStep: DailyStep? {
        guard kind == .daily else { return nil }
        if let key = progress?.currentKey, let step = DailyStep(rawValue: key) { return step }
        return progress?.steps.first { $0.state == .running }.flatMap { DailyStep(rawValue: $0.key) }
    }

    var currentCopilotStage: String? {
        progress?.copilot?.currentStage
    }

    /// 第几步（从 1 开始），用于「4/7」。
    var dailyPosition: Int? {
        guard let step = currentDailyStep, let index = DailyStep.allCases.firstIndex(of: step) else { return nil }
        return index + 1
    }

    /// 胶囊上的一句：「基建中」「TL-EX-7 · 2/3」。
    var statusText: String {
        switch kind {
        case .daily:
            if let step = currentDailyStep { return "\(step.title)中" }
            return "\(title)准备中"
        case .copilot:
            guard let copilot = progress?.copilot, copilot.total > 0 else { return "抄作业准备中" }
            let position = min(copilot.done + 1, copilot.total)
            if let stage = copilot.currentStage { return "\(stage) · \(position)/\(copilot.total)" }
            return "抄作业 \(position)/\(copilot.total)"
        case .other:
            return "\(title)中"
        }
    }

    var stopTitle: String {
        "停止\(title)？"
    }

    var stopMessage: String {
        switch kind {
        case .daily:
            guard let step = currentDailyStep, let position = dailyPosition else { return "" }
            return "当前第 \(position) 步：\(step.title)"
        case .copilot:
            guard let stage = currentCopilotStage else { return "" }
            return "\(stage) 这一关不计通关"
        case .other:
            return ""
        }
    }
}
