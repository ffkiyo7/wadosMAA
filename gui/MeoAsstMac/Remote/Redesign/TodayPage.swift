//
//  TodayPage.swift
//  Wado's MAA
//
//  首页「今天」：左边是要操作的「手动日常」（原一键长草的「这一次」，K12），右边是早场 / 晚场的
//  计划（`plan today`，点了就改：`plan set-stage` / `skip-today` / `fight`）和游戏资源；
//  下面是自动抄作业的关卡和最近一次。开始走 `run local`，和 Discord「现在跑」同一条路。
//

import SwiftUI

struct TodayPage: View {
    let go: (WMPage) -> Void

    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "今天", caption: Beijing.todayCaption())
                RemoteNotices()
                HStack(alignment: .top, spacing: 16) {
                    ManualRunCard()
                        .frame(maxWidth: .infinity)
                        .layoutPriority(1.65)
                    StatusStack(go: go)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 360)
                }
                CopilotPreviewSection(go: go).padding(.top, 26)
                RecentRunsSection().padding(.top, 26)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .task { await store.reload() }
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

    private var defaultStage: String { store.defaults?.stage ?? "" }

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

    // 关卡胶囊：默认、上次，再补几关；完整列表在「全部关卡…」。
    private func stageChips(_ choices: RunChoices) -> some View {
        var shown: [RunChoices.Choice] = []
        if let def = choices.choices.first(where: { $0.stage == defaultStage }) { shown.append(def) }
        for choice in choices.choices where !shown.contains(choice) && shown.count < 4 {
            shown.append(choice)
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
                    .help("关卡和要做的事回到「日常」里的设置")
                }
                Spacer(minLength: 0)
            }
            // 以锁文件为准（`RemoteStore` 每 2 秒看一眼），`choices.busy` 是加载那一刻的快照，会过期。
            if let holder = store.lockHolder {
                Label("游戏正在用于\(holder.text)", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(WM.game)
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
            if !receipt.ok, !force, receipt.dictionary["blocked"] as? String == "blackout" {
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
        VStack(spacing: 12) {
            sessionsCard
            versionCard
        }
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
                        VStack(alignment: .leading, spacing: 6) {
                            sessionRow(item.0, item.1, now: context.date)
                            if let plan = store.todayPlan?.sessions.first(where: { $0.phase == item.0 }) {
                                SessionPlanView(
                                    plan: plan,
                                    taskNames: store.todayPlan?.taskNames ?? [:],
                                    editable: !store.readOnly && startedToday(item.0, now: context.date) == nil)
                            }
                        }
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

    private func sessionRow(_ phase: String, _ name: String, now: Date) -> some View {
        let session = store.schedule?.sessions[phase]
        let state = sessionState(phase, session, now: now)
        return HStack(spacing: 8) {
            Image(systemName: state.icon).foregroundStyle(state.color).help(state.tip)
            Text(name).fontWeight(.semibold).frame(width: 34, alignment: .leading)
            Text(session?.time ?? "—").foregroundStyle(WM.f2).monospacedDigit()
            Spacer()
            Text(state.text).font(.system(size: 11.5)).foregroundStyle(WM.f2)
        }
    }

    /// 这一场今天已经开始过（正在跑或跑完了）就返回开始时间：这时再改计划也不影响它。
    private func startedToday(_ phase: String, now: Date) -> Date? {
        guard store.lastRun["phase"]?.string == phase,
            let started = store.lastRun["started_at"]?.string.flatMap(RunLock.parseISO),
            Beijing.calendar.isDate(started, inSameDayAs: now)
        else { return nil }
        return started
    }

    private func sessionState(_ phase: String, _ session: ScheduleReport.Session?, now: Date)
        -> (icon: String, color: Color, text: String, tip: String)
    {
        guard let session else { return ("circle.dashed", WM.f3, "读不到", "暂时读不到时间") }
        if !session.enabled { return ("pause.circle", WM.f3, "已关", "到点不自动开始") }
        if let started = startedToday(phase, now: now) {
            let status = store.lastRun["status"]?.string ?? ""
            let finished = store.lastRun["finished_at"]?.string.flatMap(RunLock.parseISO)
            let clock = finished.map(RunLock.beijingClock) ?? RunLock.beijingClock(started)
            let summary = store.lastRun["summary"]?.displayText ?? ""
            let word = LastRunText.statusWord(status)
            switch status {
            case "success": return ("checkmark.circle", WM.ok, "\(clock) \(word)", summary)
            case "skipped": return ("minus.circle", WM.f3, word, summary)
            case _ where LastRunText.ongoing.contains(status): return ("play.circle", WM.game, word, "正在进行")
            default: return ("exclamationmark.circle", WM.danger, "\(clock) \(word)", summary)
            }
        }
        if store.todayPlan?.sessions.first(where: { $0.phase == phase })?.skip == true {
            return ("minus.circle", WM.f3, "今天跳过", "到点不跑这一场")
        }
        if let date = Beijing.today(at: session.time, now: now), date > now {
            return ("circle.dashed", WM.f2, Beijing.until(date, from: now), "还没开始")
        }
        return ("minus.circle", WM.f3, "今天没跑", "今天没有记录")
    }

    /// 游戏资源：今天更新过没有；版本号放在悬停提示里。
    private var versionCard: some View {
        let status = store.upstream
        let verdict = verdictShort(status)
        let needsUpdate = status.map { !$0.fresh || $0.online?.maaResourceOutdated == true } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                key("arrow.down.circle", "游戏资源")
                Spacer()
                Text(verdict.text).font(.system(size: 11.5)).foregroundStyle(verdict.color)
            }
            .help(versionHelp(status))
            if needsUpdate, status?.running != true {
                GameButton(title: "现在更新", help: updateHelp(status)) {
                    GameConfirm(title: "更新游戏资源？", rows: [("用时", "大约 3 分钟，期间不能开始日常")], ok: "更新") {
                        Task {
                            await store.perform(["upstream", "update"])
                            _ = await RemoteGate.waitForUpdate()
                            await store.reload()
                        }
                    }
                }
                .disabled(!(status?.updateBlocked ?? "x").isEmpty || store.busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wmCard()
    }

    private func versionHelp(_ status: UpstreamStatus?) -> String {
        let version = status?.versions.maaCore ?? "未知"
        if status?.verdict == "blocked" {
            return "游戏资源状态不对，暂时不能开始日常。请稍后再看，或在设置 › 高级里复制诊断信息。\n版本 \(version)"
        }
        return "版本 \(version)"
    }

    private func updateHelp(_ status: UpstreamStatus?) -> String {
        if let blocked = status?.updateBlocked, !blocked.isEmpty { return "现在不能更新：\(blocked)" }
        return "先确认再更新"
    }

    private func verdictShort(_ status: UpstreamStatus?) -> (text: String, color: Color) {
        guard let status else { return ("没查到", WM.f3) }
        if status.running { return ("正在更新", WM.game) }
        if status.verdict == "blocked" { return ("待确认", WM.game) }
        if status.online?.maaResourceOutdated == true || status.online?.maaCliOutdated == true {
            return ("有新版本", accent.color)
        }
        return status.fresh ? ("今天已更新", WM.ok) : ("今天还没更新", accent.color)
    }
}

/// 一场的计划：刷哪关（谁定的）、做哪些事；没开始前点了就改。
struct SessionPlanView: View {
    let plan: TodayPlan.Session
    let taskNames: [String: String]
    let editable: Bool

    @Environment(RemoteStore.self) private var store

    private static let order = ["fight", "infrast", "recruit", "mall", "award"]

    private var changing: Bool { store.planChanging == plan.phase }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if editable {
                    Menu {
                        stageItems
                        Divider()
                        Toggle("刷理智", isOn: Binding(
                            get: { plan.fight },
                            set: { on in change(["plan", "fight", on ? "on" : "off"]) }))
                    } label: {
                        stageLabel
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(store.planChanging != nil)
                    .help("换关，或这一场不刷理智")
                } else {
                    stageLabel
                }
                Spacer(minLength: 0)
                if changing {
                    ProgressView().controlSize(.mini)
                } else if editable {
                    Button(plan.skip ? "恢复" : "跳过") {
                        change(["plan", "skip-today", plan.skip ? "off" : "on"])
                    }
                    .buttonStyle(WMLinkStyle())
                    .font(.system(size: 11.5))
                    .disabled(store.planChanging != nil)
                    .help(plan.skip ? "到点照常跑这一场" : "今天到点不跑这一场，另一场不受影响")
                }
            }
            Text(tasksText)
                .font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(1)
        }
        .padding(.leading, 26)
        .opacity(plan.skip ? 0.45 : 1)
    }

    @ViewBuilder private var stageItems: some View {
        ForEach(plan.choices, id: \.self) { choice in
            Button {
                change(["plan", "set-stage", choice.stage])
            } label: {
                if choice.stage == plan.stage {
                    Label(choice.label, systemImage: "checkmark")
                } else {
                    Text(choice.label)
                }
            }
        }
    }

    private var stageLabel: some View {
        HStack(spacing: 6) {
            if plan.fight {
                Swatch(code: plan.stage, size: 16, radius: 4)
                Text(plan.stage.isEmpty ? "上次作战" : plan.stage).fontWeight(.semibold).monospacedDigit()
                    .strikethrough(plan.skip)
                if let note = sourceNote {
                    Text(note).font(.system(size: 11)).foregroundStyle(WM.f3).lineLimit(1)
                }
            } else {
                Text("不刷理智").foregroundStyle(WM.f2).strikethrough(plan.skip)
            }
            if editable {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WM.f3)
            }
        }
        .contentShape(Rectangle())
        .help(dropHelp)
    }

    /// 「自动定关：缺电极单元」/「你选的」；默认关不加话。
    private var sourceNote: String? {
        switch plan.stageSource {
        case "auto":
            if let drop = plan.drops.first { return "自动定关：缺\(drop.name)" }
            return "自动定关"
        case "discord": return "你选的"
        default: return nil
        }
    }

    private var dropHelp: String {
        guard plan.stageSource == "auto", let drop = plan.drops.first else { return "" }
        let spare = plan.fallbackStage.isEmpty ? "" : "，剩下的理智去 \(plan.fallbackStage)"
        return "还缺 \(drop.count) 个\(drop.name)，刷够就停\(spare)"
    }

    private var tasksText: String {
        let names = Self.order.filter { plan.tasks[$0] ?? true }.map { taskNames[$0] ?? $0 }
        return names.isEmpty ? "什么都不做" : names.joined(separator: " · ")
    }

    private func change(_ args: [String]) {
        Task { await store.changePlan(plan.phase, args) }
    }
}

