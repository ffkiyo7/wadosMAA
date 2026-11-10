//
//  TodayPage.swift
//  Wado's MAA
//
//  首页「今天」，从上到下：页头（日期、当期活动）、早场 / 晚场两张大卡（`TodaySessions.swift`）、
//  手动日常、待处理（`TodayPending.swift`）、最近几场。
//

import SwiftUI

struct TodayPage: View {
    let go: (WMPage) -> Void

    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if RemoteNotices.any(store) { RemoteNotices(gap: 0) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    // 进行中的那张展开，另一张不跟着拉伸。
                    HStack(alignment: .top, spacing: 14) {
                        SessionCard(phase: "am", name: "早场", now: context.date)
                        SessionCard(phase: "pm", name: "晚场", now: context.date)
                    }
                }
                ForEach([store.schedule == nil ? store.scheduleError : nil, store.todayPlan == nil ? store.todayPlanError : nil]
                    .compactMap { $0 }, id: \.self)
                { error in
                    Text(error).font(.system(size: 12)).foregroundStyle(WM.danger)
                }
                ManualRunCard()
                TodayPending(go: go)
                RecentRunsSection()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .task {
            await store.reload()
            // 活动跟着日子变；进首页顺手重读一次关卡选项（里面带当期活动）。
            await data.loadChoices()
        }
    }

    /// 「今天 11 月 10 日 星期二」；有活动时右边一个胶囊「『活动名』还剩 N 天」。
    private var header: some View {
        HStack(spacing: 12) {
            Text("今天").font(.system(size: 30, weight: .bold)).tracking(-0.5)
            Text(Beijing.todayCaption()).font(.system(size: 15)).foregroundStyle(WM.f2).padding(.top, 4)
            Spacer(minLength: 0)
            if let activity = data.choices?.activity, let end = activity.end, end > .now {
                HStack(spacing: 8) {
                    Swatch(code: activity.stages.first ?? "", size: 14, radius: 4)
                    Text(activity.name).font(.system(size: 13, weight: .semibold))
                    Text(Beijing.left(until: end)).font(.system(size: 13)).foregroundStyle(WM.f2).monospacedDigit()
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(height: 30)
                .wmCard(radius: 15)
                .help(activity.start.map { "\(Beijing.slashDay($0))–\(Beijing.slashDay(end))" } ?? "")
            }
        }
        .frame(height: 38)
    }
}

/// 只读、读失败、刚才那次操作的回执（各页顶部共用）。
struct RemoteNotices: View {
    /// 下面留多少空：首页的区块之间本来就有间距，传 0。
    var gap: CGFloat = 14
    @Environment(RemoteStore.self) private var store

    /// 有没有要显示的。
    static func any(_ store: RemoteStore) -> Bool {
        store.schemaProblem != nil || store.loadError != nil || store.notice != nil
    }

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
        .padding(.bottom, Self.any(store) ? gap : 0)
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
