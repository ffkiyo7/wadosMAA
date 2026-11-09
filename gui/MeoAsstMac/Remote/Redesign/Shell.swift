//
//  Shell.swift
//  Wado's MAA
//
//  重设计的窗口外壳：边栏（今天 / 自动抄作业 / 日程与默认 / 日常配置 / 设置）、
//  顶部状态条（一个胶囊：空闲或运行中 + 做到哪，点开看详情；「日志」按钮）、右侧日志检查器（「本场」卡片 +
//  本场 / App 两段）、会连游戏的统一确认框（系统 `.confirmationDialog`）。
//

import SwiftUI

enum WMPage: String, CaseIterable, Identifiable, Hashable {
    case today, copilot, schedule, config, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .copilot: "自动抄作业"
        case .schedule: "日程与默认"
        case .config: "日常配置"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .today: "sun.max"
        case .copilot: "doc.on.doc"
        case .schedule: "calendar"
        case .config: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }

    var tip: String {
        switch self {
        case .today: "手动日常、今天的早晚场和状态"
        case .copilot: "选关、挑作业、开打"
        case .schedule: "早晚场时间、默认关卡和要做的事"
        case .config: "日常怎么刷，整页保存"
        case .settings: "外观和日志文件"
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
    @Environment(RemoteStore.self) private var store
    @AppStorage(WM.accentKey) private var accent = AccentChoice.gold
    @AppStorage(WM.logKey) private var showLog = false

    @State private var page: WMPage? = .today
    @State private var confirm: GameConfirm?
    @State private var data = RunData()
    /// 详情栏宽度：状态条胶囊按它退化（打开日志后会窄到约 390pt）。
    @State private var detailWidth: CGFloat = 800

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 260)
        } detail: {
            detail
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
                .toolbar { statusBar }
                .inspector(isPresented: $showLog) {
                    LogInspector()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
                }
        }
        // 会连游戏的操作只有这一种确认框；就要到早场 / 晚场时，警告和「仍然开始」也在这里面。
        .confirmationDialog(
            confirm?.title ?? "",
            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
            titleVisibility: .visible,
            presenting: confirm
        ) { confirm in
            Button(confirm.ok, role: confirm.warning == nil ? nil : .destructive) { confirm.action() }
            Button("取消", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
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
            RunStateView(width: detailWidth)
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

/// 状态条左侧的胶囊：空闲 / 谁在用游戏 + 做到哪了；点开看是哪一场、步骤条和「停止」。
///
/// 宽度按详情栏宽度退化（工具栏项按理想宽度排，`ViewThatFits` 在这里总会挑最宽的那个，所以不用它）：
/// 运行中「● 早场日常 · 刷理智 3/≈7 ◔」→「● 刷理智 3/≈7 ◔」→「● 刷理智」；
/// 空闲「● 空闲 ✓ 22:16 下次 早场日常 08:00」→「● 空闲 下次 早场日常 08:00」→「● 空闲」。
struct RunStateView: View {
    @Environment(RemoteStore.self) private var store

    /// 详情栏现在多宽。
    let width: CGFloat

    @State private var showDetail = false
    @State private var confirmStop: LockHolder?
    @State private var stopping = false

    private enum Fit { case full, medium, compact }

    /// 详情栏还要放「日志」按钮和两侧留白，约 130pt；剩下的给胶囊。
    private func fit(busy: Bool) -> Fit {
        let room = width - 130
        if busy { return room >= (etaText == nil ? 230 : 300) ? .full : room >= 150 ? .medium : .compact }
        return room >= 270 ? .full : room >= 200 ? .medium : .compact
    }

    var body: some View {
        Button {
            showDetail.toggle()
        } label: {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                capsule(now: context.date)
                    .padding(.horizontal, 10)
                    .fixedSize()
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("看这一场做到哪了")
        .popover(isPresented: $showDetail, arrowEdge: .bottom) {
            detailPopover
                .padding(16)
                .frame(width: 340, alignment: .leading)
        }
        .alert(
            "停止\(confirmStop?.name ?? "")？",
            isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } })
        ) {
            Button("停止", role: .destructive) { Task { await stop() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已经打完的不受影响，游戏会被关掉。")
        }
    }

    // MARK: 胶囊

    @ViewBuilder private func capsule(now: Date) -> some View {
        if busyText != nil {
            let fit = fit(busy: true)
            HStack(spacing: 6) {
                dot(WM.game)
                if fit == .full, let name = runName, name != doing {
                    Text(name).foregroundStyle(WM.f2).lineLimit(1)
                    Text("·").foregroundStyle(WM.f3)
                }
                Text(doing).fontWeight(.semibold).lineLimit(1)
                if fit != .compact {
                    if let count = fightCount {
                        Text(count).monospacedDigit()
                    }
                    if let fraction = liveFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .tint(WM.game)
                    }
                }
                if fit == .full, let eta = etaText {
                    Text(eta).foregroundStyle(WM.f2).monospacedDigit().lineLimit(1)
                }
            }
        } else {
            let fit = fit(busy: false)
            HStack(spacing: 6) {
                dot(WM.ok)
                Text("空闲").fontWeight(.semibold)
                if fit == .full, let success = lastSuccess(now: now) {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(WM.ok)
                        Text(success.text).foregroundStyle(WM.f2).monospacedDigit()
                    }
                }
                if fit != .compact, let next = nextSession(now: now) {
                    Text("下次 \(next)").foregroundStyle(WM.f2).lineLimit(1)
                }
            }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .background(Circle().fill(color.opacity(0.18)).frame(width: 16, height: 16))
    }

    // MARK: 弹出框

    @ViewBuilder private var detailPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let busy = busyText {
                if liveRun {
                    RunSessionSummary(progress: store.progress, doing: remoteStage?.doing)
                } else {
                    Text(busy).fontWeight(.semibold)
                }
                if let run = cancelableRun {
                    Button {
                        showDetail = false
                        confirmStop = run
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .buttonStyle(WMButtonStyle(kind: .danger))
                    .disabled(stopping)
                    .help("停下正在跑的\(run.name)")
                }
            } else {
                Text("空闲").fontWeight(.semibold)
                if let success = lastSuccess(now: Date()) {
                    Text(success.tip).foregroundStyle(WM.f2)
                }
                if let next = nextSession(now: Date()) {
                    Text("下次 \(next)").foregroundStyle(WM.f2)
                }
            }
        }
        .font(.system(size: 12.5))
    }

    // MARK: 数据

    /// maa-remote 正在跑、可以从这里停下的那一场（日常或抄作业）。
    private var cancelableRun: LockHolder? {
        guard let holder = store.lockHolder,
            ["daily", "copilot"].contains(holder.holder)  // copy-guard: ignore
        else { return nil }
        return holder
    }

    /// `run cancel`：给那一场发停止信号，它自己关游戏、发战报；回执显示出来，再刷新状态。
    private func stop() async {
        stopping = true
        defer { stopping = false }
        do {
            let receipt = try await RemoteBridge.run(["run", "cancel"])  // copy-guard: ignore
            store.post(receipt.ok, receipt.message)
        } catch {
            store.post(false, "没能停下，稍后再试。")
        }
        await store.reload()
    }

    private var busyText: String? {
        store.lockHolder?.text
    }

    /// 日常 / 抄作业正在跑，`RunProgress` 跟着它。
    private var liveRun: Bool {
        store.lockHolder != nil && store.lastRun["status"]?.string == "running"
            && store.progress.hasRun && store.progress.outcome == nil
    }

    /// 「早场日常」「抄作业 SR-8」。
    private var runName: String? {
        store.lockHolder?.name
    }

    /// 胶囊上的主词：现在做的那件事（「刷理智」）；还没到第一件事时是这一场的名字。
    private var doing: String {
        remoteStage?.label ?? runName ?? "运行中"
    }

    private var fightCount: String? {
        remoteStage?.key == "Fight" ? store.progress.fightText : nil
    }

    /// 「约 08:12 结束」：maa-remote 按历史耗时估的，没有就不显示。
    private var etaText: String? {
        guard liveRun, let eta = store.progress.eta else { return nil }
        return "约 \(RunLock.beijingClock(eta)) 结束"
    }

    private var liveFraction: Double? {
        liveRun ? store.progress.fraction : nil
    }

    /// maa-remote 这一场现在在哪个阶段（「刷理智」）。
    private var remoteStage: RunStage? {
        guard store.lockHolder != nil, store.lastRun["status"]?.string == "running"
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
        let upcoming = [("am", "早场日常"), ("pm", "晚场日常")].compactMap { key, name -> (Date, String)? in
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
        case "cancelled", "canceled": ("stop.circle.fill", WM.f2)
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

/// 右侧日志检查器：顶部固定「本场」卡片（步骤条、进度、本场日志），下面分两段——
/// 「本场」是 maa-remote 正在跑（或刚跑完）的那一场的阶段行，「App」是本 App 的回执记录（`AppLog`）。
struct LogInspector: View {
    @Environment(RemoteStore.self) private var store
    private let appLog = AppLog.shared
    @Environment(\.wmAccent) private var accent

    private enum Tab: Hashable { case run, app }

    @State private var tab = Tab.run

    private enum Row: Identifiable {
        case app(AppLog.Entry)
        case stage(RunProgress.Entry)

        var id: UUID {
            switch self {
            case let .app(log): log.id
            case let .stage(entry): entry.id
            }
        }
    }

    private var rows: [Row] {
        switch tab {
        case .run: store.progress.entries.map(Row.stage)
        case .app: appLog.entries.map(Row.app)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("日志").fontWeight(.bold)
                Spacer()
                Picker("", selection: $tab) {
                    Text("本场").tag(Tab.run)
                    Text("App").tag(Tab.app)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if tab == .app {
                    Button {
                        appLog.revealInFinder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WM.f2)
                    .help("在 Finder 中显示 App 的日志文件")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            if store.progress.hasRun {
                RunSessionCard()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            ScrollViewReader { proxy in
                let rows = rows
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if rows.isEmpty {
                            Text(tab == .run ? "现在没有在跑的日常或抄作业" : "还没有日志").foregroundStyle(WM.f3)
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
                .onChange(of: tab) {
                    if let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func line(_ row: Row) -> Text {
        switch row {
        case let .app(log):
            return Text(log.date.formatted(date: .omitted, time: .standard) + " ").foregroundStyle(WM.f3)
                + Text(log.text).foregroundStyle(log.ok ? WM.f2 : WM.danger)
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
        case .note: WM.game
        }
    }
}
