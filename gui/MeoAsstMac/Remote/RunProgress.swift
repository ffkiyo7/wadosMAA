//
//  RunProgress.swift
//  Wado's MAA
//
//  maa-remote 跑日常 / 手动场 / 抄作业时，跟着本场的 maa-cli 日志（`last_run.log`，DEV_GUIDE §12.3）
//  算出现在在哪个阶段。`RemoteStore` 每次读到 `last_run.json` 就喂进来；运行中每秒只读日志新增的部分
//  （`state/maa/` 的目录监听收不到 `runs/` 里的追加）。跑完、切环境就停。
//

import Foundation
import Observation

@MainActor @Observable final class RunProgress {
    struct Entry: Identifiable, Equatable {
        enum Tone { case run, stage, ok, error }

        let id = UUID()
        let date: Date
        /// 打开 App 时这一场已经跑了一段：之前那些阶段只知道顺序，不知道时刻。
        let exact: Bool
        let text: String
        let tone: Tone
    }

    /// 步骤条上的一格：计划里要做的一件事。
    struct Step: Identifiable, Equatable {
        enum State { case pending, running, done, failed, skipped }

        let key: String
        let label: String
        var state: State = .pending
        var id: String { key }
    }

    /// 最近一场的阶段行（开始、各阶段、出错、结果）。新一场开跑时清空。
    private(set) var entries: [Entry] = []
    /// 正在跑的阶段；不在跑或还没到第一个阶段时是 nil。
    private(set) var current: RunStage?

    /// 本场（正在跑或刚跑完）：「早场日常 · TL-7」、开始时刻、结果（还在跑是 nil）、本场日志文件。
    private(set) var title = ""
    private(set) var startedAt: Date?
    private(set) var outcome: String?
    private(set) var logURL: URL?
    /// 日常的步骤条：`plan.tasks` 里开着的事 + 日志解析出的进度。抄作业没有，是空的。
    private(set) var steps: [Step] = []
    /// 刷理智已打几把（连战按把数算）。
    private(set) var fights = 0
    /// 刷理智估计一共几把：已打 + 剩余理智 ÷ 每把消耗；拿不到每把消耗或理智时是 nil。刷理智做完后是确数。
    private(set) var fightTotal: Int?
    private(set) var fightTotalExact = false

    /// 有一场在跟（或刚跟完）。
    var hasRun: Bool { runKey != nil }

    /// 整体进度 0…1：按步骤条平分，刷理智那一格按 已打 / 估计总数 算。没有步骤条（抄作业）是 nil。
    var fraction: Double? {
        guard !steps.isEmpty else { return nil }
        if outcome == "success" { return 1 }
        let sum = steps.reduce(0.0) { sum, step in
            switch step.state {
            case .pending: return sum
            case .done, .failed, .skipped: return sum + 1
            case .running:
                guard step.key == "Fight", let total = fightTotal, total > 0 else { return sum }
                return sum + min(Double(fights) / Double(total), 0.95)
            }
        }
        return sum / Double(steps.count)
    }

    /// 「3/≈7」「3/7」「3 次」；还没打或不在刷理智时 nil。
    var fightText: String? {
        guard fights > 0 || fightTotalExact else { return nil }
        guard let total = fightTotal else { return "\(fights) 次" }
        return fightTotalExact ? "\(fights)/\(total)" : "\(fights)/≈\(max(total, fights))"
    }

    static let pollInterval: Duration = .seconds(1)
    /// 一次最多读这么多，日志再大也不会卡住主线程。
    static let readLimit = 4 * 1024 * 1024

