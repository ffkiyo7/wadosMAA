//
//  TodayPage.swift
//  Wado's MAA
//
//  首页「今天」：左边是要操作的「手动日常」（原一键长草的「这一次」，K12），右边是早场 / 晚场的
//  计划（`plan today`，点了就改：`plan set-stage` / `skip-today` / `fight`）和游戏资源；
//  下面是自动抄作业的关卡和最近几场（`runs/index.jsonl`，没有记录时退回 `last_run.json` 的最近一次）。
//  开始走 `run local`，和 Discord「现在跑」同一条路。
//

import SwiftUI

struct TodayPage: View {
    let go: (WMPage) -> Void

    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "今天", caption: caption)
                RemoteNotices()
                HStack(alignment: .top, spacing: 16) {
                    ManualRunCard()
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1.65)
                    StatusStack(go: go)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                }
                TodayPending(go: go).padding(.top, 26)
                RecentRunsSection().padding(.top, 26)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .task {
            await store.reload()
            // 活动跟着日子变；进首页顺手重读一次关卡选项（里面带当期活动）。
            await data.loadChoices()
        }
    }

    /// 「11 月 10 日 星期二 · 「时间啊，向前！」11/1–11/22 · 还剩 12 天」。没有活动就只有日期。
    private var caption: String {
        let today = Beijing.todayCaption()
        guard let activity = data.choices?.activity, let start = activity.start, let end = activity.end,
            end > .now
        else { return today }
        return "\(today)  ·  \(activity.name) \(Beijing.slashDay(start))–\(Beijing.slashDay(end)) · \(Beijing.left(until: end))"
    }
}

/// 只读、读失败、刚才那次操作的回执（各页顶部共用）。
struct RemoteNotices: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = store.schemaProblem {
                Label(problem, systemImage: "eye").foregroundStyle(WM.game).font(.system(size: 12))
            }
            if let error = store.loadError {
                NoticeLine(ok: false, text: error)
            }
            if let notice = store.notice {
                NoticeLine(ok: notice.ok, text: notice.text) { store.clearNotice() }
            }
        }
        .padding(.bottom, store.schemaProblem == nil && store.loadError == nil && store.notice == nil ? 0 : 14)
    }
}

// MARK: - 手动日常

