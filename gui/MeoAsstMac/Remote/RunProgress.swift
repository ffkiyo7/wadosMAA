//
//  RunProgress.swift
//  Wado's MAA
//
//  maa-remote 跑日常 / 手动场 / 抄作业时，现在做到哪了。`RemoteStore` 每次读到 `last_run.json` 就喂进来；
//  运行中每秒读一次（`state/maa/` 的目录监听收不到 `runs/` 里的改动）。跑完、切环境就停。
//
//  数据来源（DEV_GUIDE §12.3）：
//  - 有 `last_run.progress`：读 maa-remote 写的 `runs/<场>.progress.json`，步骤、刷理智把数、ETA、
//    重试 / 重启这些说明都照它显示，自己不解析日志；
//  - 没有（旧版 maa-remote、抄作业）：退回跟 maa-cli 日志（`last_run.log`），用 `RunStageParser` 猜。
//

import Foundation
import Observation

@MainActor @Observable final class RunProgress {
    struct Entry: Identifiable, Equatable {
        enum Tone { case run, stage, ok, error, note }

        let id = UUID()
        let date: Date
        /// 打开 App 时这一场已经跑了一段：之前那些阶段只知道顺序，不知道时刻。
        let exact: Bool
        let text: String
        let tone: Tone
    }

    /// 步骤条上的一格：计划里要做的一件事。
    struct Step: Identifiable, Equatable {
        enum State: String { case pending, running, done, failed, skipped }

        let key: String
        let label: String
        var state: State = .pending
        var id: String { key }
    }

    /// maa-remote 记下的恢复动作（重试、重启、摆窗、补跑……），给玩家看的原话。
    struct Note: Identifiable, Equatable {
        let id: Int
        let date: Date?
        let text: String
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
    /// 本场的恢复说明，按时间先后。只有新版 maa-remote（有 progress.json）才有。
    private(set) var notes: [Note] = []
    /// 预计几点结束；没有历史耗时或已结束时是 nil。
    private(set) var eta: Date?

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
    /// maa-remote 写的本场进度文件；nil = 旧版 maa-remote 或抄作业，退回解析日志。
    @ObservationIgnored private var progressURL: URL?
    /// 计划里要做的事（`planSteps`）；进度文件里其余的格子不画。
    @ObservationIgnored private var plannedKeys: Set<String> = []
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// 读到新的 `last_run.json` 时调用。
    func update(run: [String: JSONValue]) {
        let status = run["status"]?.string ?? ""
        let startedText = run["started_at"]?.string ?? ""
        let key = (run["phase"]?.string ?? "") + "|" + startedText
        if status == "running" {
            if key != runKey { begin(run: run, key: key, started: RunLock.parseISO(startedText)) }
            if let path = run["progress"]?.string, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if url != progressURL { progressURL = url }
                // 日志只给「在 Finder 中显示」用，不解析。
                logURL = run["log"]?.string.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                startPolling()
            } else if let path = run["log"]?.string, !path.isEmpty {
                // 旧版 maa-remote：跟日志。更旧的运行中连 `log` 都不给，那就只有开始和结果两行。
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
            eta = nil
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
        notes = []
        eta = nil
        progressURL = nil
        plannedKeys = []
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
        plannedKeys = Set(steps.map(\.key))
        notes = []
        eta = nil
        progressURL = nil
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
        if progressURL != nil {
            readProgressFile()
            return
        }
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

    // MARK: progress.json（新版 maa-remote）

    /// 进度文件的步骤 key → 界面里一直用的 key（和 `planSteps`、状态条的 `"Fight"` 判断一致）。
    static let fileKeys: [String: String] = [
        "startup": "StartUp", "annihilation": "Annihilation", "fight": "Fight", "infrast": "Infrast",
        "recruit": "Recruit", "mall": "Mall", "award": "Award",
    ]

    static func doing(_ key: String, _ label: String) -> String {
        switch key {
        case "StartUp": "正在启动游戏"
        case "Annihilation": "正在打剿灭"
        case "Fight": "正在刷理智"
        case "Infrast": "正在基建换班"
        case "Recruit": "正在公开招募"
        case "Mall": "正在逛信用商店"
        case "Award": "正在领取奖励"
        default: "正在\(label)"
        }
    }

    /// 读一遍进度文件，整份照抄过来；只给日志区补「新开始的一步」「没完成」和新的说明。
    private func readProgressFile() {
        guard let progressURL, let data = try? Data(contentsOf: progressURL),
            case let .object(file)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return }
        // 同名旧场（今天第二次手动场）的文件：开始时刻对不上就当还没有。
        if let startedAt, let fileStart = file["started_at"]?.string.flatMap(RunLock.parseISO),
            abs(fileStart.timeIntervalSince(startedAt)) > 2
        {
            return
        }
        let now = Date()
        var fresh: [Step] = []
        for item in file["steps"]?.array ?? [] {
            guard let object = item.object, let raw = object["key"]?.string else { continue }
            let key = Self.fileKeys[raw] ?? raw
            if !plannedKeys.isEmpty, !plannedKeys.contains(key) { continue }
            let label = object["label"]?.string ?? key
            let state = Step.State(rawValue: object["state"]?.string ?? "") ?? .pending
            let old = steps.first { $0.key == key }?.state
            if state != old {
                let at = object["started_at"]?.string.flatMap(RunLock.parseISO)
                if state == .running {
                    entries.append(Entry(date: at ?? now, exact: at != nil, text: Self.doing(key, label), tone: .stage))
                } else if state == .failed {
                    let end = object["finished_at"]?.string.flatMap(RunLock.parseISO)
                    entries.append(Entry(date: end ?? now, exact: end != nil, text: "\(label)未完成", tone: .error))
                }
            }
            fresh.append(Step(key: key, label: label, state: state))
        }
        if !fresh.isEmpty { steps = fresh }

        if let raw = file["current"]?.string, let step = steps.first(where: { $0.key == (Self.fileKeys[raw] ?? raw) }) {
            current = RunStage(key: step.key, label: step.label, doing: Self.doing(step.key, step.label))
        } else {
            current = nil
        }

        let fight = file["fight"]?.object ?? [:]
        fights = Int(fight["done"]?.number ?? 0)
        fightTotal = fight["estimate"]?.number.map { Int($0) }
        fightTotalExact = steps.first { $0.key == "Fight" }?.state == .done

        let all = (file["notes"]?.array ?? []).enumerated().compactMap { index, item -> Note? in
            guard let object = item.object, let text = object["text"]?.string, !text.isEmpty else { return nil }
            return Note(id: index, date: object["at"]?.string.flatMap(RunLock.parseISO), text: text)
        }
        for note in all.dropFirst(notes.count) {
            entries.append(Entry(date: note.date ?? now, exact: note.date != nil, text: note.text, tone: .note))
        }
        if all.count != notes.count { notes = all }
        eta = file["eta"]?.string.flatMap(RunLock.parseISO)
    }
}
