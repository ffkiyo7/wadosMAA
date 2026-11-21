//
//  TodaySessions.swift
//  Wado's MAA
//
//  首页的早场 / 晚场：两张并排等宽的大卡。每张：场名 + 时间、状态大字、一行细节，右上角只放一个动作。
//  还没开始 → 倒计时 + 关卡下拉（`plan set-stage` / `auto-stage` / `fight`）+「跳过」；
//  进行中 → 卡片展开成步骤条和刷理智进度（`runs/<场>.progress.json`）+「停止」；
//  完成 → 起止时间、刷了几把、掉落；没完成 →「再跑一次」；关着 →「打开」。
//

import SwiftUI
import WadosMAAShared

/// 某一天某一场的结果。正在跑的看 `last_run.json`；跑完的看 `runs/index.jsonl`，
/// 早场、晚场各有一行，晚场开跑不会把早场的结果盖掉。
struct SessionOutcome {
    let status: String
    let started: Date
    let finished: Date?
    /// 没成功 / 跳过的原因（索引里才有）。
    let reason: String
    let stage: String
    /// 这一场的进度文件（读掉落、把数）。
    let progressPath: String?

    var ongoing: Bool { LastRunText.ongoing.contains(status) }

    /// `day` 那天（北京时间）的 `phase` 场；没跑过是 nil。
    @MainActor static func of(_ phase: String, on day: Date, store: RemoteStore) -> SessionOutcome? {
        let calendar = Beijing.calendar
        var live: SessionOutcome?
        let run = store.lastRun
        if run["phase"]?.string == phase,
            let started = run["started_at"]?.string.flatMap(RunLock.parseISO),
            calendar.isDate(started, inSameDayAs: day)
        {
            var status = run["status"]?.string ?? ""
            var reason = ""
            // 写着「进行中」但锁已经空了：进程没收尾就没了。
            if LastRunText.ongoing.contains(status), store.lockHolder == nil {
                status = "failed"
                reason = "中途断了"
            }
            live = SessionOutcome(
                status: status, started: started,
                finished: run["finished_at"]?.string.flatMap(RunLock.parseISO), reason: reason,
                stage: LastRunText.stage(run), progressPath: run["progress"]?.string)
        }
        let record = store.recentRuns.first {
            $0.phase == phase && $0.startedAt.map { calendar.isDate($0, inSameDayAs: day) } == true
        }
        if let record, let started = record.startedAt,
            live.map({ !$0.ongoing && started >= $0.started.addingTimeInterval(-1) }) ?? true
        {
            return SessionOutcome(
                status: record.status, started: started, finished: record.endedAt, reason: record.reason,
                stage: record.stage, progressPath: record.progressPath)
        }
        return live
    }

    /// 那一场刷了几把、掉了什么；读不到是 nil。
    @MainActor var fight: RunFightResult? { RunFightResult.read(progressPath, started: started) }

    /// 「08:00–08:41」
    var span: String {
        var text = RunLock.beijingClock(started)
        if let finished { text += "–\(RunLock.beijingClock(finished))" }
        return text
    }
}

struct SessionCard: View {
    let phase: String
    let name: String
    let now: Date
    /// 和旁边那张一样高。
    var stretch = false

    @Environment(RemoteStore.self) private var store
    @Environment(\.askGame) private var askGame
    @Environment(\.wmAccent) private var accent

    private static let order = ["fight", "infrast", "recruit", "mall", "award"]

    private var session: ScheduleReport.Session? { store.schedule?.sessions[phase] }
    private var plan: TodayPlan.Session? { store.todayPlan?.sessions.first { $0.phase == phase } }
    private var enabledKey: String { "schedule.\(phase).enabled" }
    private var enabled: Bool { store.pendingValue(enabledKey)?.bool ?? session?.enabled ?? true }

    private enum Phase {
        case upcoming(Date), skipToday, off, missed, unknown
        case running(SessionOutcome), done(SessionOutcome), failed(SessionOutcome)
        case cancelled(SessionOutcome), skipped(SessionOutcome)
    }

