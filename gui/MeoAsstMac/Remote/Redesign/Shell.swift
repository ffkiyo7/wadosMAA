//
//  Shell.swift
//  Wado's MAA
//
//  重设计的窗口外壳：边栏（今天 / 自动抄作业 / 日程与默认 / 日常配置 / 工具与更多 / 设置）、
//  顶部状态条（空闲或运行中 + 当前阶段、「日志」按钮；环境只在设置里看）、右侧日志检查器、会连游戏的统一确认框。
//

import SwiftUI

enum WMPage: String, CaseIterable, Identifiable, Hashable {
    case today, copilot, schedule, config, tools, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .copilot: "自动抄作业"
        case .schedule: "日程与默认"
        case .config: "日常配置"
        case .tools: "工具与更多"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .copilot: "doc.on.doc"
        case .schedule: "calendar"
        case .config: "slider.horizontal.3"
        case .tools: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }

    var tip: String {
        switch self {
        case .today: "手动开一场、今天的定时场和状态"
        case .copilot: "选关、挑作业、确认开打"
        case .schedule: "早晚场时间、默认关卡和每场环节"
        case .config: "maa-remote 的日常配置，整页保存"
        case .tools: "上游任务（肉鸽、生息演算、任务列表、手贴作业）和实用工具"
        case .settings: "外观、maa-remote、连接与游戏"
        }
    }
}

/// 几个页面共用的 maa-remote 列表数据（关卡选项、抄作业关卡）。
@MainActor @Observable final class RunData {
    var choices: RunChoices?
    var choicesError: String?
    var copilot: CopilotStages?
    var copilotError: String?
    /// 首页点了某关，跳到抄作业页时选中它。
    var copilotFocus: String?

    var copilotTodo: [CopilotStageRow] {
        (copilot?.stages ?? []).filter { $0.status != "cleared" }
    }

    func reset() {
        choices = nil
        choicesError = nil
        copilot = nil
        copilotError = nil
        copilotFocus = nil
    }

    func loadChoices() async {
        do {
            choices = try await RemoteBridge.run(["run", "choices"]).decode(RunChoices.self, snakeCase: false)
            choicesError = nil
        } catch {
            choicesError = error.localizedDescription
        }
    }

    func loadCopilot() async {
        do {
            copilot = try await RemoteBridge.run(["copilot", "stages"]).decode(CopilotStages.self, snakeCase: false)
            copilotError = nil
        } catch {
            copilotError = error.localizedDescription
        }
    }
}

struct RedesignRoot: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Environment(RemoteStore.self) private var store
    @AppStorage(WM.accentKey) private var accent = AccentChoice.gold
    @AppStorage(WM.logKey) private var showLog = false

    @State private var page: WMPage? = .today
    @State private var confirm: GameConfirm?
    @State private var data = RunData()

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 260)
        } detail: {
            detail
                .toolbar { statusBar }
                .inspector(isPresented: $showLog) {
                    LogInspector()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
                }
        }
        // 确认框要在 wmAccent 之内，不然「开始」按钮拿到的是默认的金色。
        .overlay {
            if let confirm {
                GameConfirmSheet(confirm: confirm) { self.confirm = nil }
            }
        }
        // 回执只属于刚才那一页，切页就清掉。
        .onChange(of: page) { store.clearNotice() }
        .environment(\.wmAccent, accent)
        .environment(\.askGame) { confirm = $0 }
        .environment(data)
        .tint(accent.color)
        .preferredColorScheme(.dark)
        // 锁一换人就重拿关卡选项：「现在不能开」的提示（blackout）也可能跟着变。
        .onChange(of: store.lockHolder) { Task { await data.loadChoices() } }
        // 切了 HERMES_HOME 就丢掉旧环境的列表重新拿。
        .task(id: store.homeGeneration) {
            if store.homeGeneration > 0 { data.reset() }
            await data.loadChoices()
            await data.loadCopilot()
        }
    }

    // MARK: 边栏

    private var sidebar: some View {
        List(selection: $page) {
            row(.today)
            row(.copilot, badge: data.copilotTodo.count)
            Section("配置") {
                row(.schedule)
                row(.config)
            }
            Section("更多") {
                row(.tools)
            }
        }
        .safeAreaInset(edge: .bottom) {
            List(selection: $page) { row(.settings) }
                .scrollDisabled(true)
                .frame(height: 44)
        }
    }

    private func row(_ entry: WMPage, badge: Int = 0) -> some View {
        Label {
            Text(entry.title)
        } icon: {
            Image(systemName: entry.icon).foregroundStyle(accent.color)
        }
        .badge(badge > 0 ? Text("\(badge)").monospacedDigit() : nil)
        .help(entry.tip)
        .tag(entry)
    }

    // MARK: 内容

    @ViewBuilder private var detail: some View {
        Group {
            switch page ?? .today {
            case .today: TodayPage(go: { page = $0 })
            case .copilot: CopilotPage()
            case .schedule: SchedulePage()
            case .config: ConfigPage()
            case .tools: ToolsPage()
            case .settings: SettingsPage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        // 一场跑完的战报，哪一页都看得到。
        .overlay(alignment: .top) {
            if let report = store.runReport {
                RunReportBanner(report: report) { store.dismissReport() }
                    .padding(.top, 12)
                    .padding(.horizontal, 28)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.runReport)
    }

    // MARK: 状态条

    @ToolbarContentBuilder private var statusBar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            RunStateView()
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showLog.toggle()
            } label: {
                Label("日志", systemImage: "text.alignleft").labelStyle(.titleAndIcon)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .help("显示或隐藏运行日志 ⌥⌘L")
        }
    }
}