// MARK: - 自动抄作业 / 最近一次

struct CopilotPreviewSection: View {
    let go: (WMPage) -> Void
    @Environment(RunData.self) private var data

    var body: some View {
        let todo = data.copilotTodo
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "自动抄作业") {
                Button("全部 ›") { go(.copilot) }.buttonStyle(WMLinkStyle()).help("打开「自动抄作业」")
            }
            VStack(spacing: 0) {
                let rows = Array((todo.isEmpty ? (data.copilot?.stages ?? []) : todo).prefix(4))
                if rows.isEmpty {
                    Text(data.copilotError ?? (data.copilot == nil ? "读取中…" : "现在没有可抄的关"))
                        .foregroundStyle(data.copilotError == nil ? WM.f2 : WM.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { RowDivider() }
                    Button {
                        data.copilotFocus = row.stage
                        go(.copilot)
                    } label: {
                        CopilotStageListRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .help("打开 \(row.stage) 的候选作业")
                }
            }
            .wmCard()
        }
    }
}

struct CopilotStageListRow: View {
    let row: CopilotStageRow

    var body: some View {
        HStack(spacing: 12) {
            Swatch(code: row.stage, size: 24, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.stage).fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(row.status == "cleared" ? WM.f2 : Color.primary)
                if let reason = CopilotText.reason(row) {
                    Text(reason).font(.system(size: 11.5)).foregroundStyle(WM.f2)
                }
            }
            Spacer()
            Text(CopilotText.state(row)).font(.system(size: 12))
                .foregroundStyle(row.status == "cleared" ? WM.ok : WM.f2)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(WM.f3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

enum CopilotText {
    /// 去掉 status_text 前面的 emoji。
    static func status(_ row: CopilotStageRow) -> String {
        let text = row.statusText ?? ""
        return text.drop { !$0.isLetter && !$0.isNumber && $0 != "（" }.trimmingCharacters(in: .whitespaces)
    }

    /// 进不去的关（maa-remote 的 no_nav / not_indexed）统一一个说法，不透出原因原文。
    static func unsupported(_ row: CopilotStageRow) -> Bool {
        row.nav == false || row.status == "no_nav" || row.status == "not_indexed"
    }

    static func state(_ row: CopilotStageRow) -> String {
        if unsupported(row) { return "暂不支持自动前往" }
        return status(row).isEmpty ? "" : status(row)
    }

    /// maa-remote 给的原因；进不去的关、没有原因时不占一行。
    static func reason(_ row: CopilotStageRow) -> String? {
        guard !unsupported(row), let reason = row.reason, !reason.isEmpty else { return nil }
        return reason
    }

    static func detail(_ row: CopilotStageRow) -> String {
        if unsupported(row) { return "暂不支持自动前往" }
        return reason(row) ?? (row.status == "cleared" ? "已通" : "可以去搜作业")
    }
}

struct RecentRunsSection: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "最近一次")
            VStack(spacing: 0) {
                if store.lastRun["status"] == nil {
                    Text("还没有记录").foregroundStyle(WM.f2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    lastRunRow
                }
            }
            .wmCard()
        }
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
                .foregroundStyle(
                    status == "success" ? WM.ok
                        : status == "skipped" ? WM.f3
                        : LastRunText.ongoing.contains(status) ? WM.game : WM.danger)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(run["summary"]?.displayText ?? "")
    }
}