    var body: some View {
        let state = state(SessionOutcome.of(phase, on: now, store: store))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(name).font(.system(size: 17, weight: .bold))
                Text(session?.time ?? plan?.time ?? "—").font(.system(size: 15)).foregroundStyle(WM.f2).monospacedDigit()
                Spacer(minLength: 0)
                action(state)
            }
            .frame(height: 30)
            statusLine(state)
            if let detail = detail(state) {
                Text(detail.text).font(.system(size: 14)).foregroundStyle(detail.color)
                    .monospacedDigit().lineLimit(2)
            }
            stageLine(state)
            switch state {
            case let .done(outcome):
                if let drops = outcome.fight?.drops, !drops.isEmpty {
                    DropChips(drops: drops).padding(.top, 4)
                }
            case .running:
                if store.lastRun["phase"]?.string == phase, store.progress.hasRun {
                    RunBoard(progress: store.progress, stage: LastRunText.stage(store.lastRun)).padding(.top, 2)
                }
            default: EmptyView()
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: stretch ? .infinity : nil, alignment: .topLeading)
        .wmCard(radius: 18)
    }

    // MARK: 状态

    private func state(_ outcome: SessionOutcome?) -> Phase {
        if let outcome {
            switch outcome.status {
            case "success": return .done(outcome)
            case "skipped": return .skipped(outcome)
            case "canceled", "cancelled": return .cancelled(outcome)
            case _ where outcome.ongoing: return .running(outcome)
            default: return .failed(outcome)
            }
        }
        guard let session else { return .unknown }
        if !enabled { return .off }
        if plan?.skip == true { return .skipToday }
        if let date = Beijing.today(at: session.time, now: now), date > now { return .upcoming(date) }
        return .missed
    }

    @ViewBuilder private func statusLine(_ state: Phase) -> some View {
        let look = look(state)
        HStack(spacing: 10) {
            if case .running = state {
                Circle().fill(accent.color).frame(width: 11, height: 11)
                    .background(Circle().fill(accent.color.opacity(0.22)).frame(width: 21, height: 21))
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: look.icon).font(.system(size: 19))
                    .frame(width: 22, height: 22)
            }
            Text(look.text).font(.system(size: 22, weight: .semibold)).tracking(-0.2).monospacedDigit()
        }
        .foregroundStyle(look.color)
        .help(look.tip)
    }

    private func look(_ state: Phase) -> (icon: String, text: String, color: Color, tip: String) {
        let quiet = Color(hex: 0xebebf5, opacity: 0.78)
        switch state {
        case let .upcoming(date): return ("clock", Beijing.until(date, from: now), .primary, "还没开始")
        case .skipToday: return ("minus.circle", "今天跳过", quiet, "到点不跑这一场")
        case .off: return ("pause.circle", "已关", quiet, "到点不自动开始")
        case .missed: return ("minus.circle", "今天没跑", quiet, "今天没有记录")
        case .unknown: return ("circle.dashed", "读不到", quiet, "暂时读不到时间")
        case .running: return ("", "进行中", accent.color, "")
        case .done: return ("checkmark.circle", "完成", WM.ok, "")
        case .failed: return ("exclamationmark.circle", "没完成", WM.danger, "")
        case .cancelled: return ("stop.circle", "已停止", quiet, "")
        case .skipped: return ("minus.circle", "已跳过", quiet, "")
        }
    }

    /// 状态下面那一行：没开始时只在有事不做时说一句；跑过的写起止时间和原因。
    private func detail(_ state: Phase) -> (text: String, color: Color)? {
        switch state {
        case .upcoming:
            guard let plan else { return nil }
            let off = Self.order.dropFirst().filter { plan.tasks[$0] == false }
                .map { store.todayPlan?.taskNames[$0] ?? $0 }
            return off.isEmpty ? nil : ("不做\(off.joined(separator: "、"))", WM.f2)
        case let .running(outcome):
            var text = "\(RunLock.beijingClock(outcome.started)) 开始"
            if store.lastRun["phase"]?.string == phase, let eta = store.progress.eta {
                text += " · 预计 \(RunLock.beijingClock(eta)) 结束"
            }
            return (text, WM.f2)
        case let .done(outcome):
            var text = outcome.span
            if let done = outcome.fight?.done, done > 0, !outcome.stage.isEmpty {
                text += " · \(outcome.stage) 刷了 \(done) 把"
            }
            return (text, WM.f2)
        case let .failed(outcome):
            return (outcome.reason.isEmpty ? outcome.span : "\(outcome.reason) · \(outcome.span)", .primary)
        case let .cancelled(outcome):
            return (outcome.span, WM.f2)
        case let .skipped(outcome):
            // 计划里跳过的，「已跳过」已经说清楚了；只有「你在玩」这种才多一句。
            let plain = outcome.reason.isEmpty || outcome.reason == RunHistory.skipText["plan"]
            return plain ? nil : (outcome.reason, WM.f2)
        case .skipToday, .off, .missed, .unknown:
            return nil
        }
    }

    /// 还没跑的几种状态才露出关卡：没开始能换，今天跳过划掉变淡，关着只变淡。
    @ViewBuilder private func stageLine(_ state: Phase) -> some View {
        if let plan {
            switch state {
            case .upcoming:
                SessionStageMenu(plan: plan, editable: !store.readOnly, struck: false).padding(.top, 4)
            case .skipToday:
                SessionStageMenu(plan: plan, editable: false, struck: true).opacity(0.42).padding(.top, 4)
            case .off:
                SessionStageMenu(plan: plan, editable: false, struck: false).opacity(0.42).padding(.top, 4)
            default:
                EmptyView()
            }
        }
    }

    // MARK: 动作

    @ViewBuilder private func action(_ state: Phase) -> some View {
        switch state {
        case .running:
            if store.cancelableRun?.name == "\(name)日常" { StopRunButton() }
        case .failed, .cancelled:
            if let plan, store.lockHolder == nil, !store.readOnly {
                Button("再跑一次") { askGame(retryConfirm(plan)) }
                    .buttonStyle(WMButtonStyle())
                    .help("按这一场的计划马上再跑一次")
            }
        case .off where !store.readOnly:
            Button("打开") {
                Task {
                    await store.change(
                        ["schedule", "enable", phase], undo: ["schedule", "disable", phase],
                        pendingKey: enabledKey, pendingValue: .bool(true))
                }
            }
            .buttonStyle(WMButtonStyle())
            .help("到点自动开始")
        case .upcoming where !store.readOnly, .skipToday where !store.readOnly:
            if store.planChanging == phase {
                ProgressView().controlSize(.small)
            } else if let plan {
                Button(plan.skip ? "恢复" : "跳过") {
                    Task { await store.changePlan(phase, ["plan", "skip-today", plan.skip ? "off" : "on"]) }
                }
                .buttonStyle(WMButtonStyle())
                .disabled(store.planChanging != nil)
                .help(plan.skip ? "到点照常跑这一场" : "今天到点不跑这一场，另一场不受影响")
            }
        default:
            EmptyView()
        }
    }

    // MARK: 再跑一次

    /// 和「手动日常」同一条路（`run local`）：关卡、要做的事照这一场的计划。
    private func retryConfirm(_ plan: TodayPlan.Session, soon: Bool = false) -> GameConfirm {
        let names = Self.order.filter { plan.tasks[$0] ?? true }.map { store.todayPlan?.taskNames[$0] ?? $0 }
        let rows = [
            ("关卡", plan.fight ? (plan.stage.isEmpty ? "上次作战关卡" : plan.stage) : "不刷理智"),
            ("要做的事", names.isEmpty ? "无" : names.joined(separator: "、")),
            ("规矩", "不碎石、不借助战，只吃快过期的理智药"),
        ]
        guard soon else {
            return GameConfirm(title: "再跑一次\(name)？", rows: rows, ok: "开始") { Task { await retry(plan, force: false) } }
        }
        return GameConfirm(
            title: "另一场就要开始了", rows: rows,
            warning: "现在开始，另一场可能会因为游戏被占用而跳过。", ok: "仍然开始"
        ) { Task { await retry(plan, force: true) } }
    }

    private func retry(_ plan: TodayPlan.Session, force: Bool) async {
        var switches: [String: Bool] = [:]
        for key in Self.order { switches[key] = plan.tasks[key] ?? true }
        let payload = (try? JSONSerialization.data(withJSONObject: switches, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var args = ["run", "local", plan.stage, payload]
        if force { args.append("--force") }
        do {
            let receipt = try await RemoteBridge.run(args)
            if !receipt.ok, !force,
                receipt.code == "session_soon" || receipt.dictionary["blocked"] as? String == "blackout"
            {
                askGame(retryConfirm(plan, soon: true))
                return
            }
            store.post(receipt.ok, receipt.message)
        } catch {
            store.post(false, error.localizedDescription)
        }
        await store.reload()
    }
}

// MARK: - 进行中

/// 进行中的场卡展开的部分：7 格步骤条，刷理智那一格的把数、理智、已掉落。
private struct RunBoard: View {
    let progress: RunProgress
    let stage: String

    @Environment(\.wmAccent) private var accent

    var body: some View {
        let steps = progress.boardSteps
        VStack(alignment: .leading, spacing: 8) {
            if !steps.isEmpty {
                stepper(steps).padding(.top, 8)
            }
            let fightState = steps.first { $0.key == "Fight" }?.state
            if fightState == .running || fightState == .done {
                fightBox
            }
        }
    }

    private func stepper(_ steps: [RunProgress.Step]) -> some View {
        let reach = steps.lastIndex { $0.state != .pending } ?? 0
        return ZStack(alignment: .top) {
            GeometryReader { geo in
                let column = geo.size.width / CGFloat(steps.count)
                let span = geo.size.width - column
                let filled = steps.count > 1 ? span * CGFloat(reach) / CGFloat(steps.count - 1) : 0
                Rectangle().fill(Color.white.opacity(0.14))
                    .frame(width: span, height: 2).offset(x: column / 2, y: 11)
                Rectangle().fill(accent.color)
                    .frame(width: filled, height: 2).offset(x: column / 2, y: 11)
            }
            .frame(height: 24)
            HStack(spacing: 0) {
                ForEach(steps) { step in
                    VStack(spacing: 7) {
                        node(step.state)
                        Text(step.label)
                            .font(.system(size: 12.5, weight: step.state == .running ? .semibold : .regular))
                            .foregroundStyle(labelColor(step.state))
                            .lineLimit(1).fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private func node(_ state: RunProgress.Step.State) -> some View {
        switch state {
        case .done:
            Circle().fill(WM.ok).frame(width: 24, height: 24)
                .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(hex: 0x0b2414)))
        case .running:
            Circle().fill(Color(hex: 0x10302c)).frame(width: 24, height: 24)
                .overlay(Circle().fill(accent.color).frame(width: 8, height: 8))
                .overlay(Circle().strokeBorder(accent.color, lineWidth: 2))
                .background(Circle().fill(accent.color.opacity(0.18)).frame(width: 32, height: 32))
        case .pending:
            Circle().fill(Color(hex: 0x1c1930)).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color(hex: 0xebebf5, opacity: 0.38), lineWidth: 1.5))
        case .skipped:
            Circle().fill(Color(hex: 0x2c2940)).frame(width: 24, height: 24)
                .overlay(Circle().strokeBorder(Color(hex: 0xebebf5, opacity: 0.3), lineWidth: 1.5))
                .overlay(Text("–").font(.system(size: 12, weight: .heavy)).foregroundStyle(Color(hex: 0xebebf5, opacity: 0.8)))
        case .failed:
            Circle().fill(WM.danger).frame(width: 24, height: 24)
                .overlay(Image(systemName: "xmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color(hex: 0x3a0a05)))
        }
    }

    private func labelColor(_ state: RunProgress.Step.State) -> Color {
        switch state {
        case .done: Color(hex: 0xebebf5, opacity: 0.78)
        case .running: accent.color
        case .pending, .skipped: Color(hex: 0xebebf5, opacity: 0.66)
        case .failed: WM.danger
        }
    }

    private var fightBox: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("刷理智").font(.system(size: 15, weight: .semibold))
                if !stage.isEmpty {
                    Swatch(code: stage, size: 16, radius: 4).padding(.leading, 4)
                    Text(stage).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                }
                Spacer(minLength: 0)
                if let count = fightCount {
                    Text(count).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
            }
            if let sanity = progress.sanity {
                HStack(spacing: 10) {
                    Text("理智").font(.system(size: 13)).foregroundStyle(WM.f2).frame(width: 42, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.white.opacity(0.1))
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent.color)
                                    .frame(width: geo.size.width * min(1, CGFloat(sanity.current) / CGFloat(sanity.max)))
                            }
                    }
                    .frame(height: 6)
                    Text("\(sanity.current)/\(sanity.max)").font(.system(size: 13)).monospacedDigit()
                }
            }
            if !progress.drops.isEmpty {
                HStack(spacing: 10) {
                    Text("已掉落").font(.system(size: 13)).foregroundStyle(WM.f2).frame(width: 42, alignment: .leading)
                    DropText(drops: progress.drops)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// 「第 3 / 约 6 把」「第 3 / 6 把」「第 3 把」；还没打是 nil。
    private var fightCount: String? {
        guard progress.fights > 0 || progress.fightTotalExact else { return nil }
        guard let total = progress.fightTotal else { return "第 \(progress.fights) 把" }
        return progress.fightTotalExact
            ? "第 \(progress.fights) / \(total) 把"
            : "第 \(progress.fights) / 约 \(max(total, progress.fights)) 把"
    }
}

// MARK: - 掉落

/// 完成卡的掉落：最多 3 种，多了写「等 N 种」。
struct DropChips: View {
    let drops: [RunFightResult.Drop]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(drops.prefix(3), id: \.self) { drop in
                HStack(spacing: 7) {
                    Text(drop.name).font(.system(size: 14))
                    Text("×\(drop.count)").font(.system(size: 14)).foregroundStyle(WM.f2).monospacedDigit()
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .fixedSize()
            }
            if drops.count > 3 {
                Text("等 \(drops.count) 种").font(.system(size: 13)).foregroundStyle(WM.f2)
                    .help(drops.map { "\($0.name) ×\($0.count)" }.joined(separator: "\n"))
            }
        }
    }
}

/// 一行字的掉落：「环烃聚质 ×2　电极单元 ×1」，最多 3 种。
struct DropText: View {
    let drops: [RunFightResult.Drop]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(drops.prefix(3), id: \.self) { drop in
                HStack(spacing: 5) {
                    Text(drop.name)
                    Text("×\(drop.count)").foregroundStyle(WM.f2).monospacedDigit()
                }
                .fixedSize()
            }
            if drops.count > 3 {
                Text("等 \(drops.count) 种").foregroundStyle(WM.f2)
                    .help(drops.map { "\($0.name) ×\($0.count)" }.joined(separator: "\n"))
            }
        }
        .font(.system(size: 13))
    }
}