/// 状态条左侧：空闲 / 谁在用游戏。
struct RunStateView: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @Environment(RemoteStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 8) {
                if let busy = busyText {
                    Circle().fill(WM.game).frame(width: 8, height: 8)
                        .background(Circle().fill(WM.game.opacity(0.18)).frame(width: 16, height: 16))
                    Text("运行中").fontWeight(.semibold)
                    Text(busy).foregroundStyle(WM.f2).lineLimit(1)
                    if let stage = remoteStage {
                        Text(stage.label).fontWeight(.medium).lineLimit(1)
                    }
                    ProgressView().progressViewStyle(.linear).frame(width: 140).tint(WM.game)
                    if viewModel.status == .busy {
                        Button {
                            Task { try? await viewModel.stop() }
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }
                        .buttonStyle(WMButtonStyle(kind: .danger))
                        .help("停止本 App 里正在跑的上游任务")
                    }
                } else {
                    Circle().fill(WM.ok).frame(width: 8, height: 8)
                    Text("空闲").fontWeight(.semibold)
                    if let success = lastSuccess(now: context.date) {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WM.ok)
                            Text(success.text).foregroundStyle(WM.f2).monospacedDigit()
                        }
                        .help(success.tip)
                    }
                    if let next = nextSession(now: context.date) {
                        Text("下一场 \(next)").foregroundStyle(WM.f2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .fixedSize()
        }
    }

    private var busyText: String? {
        if viewModel.status != .idle { return "本 App 的上游任务" }
        return store.lockHolder?.text
    }

    /// maa-remote 这一场现在在哪个阶段（「刷理智」）。
    private var remoteStage: RunStage? {
        guard viewModel.status == .idle, store.lockHolder != nil, store.lastRun["status"]?.string == "running"
        else { return nil }
        return store.progress.current
    }

    /// 上次成功：今天只写时刻，昨天写「昨天 22:16」，更早只写日期。判成败只看 `status`。
    private func lastSuccess(now: Date) -> (text: String, tip: String)? {
        let run = store.lastRun
        guard run["status"]?.string == "success",
            let finished = run["finished_at"]?.string.flatMap(RunLock.parseISO)
        else { return nil }
        let clock = RunLock.beijingClock(finished)
        let calendar = Beijing.calendar
        let text =
            if calendar.isDate(finished, inSameDayAs: now) {
                clock
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                calendar.isDate(finished, inSameDayAs: yesterday)
            {
                "昨天 \(clock)"
            } else {
                Beijing.monthDay(finished)
            }
        return (text, "上次成功：\(LastRunText.title(run))，\(Beijing.monthDay(finished)) \(clock)")
    }

    private func nextSession(now: Date) -> String? {
        guard let sessions = store.schedule?.sessions else { return nil }
        let upcoming = [("am", "早场"), ("pm", "晚场")].compactMap { key, name -> (Date, String)? in
            guard let session = sessions[key], session.enabled, let date = Beijing.today(at: session.time, now: now)
            else { return nil }
            let target = date > now ? date : Beijing.calendar.date(byAdding: .day, value: 1, to: date)!
            return (target, "\(name) \(session.time)")
        }
        return upcoming.min { $0.0 < $1.0 }?.1
    }
}

