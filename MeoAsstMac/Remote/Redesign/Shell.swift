//
//  Shell.swift
//  Wado's MAA
//
//  重设计的窗口外壳：边栏（今天 / 自动抄作业 / 日程与默认 / 日常配置 / 工具与更多 / 设置）、
//  顶部状态条（空闲或运行中、「日志」按钮；环境只在设置里看）、右侧日志检查器、会连游戏的统一确认框。
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

/// 右侧日志检查器：本 App 的运行日志。
struct LogInspector: View {
    @Environment(NewViewModel.self) private var newModel
    @Environment(\.wmAccent) private var accent

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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if newModel.logs.isEmpty {
                            Text("还没有日志").foregroundStyle(WM.f3)
                        }
                        ForEach(newModel.logs) { log in
                            (Text(log.date.formatted(date: .omitted, time: .standard) + " ")
                                .foregroundStyle(WM.f3)
                                + Text(log.content).foregroundStyle(color(log)))
                                .textSelection(.enabled)
                                .id(log.id)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .lineSpacing(3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: newModel.logs.count) {
                    if let last = newModel.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
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