// MARK: - 关卡下拉

/// 一场刷哪关（谁定的）；没开始前点开换关，或者这一场不刷理智。
struct SessionStageMenu: View {
    let plan: TodayPlan.Session
    let editable: Bool
    let struck: Bool

    @Environment(RemoteStore.self) private var store

    private var auto: Bool { plan.stageSource == "auto" }

    var body: some View {
        if editable {
            Menu {
                // 马上按材料缺口算一次，用户选过的关也交回给自动定关（`plan auto-stage`）。
                Button {
                    change(["plan", "auto-stage"])
                } label: {
                    if auto {
                        Label("自动选关", systemImage: "checkmark")
                    } else {
                        Text("自动选关")
                    }
                }
                Divider()
                ForEach(plan.choices, id: \.self) { choice in
                    Button {
                        change(["plan", "set-stage", choice.stage])
                    } label: {
                        if !auto, choice.stage == plan.stage {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(choice.label)
                        }
                    }
                }
                Divider()
                Toggle("刷理智", isOn: Binding(
                    get: { plan.fight },
                    set: { on in change(["plan", "fight", on ? "on" : "off"]) }))
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(store.planChanging != nil)
            .help("换关，或这一场不刷理智")
        } else {
            label.fixedSize()
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            if plan.fight {
                Swatch(code: plan.stage, size: 18, radius: 5)
                Text(plan.stage.isEmpty ? "上次作战" : plan.stage).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                    .strikethrough(struck)
                if let note = sourceNote {
                    Text(note).font(.system(size: 13)).foregroundStyle(WM.f2).lineLimit(1)
                }
            } else {
                Text("不刷理智").font(.system(size: 15)).foregroundStyle(WM.f2).strikethrough(struck)
            }
            if editable {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(WM.f2)
            }
        }
        .padding(.leading, plan.fight ? 8 : 12)
        .padding(.trailing, 12)
        .frame(height: 34)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
        .contentShape(Rectangle())
        .help(dropHelp)
    }

    /// 只在说得出缺什么时才写「缺电极单元」；「你选的」照旧。默认关、说不出缺什么都不加话。
    private var sourceNote: String? {
        switch plan.stageSource {
        case "auto": plan.drops.first.map { "缺\($0.name)" }
        case "discord": "你选的"
        default: nil
        }
    }

    private var dropHelp: String {
        guard plan.stageSource == "auto" else { return "" }
        guard let drop = plan.drops.first else { return "按材料缺口自动定的关" }
        let spare = plan.fallbackStage.isEmpty ? "" : "，剩下的理智去 \(plan.fallbackStage)"
        return "自动定关：还缺 \(drop.count) 个\(drop.name)，刷够就停\(spare)"
    }

    private func change(_ args: [String]) {
        Task { await store.changePlan(plan.phase, args) }
    }
}