    /// 正在跟（或刚跟完）的那一场：phase|started_at。
    @ObservationIgnored private var runKey: String?
    @ObservationIgnored private var finished = false
    /// 刷理智时最近一次读到的理智（扣掉之后开的那几把）和每把消耗。
    @ObservationIgnored private var sanityLeft: Int?
    @ObservationIgnored private var perRun: Double?
    @ObservationIgnored private var offset: UInt64 = 0
    /// 跟的时候日志还没建、或还是同名旧场的内容：之后读到的都是现场发生的。
    @ObservationIgnored private var sawNotReady = false
    @ObservationIgnored private var parser = RunStageParser(copilot: false, annihilationPlanned: false)
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// 读到新的 `last_run.json` 时调用。
    func update(run: [String: JSONValue]) {
        let status = run["status"]?.string ?? ""
        let startedText = run["started_at"]?.string ?? ""
        let key = (run["phase"]?.string ?? "") + "|" + startedText
        if status == "running" {
            if key != runKey { begin(run: run, key: key, started: RunLock.parseISO(startedText)) }
            // 旧版 maa-remote 运行中不给 `log`，那就只有开始和结果两行。
            if let path = run["log"]?.string, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if url != logURL {
                    logURL = url
                    resetRead()
                }
                startPolling()
            }
        } else if key == runKey, !finished, !LastRunText.ongoing.contains(status) {
            readNew()
            stopPolling()
            finished = true
            current = nil
            outcome = status
            for i in steps.indices where steps[i].state == .running {
                steps[i].state = status == "success" ? .done : .failed
            }
            let ok = status == "success"
            entries.append(Entry(date: Date(), exact: true, text: "\(title) \(LastRunText.statusWord(status))",
                                 tone: ok || status == "skipped" ? .ok : .error))
        }
    }

    /// 切环境：停掉并清空。
    func stop() {
        stopPolling()
        runKey = nil
        finished = false
        logURL = nil
        entries = []
        current = nil
        title = ""
        startedAt = nil
        outcome = nil
        steps = []
        resetFights()
    }

    private func begin(run: [String: JSONValue], key: String, started: Date?) {
        stopPolling()
        runKey = key
        finished = false
        title = LastRunText.title(run)
        startedAt = started
        logURL = nil
        current = nil
        outcome = nil
        steps = Self.planSteps(run)
        resetFights()
        let annihilation = run["plan"]?.object?["annihilation"]?.bool == true
        parser = RunStageParser(copilot: LastRunText.isCopilot(run), annihilationPlanned: annihilation)
        resetRead()
        entries = [Entry(date: started ?? Date(), exact: started != nil, text: "\(title) 开始", tone: .run)]
    }

    /// 计划里要做的事，按 maa-remote 的执行顺序（DEV_GUIDE §5）；关掉的不放。抄作业不画步骤条。
    static func planSteps(_ run: [String: JSONValue]) -> [Step] {
        guard !LastRunText.isCopilot(run) else { return [] }
        let plan = run["plan"]?.object ?? [:]
        let tasks = plan["tasks"]?.object ?? [:]
        func on(_ key: String) -> Bool { tasks[key]?.bool ?? true }
        var steps = [Step(key: "StartUp", label: "启动游戏")]
        if plan["annihilation"]?.bool == true { steps.append(Step(key: "Annihilation", label: "剿灭")) }
        if on("fight"), plan["farming"]?.bool ?? true { steps.append(Step(key: "Fight", label: "刷理智")) }
        if on("infrast") { steps.append(Step(key: "Infrast", label: "基建")) }
        if on("recruit") { steps.append(Step(key: "Recruit", label: "公招")) }
        if on("mall") { steps.append(Step(key: "Mall", label: "商店")) }
        if on("award") { steps.append(Step(key: "Award", label: "领奖")) }
        return steps
    }

    private func resetFights() {
        fights = 0
        fightTotal = nil
        fightTotalExact = false
        sanityLeft = nil
        perRun = nil
    }

    /// 开始了 `key`：它前面还在跑的算做完，没轮到的算跳过。收尾（返回主界面 / 关游戏）把剩下的都结掉。
    private func advance(to key: String) {
        let end = ["Custom", "CloseDown", RunStageParser.wrapUp.key].contains(key)
        guard let index = end ? steps.endIndex : steps.firstIndex(where: { $0.key == key }) else { return }
        for i in steps.startIndex..<index {
            switch steps[i].state {
            case .running: steps[i].state = .done
            case .pending: steps[i].state = .skipped
            default: break
            }
        }
        if index < steps.endIndex {
            steps[index].state = .running
            if key == "Fight" { fightTotalExact = false }
        }
    }

    private func mark(_ key: String, _ state: Step.State) {
        guard let index = steps.firstIndex(where: { $0.key == key }), steps[index].state == .running else { return }
        steps[index].state = state
    }

    private func estimateFights() {
        guard let perRun, perRun > 0, let sanityLeft else { return }
        fightTotal = fights + Int(Double(sanityLeft) / perRun)
    }

    private func resetRead() {
        offset = 0
        sawNotReady = false
    }

    private func startPolling() {
        guard poll == nil else { return }
        readNew()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.readNew()
            }
        }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func readNew() {
        guard let logURL else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            sawNotReady = true
            return
        }
        // maa run 开写前，同名文件可能还是今天上一场（比如第二次手动场）的内容。
        if let startedAt, let modified = attributes[.modificationDate] as? Date, modified < startedAt {
            sawNotReady = true
            return
        }
        if size < offset {
            // 被截断重写了：从头来。
            offset = 0
            parser = RunStageParser(copilot: parser.copilot, annihilationPlanned: parser.annihilationPlanned)
            for i in steps.indices { steps[i].state = .pending }
            resetFights()
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let catchUp = offset == 0 && !sawNotReady
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.read(upToCount: min(Int(size - offset), Self.readLimit)), !data.isEmpty
        else { return }
        offset += UInt64(data.count)
        let date = catchUp ? (startedAt ?? Date()) : Date()
        for event in parser.feed(data) {
            switch event {
            case let .started(stage):
                current = stage
                advance(to: stage.key)
                entries.append(Entry(date: date, exact: !catchUp, text: stage.doing, tone: .stage))
            case let .completed(stage):
                mark(stage.key, .done)
                if stage.key == "Fight" {
                    fightTotal = fights
                    fightTotalExact = true
                }
            case let .failed(stage):
                mark(stage.key, .failed)
                entries.append(Entry(date: date, exact: !catchUp, text: "\(stage.label)未完成", tone: .error))
            case let .missions(times, sanity):
                guard current?.key == "Fight" else { break }
                fights += times
                perRun = Double(sanity) / Double(times)
                sanityLeft = sanityLeft.map { max(0, $0 - sanity) }
                estimateFights()
            case let .sanity(value):
                guard current?.key == "Fight" else { break }
                sanityLeft = value
                estimateFights()
            case .allDone:
                current = RunStageParser.wrapUp
                advance(to: RunStageParser.wrapUp.key)
            }
        }
    }
}