/// 一场跑完的战报：状态、哪一场、几点结束，下面是战报里要紧的几行；悬停看全文。
struct RunReportBanner: View {
    let report: RunReport
    let close: () -> Void

    private var look: (icon: String, color: Color) {
        switch report.status {
        case "success": ("checkmark.circle.fill", WM.ok)
        case "skipped": ("minus.circle.fill", WM.f2)
        default: ("xmark.circle.fill", WM.danger)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: look.icon).font(.system(size: 18)).foregroundStyle(look.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(report.title).fontWeight(.semibold)
                    Text(LastRunText.statusWord(report.status)).foregroundStyle(look.color)
                    if let finished = report.finishedAt {
                        Text(RunLock.beijingClock(finished)).foregroundStyle(WM.f3).monospacedDigit()
                    }
                }
                ForEach(report.lines, id: \.self) { line in
                    Text(line).font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WM.f3)
            .help("关掉")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(look.color.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .help(report.summary)
    }
}

/// 右侧日志检查器：本 App 的运行日志，按时间插进 maa-remote 正在跑的那一场的阶段（不刷 maa-cli 原文）。
struct LogInspector: View {
    @Environment(NewViewModel.self) private var newModel
    @Environment(RemoteStore.self) private var store
    @Environment(\.wmAccent) private var accent

    private enum Row: Identifiable {
        case app(MAALog)
        case stage(RunProgress.Entry)

        var id: UUID {
            switch self {
            case let .app(log): log.id
            case let .stage(entry): entry.id
            }
        }
    }

    /// 两边各自按时间排好，归并成一列；同一时刻阶段行在前。
    private var rows: [Row] {
        let logs = newModel.logs
        let stages = store.progress.entries
        var rows: [Row] = []
        rows.reserveCapacity(logs.count + stages.count)
        var i = 0, j = 0
        while i < logs.count || j < stages.count {
            if j < stages.count, i == logs.count || stages[j].date <= logs[i].date {
                rows.append(.stage(stages[j]))
                j += 1
            } else {
                rows.append(.app(logs[i]))
                i += 1
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("日志").fontWeight(.bold)
                Spacer()
                Button {
                    OpenLogFileView.revealLogInFinder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WM.f2)
                .help("在 Finder 中显示日志文件")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
            ScrollViewReader { proxy in
                let rows = rows
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if rows.isEmpty {
                            Text("还没有日志").foregroundStyle(WM.f3)
                        }
                        ForEach(rows) { row in
                            line(row)
                                .textSelection(.enabled)
                                .id(row.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: rows.count) {
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func line(_ row: Row) -> Text {
        switch row {
        case let .app(log):
            return Text(log.date.formatted(date: .omitted, time: .standard) + " ").foregroundStyle(WM.f3)
                + Text(log.content).foregroundStyle(color(log))
        case let .stage(entry):
            // 打开 App 之前就过去的阶段只知道顺序，时刻那一栏空着。
            let time = entry.date.formatted(date: .omitted, time: .standard)
            let stamp = entry.exact ? time : String(repeating: " ", count: time.count)
            return Text(stamp + " ").foregroundStyle(WM.f3)
                + Text(entry.text).foregroundStyle(color(entry.tone)).fontWeight(entry.tone == .stage ? .regular : .semibold)
        }
    }

    private func color(_ tone: RunProgress.Entry.Tone) -> Color {
        switch tone {
        case .run: accent.color
        case .stage: .primary
        case .ok: WM.ok
        case .error: WM.danger
        }
    }

    private func color(_ log: MAALog) -> Color {
        switch log.color {
        case .error: WM.danger
        case .warning: WM.game
        case .rare: accent.color
        default: WM.f2
        }
    }
}