struct ManualRunCard: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data
    @Environment(\.wmAccent) private var accent
    @Environment(\.askGame) private var askGame

    @State private var stage: String?
    @State private var switches: [String: Bool] = [:]
    @State private var running = false
    @State private var result: (ok: Bool, text: String)?

    /// 活动期间前置的活动关（只留关卡选项里有的）；没有活动是空的。
    private var activityStages: [String] {
        guard let choices = data.choices, let activity = choices.activity else { return [] }
        let known = Set(choices.choices.map(\.stage))
        return activity.stages.filter { known.contains($0) }
    }

    /// 平时是「日常」里设的默认关；活动期间换成活动关：下一场自动定关选中的活动关，没有就第一个活动关。
    private var defaultStage: String {
        let front = activityStages
        guard let first = front.first else { return store.defaults?.stage ?? "" }
        let next = SessionGate.load().upcoming(within: 24 * 60)?.phase
        let sessions = (store.todayPlan?.sessions ?? []).sorted { $0.phase == next && $1.phase != next }
        return sessions.first { $0.stageSource == "auto" && front.contains($0.stage) }?.stage ?? first
    }

    private func defaultOn(_ key: String) -> Bool { store.defaults?.tasks?[key] ?? true }

    private var currentStage: String { stage ?? defaultStage }

    private var changed: Bool {
        currentStage != defaultStage
            || (data.choices?.switches ?? []).contains { (switches[$0] ?? defaultOn($0)) != defaultOn($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("手动日常").font(.system(size: 15, weight: .bold))
            if let choices = data.choices {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "关卡")
                    stageChips(choices)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "要做的事")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(choices.switches, id: \.self) { key in
                            partTile(key, name: choices.taskNames[key] ?? key)
                        }
                    }
                }
                goRow(choices)
            } else if let error = data.choicesError {
                NoticeLine(ok: false, text: error)
                Button("重试") { Task { await data.loadChoices() } }.buttonStyle(WMButtonStyle())
            } else {
                ProgressView().controlSize(.small)
            }
            if let result {
                NoticeLine(ok: result.ok, text: result.text) { self.result = nil }
            }
        }
        .padding(16)
        .wmCard()
        .autoDismiss(result) { result = nil }
    }

    /// 快到的那一场（和 maa-remote 的「早晚场优先」同一个算法）。
    private var blackoutSlot: SessionGate.Slot? {
        let gate = SessionGate.load()
        return gate.upcoming(within: gate.blackoutMinutes)
    }

    /// 「开始日常」的确认框。早场 / 晚场就要开始了（本地算出来的，或者 maa-remote 刚挡下来的）时，
    /// 同一个确认框带上警告，确认键换成「仍然开始」，确认后带 `--force`（只解除这一条，游戏被占用时照样开不了）。
    private func startConfirm(_ choices: RunChoices, soon: Bool = false) -> GameConfirm {
        let names = choices.switches.filter { switches[$0] ?? defaultOn($0) }.map { choices.taskNames[$0] ?? $0 }
        let rows = [
            ("关卡", currentStage.isEmpty ? "上次作战关卡" : currentStage),
            ("要做的事", names.isEmpty ? "无" : names.joined(separator: "、")),
            ("规矩", "不碎石、不借助战，只吃快过期的理智药"),
        ]
        let slot = blackoutSlot
        guard soon || slot != nil else {
            return GameConfirm(title: "开始手动日常？", rows: rows, ok: "开始") { Task { await start(force: false) } }
        }
        let name = slot?.phase == "pm" ? "晚场" : "早场"
        return GameConfirm(
            title: slot.map { "\($0.label) 就要开始了" } ?? "日常就要开始了",
            rows: rows,
            warning: "现在开始，\(name)可能会因为游戏被占用而跳过。",
            ok: "仍然开始"
        ) { Task { await start(force: true) } }
    }

    // 关卡胶囊：活动期间是活动关和上次作战；平时是默认、上次，再补几关。完整列表在「全部关卡…」。
    private func stageChips(_ choices: RunChoices) -> some View {
        var shown: [RunChoices.Choice] = []
        let front = activityStages
        if front.isEmpty {
            if let def = choices.choices.first(where: { $0.stage == defaultStage }) { shown.append(def) }
            for choice in choices.choices where !shown.contains(choice) && shown.count < 4 {
                shown.append(choice)
            }
        } else {
            shown = front.compactMap { stage in choices.choices.first { $0.stage == stage } }
            if let last = choices.choices.first(where: { $0.stage.isEmpty }) { shown.append(last) }
        }
        if let picked = choices.choices.first(where: { $0.stage == currentStage }), !shown.contains(picked) {
            shown.append(picked)
        }
        return FlowRow(spacing: 8) {
            ForEach(shown, id: \.self) { choice in
                stageChip(choice)
            }
            Menu {
                ForEach(choices.choices, id: \.self) { choice in
                    Button(choice.label) { stage = choice.stage }
                }
            } label: {
                Text("全部关卡…").foregroundStyle(WM.f2)
            }
            .menuStyle(.button)
            .buttonStyle(ChipStyle(selected: false))
            .fixedSize()
        }
    }

    private func stageChip(_ choice: RunChoices.Choice) -> some View {
        let code = choice.stage.isEmpty ? "上次作战" : choice.stage
        let note = choice.stage == defaultStage ? "默认" : choice.stage.isEmpty ? "" : shortNote(choice)
        return Button {
            stage = choice.stage
        } label: {
            HStack(spacing: 8) {
                Swatch(code: choice.stage)
                Text(code).fontWeight(.semibold).monospacedDigit()
                if !note.isEmpty { Text(note).font(.system(size: 11)).foregroundStyle(WM.f3) }
            }
        }
        .buttonStyle(ChipStyle(selected: currentStage == choice.stage))
        .help("\(choice.label)：\(choice.description)")
    }

    private func shortNote(_ choice: RunChoices.Choice) -> String {
        choice.label.components(separatedBy: " · ").dropFirst().first ?? ""
    }

    private func partTile(_ key: String, name: String) -> some View {
        let on = switches[key] ?? defaultOn(key)
        return Button {
            switches[key] = !on
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(on ? accent.color : Color.clear)
                    RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : WM.f3, lineWidth: 1.5)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(accent.ink)
                    }
                }
                .frame(width: 16, height: 16)
                Text(name).foregroundStyle(on ? Color.primary : WM.f3)
                Spacer(minLength: 0)
                if on != defaultOn(key) {
                    Text("已改").font(.system(size: 10.5)).foregroundStyle(WM.f3)
                        .help("和默认不同，只对这次生效")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(WM.raise, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WM.line, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "这次做「\(name)」，点一下跳过" : "这次跳过「\(name)」，点一下加回")
    }

    private func goRow(_ choices: RunChoices) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(WM.line).frame(height: 1)
            HStack(spacing: 12) {
                GameButton(title: "开始日常", help: "先确认再开始", big: true) { startConfirm(choices) }
                .disabled(running || store.readOnly || store.lockHolder != nil)
                if running { ProgressView().controlSize(.small) }
                if changed {
                    Button("恢复默认") {
                        stage = nil
                        switches = [:]
                    }
                    .buttonStyle(WMLinkStyle())
                    .font(.system(size: 11.5))
                    .help(activityStages.isEmpty ? "关卡和要做的事回到「日常」里的设置" : "关卡回到活动关，要做的事回到「日常」里的设置")
                }
                Spacer(minLength: 0)
            }
            // 以锁文件为准（`RemoteStore` 每 2 秒看一眼），`choices.busy` 是加载那一刻的快照，会过期。
            if let holder = store.lockHolder {
                HStack(spacing: 10) {
                    Label("游戏正在用于\(holder.text)", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(WM.game)
                    Spacer(minLength: 0)
                    StopRunButton()
                }
            } else if !choices.blackout.isEmpty {
                Label(choices.blackout, systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 12)).foregroundStyle(WM.game)
            }
        }
    }

    private func start(force: Bool) async {
        guard let choices = data.choices else { return }
        result = nil
        running = true
        defer { running = false }
        var payloadDict: [String: Bool] = [:]
        for key in choices.switches { payloadDict[key] = switches[key] ?? defaultOn(key) }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var args = ["run", "local", currentStage, payload]
        if force { args.append("--force") }
        do {
            let receipt = try await RemoteBridge.run(args)
            result = (receipt.ok, receipt.message)
            // 确认时还没到、开始时刚好到了：再问一次，还是同一个确认框。
            if !receipt.ok, !force, receipt.code == "session_soon" || receipt.dictionary["blocked"] as? String == "blackout" {
                result = nil
                askGame(startConfirm(choices, soon: true))
            }
        } catch {
            result = (false, error.localizedDescription)
        }
        await data.loadChoices()
    }
}

