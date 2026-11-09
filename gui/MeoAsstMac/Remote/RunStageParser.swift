//
//  RunStageParser.swift
//  Wado's MAA
//
//  过渡期用：maa-remote 没给 `last_run.progress`（旧版、抄作业）时才用它，见 RunProgress.swift。
//  maa-cli 日志 → 阶段。只认整行的 `<Task> Start|Completed|Error|Stopped` 和 `AllTasksCompleted`，
//  其余行（理智、掉落、公招 tag……）一律不看。只依赖 Foundation，方便单独拿出来测。
//

import Foundation

/// 一个阶段：`key` 对上计划里要做的事（`StartUp` / `Annihilation` / `Fight` …），
/// `label` 给状态条用（「刷理智」），`doing` 给日志用（「正在刷理智」）。
struct RunStage: Equatable, Sendable {
    let key: String
    let label: String
    let doing: String
}

enum RunStageEvent: Equatable, Sendable {
    case started(RunStage)
    /// `<Task> Completed`（只认刚 Start 的那一个）。
    case completed(RunStage)
    /// `<Task> Error` / `<Task> Stopped`。
    case failed(RunStage)
    /// `Mission started (3 times, use 90 sanity)`：开了一次（连战）`times` 把，花 `sanity` 理智。
    case missions(times: Int, sanity: Int)
    /// `Current sanity: 104/208`：现在的理智。
    case sanity(Int)
    /// `AllTasksCompleted`：maa 的任务都跑完了，maa-remote 还要截图、发战报。
    case allDone
}

struct RunStageParser: Sendable {
    /// 抄作业：`Fight` 是导航到关卡，`Custom` 是界面检查 / 战后收尾，不是刷理智、回主界面。
    let copilot: Bool
    /// 日常本场要打剿灭（`last_run.plan.annihilation == true`）：剿灭也是 `Fight`，排在刷理智前面，
    /// 日志里分不出来，只能按「第一个 Fight 是剿灭」算（maa-remote 的任务顺序，DEV_GUIDE §5）。
    let annihilationPlanned: Bool

    static let wrapUp = RunStage(key: "WrapUp", label: "收尾", doing: "正在收尾")

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
    private static let mission = try! NSRegularExpression(pattern: "^Mission started \\((\\d+) times?, use (\\d+) sanity\\)")
    private static let sanityLine = try! NSRegularExpression(pattern: "^Current sanity: (\\d+)/\\d+")

    private static func numbers(_ regex: NSRegularExpression, _ line: String) -> [Int]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).flatMap { Int(line[$0]) } }
    }

    mutating func parse(line raw: String) -> RunStageEvent? {
        let stripped = Self.ansi.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        let line = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "AllTasksCompleted" {
            running = nil
            return .allDone
        }
        if line.hasPrefix("Mission started"), let n = Self.numbers(Self.mission, line), n.count == 2, n[0] > 0 {
            return .missions(times: n[0], sanity: n[1])
        }
        if line.hasPrefix("Current sanity"), let n = Self.numbers(Self.sanityLine, line), n.count == 1 {
            return .sanity(n[0])
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
        case "Completed":
            guard let running, running.task == task else { return nil }
            self.running = nil
            return .completed(running.stage)
        default:
            return nil
        }
    }

    /// 任务名 → 阶段。nil = 这一类不显示；不认识的原样显示。
    private func stage(for task: String) -> RunStage? {
        switch task {
        case "StartUp": return RunStage(key: "StartUp", label: "启动游戏", doing: "正在启动游戏")
        case "Fight":
            if copilot { return RunStage(key: "Navigate", label: "前往关卡", doing: "正在前往关卡") }
            if annihilationPlanned && fightStarts == 0 { return RunStage(key: "Annihilation", label: "剿灭", doing: "正在打剿灭") }
            return RunStage(key: "Fight", label: "刷理智", doing: "正在刷理智")
        case "Copilot": return RunStage(key: task, label: "抄作业", doing: "正在抄作业")
        case "Infrast": return RunStage(key: task, label: "基建换班", doing: "正在基建换班")
        case "Recruit": return RunStage(key: task, label: "公开招募", doing: "正在公开招募")
        case "Mall": return RunStage(key: task, label: "信用商店", doing: "正在逛信用商店")
        case "Award": return RunStage(key: task, label: "领取奖励", doing: "正在领取奖励")
        case "Custom": return copilot ? nil : RunStage(key: task, label: "返回主界面", doing: "正在返回主界面")
        case "Roguelike": return RunStage(key: task, label: "集成战略", doing: "正在刷集成战略")
        case "Reclamation": return RunStage(key: task, label: "生息演算", doing: "正在刷生息演算")
        case "CloseDown": return RunStage(key: task, label: "关闭游戏", doing: "正在关闭游戏")
        default: return RunStage(key: task, label: task, doing: task)
        }
    }
}
