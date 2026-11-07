//
//  RunStageParser.swift
//  Wado's MAA
//
//  maa-cli 日志 → 阶段。只认整行的 `<Task> Start|Completed|Error|Stopped` 和 `AllTasksCompleted`，
//  其余行（理智、掉落、公招 tag……）一律不看。只依赖 Foundation，方便单独拿出来测。
//

import Foundation

/// 一个阶段：`label` 给状态条用（「刷理智」），`doing` 给日志用（「正在刷理智」）。
struct RunStage: Equatable, Sendable {
    let label: String
    let doing: String
}

enum RunStageEvent: Equatable, Sendable {
    case started(RunStage)
    /// `<Task> Error` / `<Task> Stopped`。
    case failed(RunStage)
    /// `AllTasksCompleted`：maa 的任务都跑完了，maa-remote 还要截图、发战报。
    case allDone
}

struct RunStageParser: Sendable {
    /// 抄作业：`Fight` 是导航到关卡，`Custom` 是界面检查 / 战后收尾，不是刷理智、回主界面。
    let copilot: Bool
    /// 日常本场要打剿灭（`last_run.plan.annihilation == true`）：剿灭也是 `Fight`，排在刷理智前面，
    /// 日志里分不出来，只能按「第一个 Fight 是剿灭」算（maa-remote 的任务顺序，DEV_GUIDE §5）。
    let annihilationPlanned: Bool

    static let wrapUp = RunStage(label: "收尾", doing: "正在收尾")

    private var fightStarts = 0
    /// 最近一次 Start 的任务名和阶段，给 Error / Stopped 认名字用。
    private var running: (task: String, stage: RunStage)?
    private var pending = Data()

    init(copilot: Bool, annihilationPlanned: Bool) {
        self.copilot = copilot
        self.annihilationPlanned = annihilationPlanned
    }

    /// 喂一段新读到的字节；不完整的最后一行留到下次。
    mutating func feed(_ data: Data) -> [RunStageEvent] {
        pending.append(data)
        var events: [RunStageEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            if let event = parse(line: line) { events.append(event) }
        }
        // 一行不该这么长；真遇到了就丢掉，免得缓冲一直涨。
        if pending.count > 64 * 1024 { pending.removeAll() }
        return events
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-?]*[ -/]*[@-~]")
    private static let marker = try! NSRegularExpression(pattern: "^([A-Z][A-Za-z0-9]*) (Start|Completed|Error|Stopped)$")

    mutating func parse(line raw: String) -> RunStageEvent? {
        let stripped = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        let line = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "AllTasksCompleted" {
            running = nil
            return .allDone
        }
        guard let match = Self.marker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            let taskRange = Range(match.range(at: 1), in: line),
            let verbRange = Range(match.range(at: 2), in: line)
        else { return nil }
        let task = String(line[taskRange])
        switch line[verbRange] {
        case "Start":
            guard let stage = stage(for: task) else { return nil }
            if task == "Fight" { fightStarts += 1 }
            running = (task, stage)
            return .started(stage)
        case "Error", "Stopped":
            defer { if running?.task == task { running = nil } }
            if let running, running.task == task { return .failed(running.stage) }
            return stage(for: task).map(RunStageEvent.failed)
        default:
            return nil
        }
    }

    /// 任务名 → 阶段。nil = 这一类不显示；不认识的原样显示。
    private func stage(for task: String) -> RunStage? {
        switch task {
        case "StartUp": return RunStage(label: "开始唤醒", doing: "正在开始唤醒")
        case "Fight":
            if copilot { return RunStage(label: "前往关卡", doing: "正在前往关卡") }
            if annihilationPlanned && fightStarts == 0 { return RunStage(label: "剿灭", doing: "正在打剿灭") }
            return RunStage(label: "刷理智", doing: "正在刷理智")
        case "Copilot": return RunStage(label: "抄作业", doing: "正在抄作业")
        case "Infrast": return RunStage(label: "基建换班", doing: "正在基建换班")
        case "Recruit": return RunStage(label: "公开招募", doing: "正在公开招募")
        case "Mall": return RunStage(label: "信用商店", doing: "正在逛信用商店")
        case "Award": return RunStage(label: "领取奖励", doing: "正在领取奖励")
        case "Custom": return copilot ? nil : RunStage(label: "返回主界面", doing: "正在返回主界面")
        case "Roguelike": return RunStage(label: "集成战略", doing: "正在刷集成战略")
        case "Reclamation": return RunStage(label: "生息演算", doing: "正在刷生息演算")
        case "CloseDown": return RunStage(label: "关闭游戏", doing: "正在关闭游戏")
        default: return RunStage(label: task, doing: task)
        }
    }
}