struct ChipStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.wmAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? accent.color.mix(with: WM.raise, by: 0.88) : WM.raise))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? accent.color : WM.line, lineWidth: selected ? 1.5 : 0.5))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

/// 换行排列。
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (maxX, y + rowHeight)
    }
}

// MARK: - 右栏状态

struct StatusStack: View {
    let go: (WMPage) -> Void
    @Environment(RemoteStore.self) private var store
    @Environment(\.wmAccent) private var accent

    var body: some View {
        sessionsCard
    }

    private func key(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(WM.f2)
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                key("calendar", "今天的日常")
                Spacer()
                Button("日常 ›") { go(.daily) }.buttonStyle(WMLinkStyle()).help("打开「日常」")
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 10) {
                    ForEach(Array([("am", "早场"), ("pm", "晚场")].enumerated()), id: \.element.0) { index, item in
                        if index > 0 { RowDivider() }
                        SessionBlock(phase: item.0, name: item.1, now: context.date)
                    }
                }
            }
            if store.schedule == nil, let error = store.scheduleError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(WM.danger)
            }
            if store.todayPlan == nil, let error = store.todayPlanError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(WM.danger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wmCard()
    }
}

/// 一场今天的结果。正在跑的看 `last_run.json`；跑完的看 `runs/index.jsonl`，
/// 早场、晚场各有一行，晚场开跑不会把早场的结果盖掉。
struct SessionOutcome {
    let status: String
    let started: Date
    let finished: Date?
    /// 没成功 / 跳过的原因（索引里才有）。
    let reason: String

    var ongoing: Bool { LastRunText.ongoing.contains(status) }

    @MainActor static func today(_ phase: String, store: RemoteStore, now: Date) -> SessionOutcome? {
        let calendar = Beijing.calendar
        var live: SessionOutcome?
        let run = store.lastRun
        if run["phase"]?.string == phase,
            let started = run["started_at"]?.string.flatMap(RunLock.parseISO),
            calendar.isDate(started, inSameDayAs: now)
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
                finished: run["finished_at"]?.string.flatMap(RunLock.parseISO), reason: reason)
        }
        let record = store.recentRuns.first {
            $0.phase == phase && $0.startedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        }
        if let record, let started = record.startedAt,
            live.map({ !$0.ongoing && started >= $0.started.addingTimeInterval(-1) }) ?? true
        {
            return SessionOutcome(
                status: record.status, started: started,
                finished: record.durationSeconds.map { started.addingTimeInterval(TimeInterval($0)) },
                reason: record.reason)
        }
        return live
    }
}

/// 首页「今天的日常」里的一场：状态行 + 计划。
/// 右边一列只放一个动作：在跑 → 停止；没成功 → 再跑一次；没开始 → 跳过 / 恢复；关着 → 打开。
struct SessionBlock: View {
    let phase: String
    let name: String
    let now: Date

    @Environment(RemoteStore.self) private var store
    @Environment(\.askGame) private var askGame

    private static let order = ["fight", "infrast", "recruit", "mall", "award"]

    private var session: ScheduleReport.Session? { store.schedule?.sessions[phase] }
    private var plan: TodayPlan.Session? { store.todayPlan?.sessions.first { $0.phase == phase } }
    private var enabledKey: String { "schedule.\(phase).enabled" }
    private var enabled: Bool { store.pendingValue(enabledKey)?.bool ?? session?.enabled ?? true }

    var body: some View {
        let outcome = SessionOutcome.today(phase, store: store, now: now)
        let state = state(outcome)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: state.icon).foregroundStyle(state.color)
                Text(name).fontWeight(.semibold).frame(width: 34, alignment: .leading)
                Text(session?.time ?? "—").foregroundStyle(WM.f2).monospacedDigit()
                Spacer()
                Text(state.text).font(.system(size: 11.5)).foregroundStyle(state.textColor)
            }
            .help(state.tip)
            if let plan {
                planBlock(plan, outcome: outcome)
            }
        }
    }

    // MARK: 状态

    private func state(_ outcome: SessionOutcome?)
        -> (icon: String, color: Color, text: String, textColor: Color, tip: String)
    {
        if let outcome {
            switch outcome.status {
            case "success": return ("checkmark.circle", WM.ok, "完成", WM.ok, "")
            case "skipped": return ("minus.circle", WM.f3, "已跳过", WM.f2, "")
            case "canceled", "cancelled": return ("stop.circle", WM.f3, "已停止", WM.f2, "")
            case _ where outcome.ongoing: return ("play.circle", WM.game, "进行中", WM.game, "")
            default: return ("exclamationmark.circle", WM.danger, "没完成", WM.danger, "")
            }
        }
        guard let session else { return ("circle.dashed", WM.f3, "读不到", WM.f2, "暂时读不到时间") }
        if !enabled { return ("pause.circle", WM.f3, "已关", WM.f2, "到点不自动开始") }
        if plan?.skip == true { return ("minus.circle", WM.f3, "今天跳过", WM.f2, "到点不跑这一场") }
        if let date = Beijing.today(at: session.time, now: now), date > now {
            return ("circle.dashed", WM.f2, Beijing.until(date, from: now), WM.f2, "还没开始")
        }
        return ("minus.circle", WM.f3, "今天没跑", WM.f2, "今天没有记录")
    }

    // MARK: 计划

    private func planBlock(_ plan: TodayPlan.Session, outcome: SessionOutcome?) -> some View {
        let dim = outcome == nil && (!enabled || plan.skip)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                SessionStageMenu(
                    plan: plan,
                    editable: outcome == nil && enabled && !store.readOnly,
                    struck: outcome == nil && enabled && plan.skip)
                    .opacity(dim ? 0.45 : 1)
                Spacer(minLength: 0)
                trailing(plan, outcome: outcome)
            }
            if let footer = footer(plan, outcome: outcome) {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(2)
                    .monospacedDigit()
                    .opacity(dim ? 0.45 : 1)
            }
        }
        .padding(.leading, 26)
    }

    /// 跑过了：起止时间和原因；没跑：只在有事不做时说一句，全做就不占行。
    private func footer(_ plan: TodayPlan.Session, outcome: SessionOutcome?) -> String? {
        if let outcome {
            if outcome.ongoing { return "\(RunLock.beijingClock(outcome.started)) 开始" }
            if outcome.status == "skipped" { return outcome.reason.isEmpty ? nil : outcome.reason }
            var text = RunLock.beijingClock(outcome.started)
            if let finished = outcome.finished { text += "–\(RunLock.beijingClock(finished))" }
            if !outcome.reason.isEmpty { text += " · \(outcome.reason)" }
            return text
        }
        let off = Self.order.dropFirst().filter { plan.tasks[$0] == false }
            .map { store.todayPlan?.taskNames[$0] ?? $0 }
        return off.isEmpty ? nil : "不做\(off.joined(separator: "、"))"
    }

    @ViewBuilder private func trailing(_ plan: TodayPlan.Session, outcome: SessionOutcome?) -> some View {
        if let outcome {
            if outcome.ongoing {
                if store.cancelableRun?.name == "\(name)日常" { StopRunButton() }
            } else if outcome.status != "success", outcome.status != "skipped",
                store.lockHolder == nil, !store.readOnly
            {
                Button("再跑一次") { askGame(retryConfirm(plan)) }
                    .buttonStyle(QuietLinkStyle())
                    .help("按这一场的计划马上再跑一次")
            }
        } else if store.readOnly {
            EmptyView()
        } else if !enabled {
            Button("打开") {
                Task {
                    await store.change(
                        ["schedule", "enable", phase], undo: ["schedule", "disable", phase],
                        pendingKey: enabledKey, pendingValue: .bool(true))
                }
            }
            .buttonStyle(QuietLinkStyle())
            .help("到点自动开始")
        } else if store.planChanging == phase {
            ProgressView().controlSize(.mini)
        } else {
            Button(plan.skip ? "恢复" : "跳过") {
                Task { await store.changePlan(phase, ["plan", "skip-today", plan.skip ? "off" : "on"]) }
            }
            .buttonStyle(QuietLinkStyle())
            .disabled(store.planChanging != nil)
            .help(plan.skip ? "到点照常跑这一场" : "今天到点不跑这一场，另一场不受影响")
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

/// 场卡里的次要动作：灰字，不和标题栏的「日常 ›」抢颜色。
private struct QuietLinkStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5))
            .foregroundStyle(WM.f2)
            .underline(configuration.isPressed)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

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
            label
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if plan.fight {
                Swatch(code: plan.stage, size: 16, radius: 4)
                Text(plan.stage.isEmpty ? "上次作战" : plan.stage).fontWeight(.semibold).monospacedDigit()
                    .strikethrough(struck)
                if let note = sourceNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(WM.f3).lineLimit(1)
                }
            } else {
                Text("不刷理智").foregroundStyle(WM.f2).strikethrough(struck)
            }
            if editable {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WM.f3)
            }
        }
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

// MARK: - 最近几场

struct RecentRunsSection: View {
    @Environment(RemoteStore.self) private var store

    /// 正在跑的那一场还没进索引，先放在最上面。
    private var running: Bool {
        LastRunText.ongoing.contains(store.lastRun["status"]?.string ?? "") && store.lastRun["status"] != nil
    }

    var body: some View {
        let runs = Array(store.recentRuns.prefix(RunHistory.shown))
        VStack(alignment: .leading, spacing: 0) {
            if runs.isEmpty {
                SectionTitle(title: "最近一次")
            } else {
                SectionTitle(title: "最近几场") { rateText }
            }
            VStack(spacing: 0) {
                if runs.isEmpty {
                    if store.lastRun["status"] == nil {
                        Text("还没有记录").foregroundStyle(WM.f2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    } else {
                        lastRunRow
                    }
                } else {
                    if running {
                        lastRunRow
                        RowDivider()
                    }
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { RowDivider() }
                        recordRow(run)
                    }
                }
            }
            .wmCard()
        }
    }

    @ViewBuilder private var rateText: some View {
        if let rate = RunHistory.successRate(store.recentRuns) {
            Text("近 \(rate.total) 场成功 \(rate.ok * 100 / rate.total)%")
                .font(.system(size: 12)).foregroundStyle(WM.f2).monospacedDigit()
                .help("\(rate.total) 场里成功 \(rate.ok) 场，跳过和停下的不算")
        }
    }

    private func recordRow(_ run: RunRecord) -> some View {
        var when = run.startedAt.map { "\(Beijing.monthDay($0)) \(RunLock.beijingClock($0))" } ?? ""
        if let seconds = run.durationSeconds, run.status != "skipped" {
            when += (when.isEmpty ? "" : " · ") + RunHistory.durationText(seconds)
        }
        return HStack(spacing: 12) {
            Swatch(code: run.stage, size: 24, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).fontWeight(.semibold)
                Text(when).font(.system(size: 11.5)).foregroundStyle(WM.f2).monospacedDigit().lineLimit(1)
            }
            Spacer()
            Text(LastRunText.statusWord(run.status))
                .font(.system(size: 12))
                .foregroundStyle(Self.statusColor(run.status))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(run.reason)
    }

    static func statusColor(_ status: String) -> Color {
        status == "success" ? WM.ok
            : status == "skipped" || status == "cancelled" ? WM.f3
            : LastRunText.ongoing.contains(status) ? WM.game : WM.danger
    }

    private var lastRunRow: some View {
        let run = store.lastRun
        // 抄作业（phase 是 copilot-<token>）没有 plan，关卡在顶层 stage；下面一行用 summary。
        let plan = LastRunText.isCopilot(run) ? nil : run["plan"]?.object
        let stage = LastRunText.stage(run)
        let names = ["fight": "刷理智", "infrast": "基建", "recruit": "公招", "mall": "信用商店", "award": "领奖"]
        let tasks = Set((plan?["tasks"]?.object ?? [:]).filter { $0.value.bool == true }.keys)
        let order = ["fight", "infrast", "recruit", "mall", "award"]
        let taskText = order.filter { tasks.contains($0) }.compactMap { names[$0] }.joined(separator: "、")
        let started = run["started_at"]?.string.flatMap(RunLock.parseISO)
        let status = run["status"]?.string ?? ""
        let title = LastRunText.title(run)
        return HStack(spacing: 12) {
            Swatch(code: stage, size: 24, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(taskText.isEmpty ? (run["summary"]?.displayText ?? "") : taskText)
                    .font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(1)
            }
            Spacer()
            if let started {
                Text("\(Beijing.monthDay(started)) \(RunLock.beijingClock(started))")
                    .font(.system(size: 12)).foregroundStyle(WM.f2).monospacedDigit()
            }
            Text(LastRunText.statusWord(status))
                .font(.system(size: 12))
                .foregroundStyle(Self.statusColor(status))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(run["summary"]?.displayText ?? "")
    }
}
