//
//  ToolsPage.swift
//  Wado's MAA
//
//  工具与更多：上游任务（肉鸽、生息演算、任务列表、手贴作业）+ 实用工具。
//  这些都直接用本 App 里的 MaaCore，不走 maa-remote；开跑前照旧过 RemoteGate（抢锁、查上游和定时场）。
//  原来的页面（任务设置、作业列表、识别结果）原样嵌进来，点进去用。
//

import SwiftUI

enum ToolRoute: Hashable {
    case tasks(UUID?)
    case manualCopilot
    case utility(UtilityEntry)
}

struct ToolsPage: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State private var path: [ToolRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageHeader(title: "工具与更多")
                    SectionTitle(title: "上游任务")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        taskCard("肉鸽", kind: .roguelike)
                        taskCard("生息演算", kind: .reclamation)
                        tool(
                            "任务列表", detail: "\(viewModel.tasks.count) 项上游任务",
                            help: "按上游任务列表开始（不发 Discord 战报）"
                        ) {
                            Button("选项…") { path.append(.tasks(nil)) }.buttonStyle(WMButtonStyle())
                                .help("编辑上游任务列表和每项的设置")
                            GameButton(title: "开始", help: "会连接游戏：按上游任务列表开始") {
                                GameConfirm(title: "按上游任务列表开始？",
                                            rows: [("任务", enabledNames)], ok: "开始") {
                                    Task { await viewModel.tryStartTasks() }
                                }
                            }
                            .disabled(viewModel.status != .idle)
                        }
                        tool("手贴作业", detail: "内置、本地文件、作业集", help: "上游的自动战斗：手动贴作业码") {
                            Button("打开…") { path.append(.manualCopilot) }.buttonStyle(WMButtonStyle())
                                .help("打开上游的作业列表")
                        }
                    }
                    SectionTitle(title: "实用工具").padding(.top, 26)
                    VStack(spacing: 0) {
                        let entries = UtilityEntry.allCases.filter { $0 != .video }
                        ForEach(Array(entries.enumerated()), id: \.element) { index, entry in
                            if index > 0 { RowDivider() }
                            utilityRow(entry)
                        }
                    }
                    .wmCard()
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 40)
            }
            .navigationDestination(for: ToolRoute.self) { route in
                switch route {
                case let .tasks(selected): UpstreamTasksScreen(selection: selected)
                case .manualCopilot:
                    HSplitView {
                        CopilotContent().frame(minWidth: 260, idealWidth: 300)
                        CopilotDetail().frame(minWidth: 420)
                    }
                    .navigationTitle("手贴作业")
                case let .utility(entry):
                    UtilityDetail(entry: entry).navigationTitle(entry.description)
                }
            }
        }
    }

    private var enabledNames: String {
        let names = viewModel.tasks.filter(\.enabled).map { Self.title($0.task) }
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    static func title(_ task: MAATask) -> String {
        switch task {
        case .startup(let c): c.title
        case .closedown(let c): c.title
        case .recruit(let c): c.title
        case .infrast(let c): c.title
        case .fight(let c): c.title
        case .mall(let c): c.title
        case .award(let c): c.title
        case .switchTheme(let c): c.title
        case .roguelike(let c): c.title
        case .reclamation(let c): c.title
        }
    }

    private enum Kind { case roguelike, reclamation }

    private func firstTask(_ kind: Kind) -> DailyTask? {
        viewModel.tasks.first { task in
            switch (kind, task.task) {
            case (.roguelike, .roguelike), (.reclamation, .reclamation): true
            default: false
            }
        }
    }

    private func taskCard(_ name: String, kind: Kind) -> some View {
        let task = firstTask(kind)
        return tool(name, detail: task == nil ? "任务列表里还没有" : "上游任务", help: "上游的\(name)，开跑前先抢游戏锁") {
            Button("选项…") { path.append(.tasks(task?.id)) }.buttonStyle(WMButtonStyle())
                .help(task == nil ? "打开任务列表，用「添加」加一项\(name)" : "\(name)的设置")
            GameButton(title: "开始", help: "会连接游戏：只跑\(name)（加上开始唤醒）") {
                GameConfirm(title: "开始\(name)？", rows: [("任务", "开始唤醒、\(name)")], ok: "开始") {
                    if let task { Task { await runOnly(task.id) } }
                }
            }
            .disabled(task == nil || viewModel.status != .idle)
        }
    }

    /// 只开「开始唤醒」和这一项，跑起来后把勾选还原。
    /// `tryStartTasks()` 会挂起到 Core 开跑，这期间用户可能又改了勾选：只还原仍是我们设的那个值的项，
    /// 用户动过的、新加的都不碰。
    private func runOnly(_ id: UUID) async {
        let saved = Dictionary(uniqueKeysWithValues: viewModel.tasks.map { ($0.id, $0.enabled) })
        var forced: [UUID: Bool] = [:]
        viewModel.tasks = viewModel.tasks.map { task in
            var copy = task
            if case .startup = task.task { copy.enabled = task.enabled } else { copy.enabled = task.id == id }
            forced[task.id] = copy.enabled
            return copy
        }
        await viewModel.tryStartTasks()
        viewModel.tasks = viewModel.tasks.map { task in
            guard let original = saved[task.id], forced[task.id] == task.enabled else { return task }
            var copy = task
            copy.enabled = original
            return copy
        }
    }

    private func tool<Buttons: View>(
        _ name: String, detail: String, help: String, @ViewBuilder buttons: () -> Buttons
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.system(size: 16, weight: .bold)).help(help)
            Text(detail).font(.system(size: 11.5)).foregroundStyle(WM.f2)
            Spacer(minLength: 12)
            FlowRow(spacing: 8) { buttons() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .wmCard()
    }

    private func utilityRow(_ entry: UtilityEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.iconImage).foregroundStyle(Color.accentColor).frame(width: 20)
                .help(entry.description)
            Text(entry.description).fontWeight(.semibold)
            Spacer()
            Button("打开…") { path.append(.utility(entry)) }.buttonStyle(WMButtonStyle())
                .help("打开\(entry.description)（说明和结果）")
            if let recognize = recognizer(entry) {
                GameButton(title: "识别", help: "会连接游戏：开始\(entry.description)识别") {
                    GameConfirm(title: "开始\(entry.description)识别？", ok: "开始") {
                        path.append(.utility(entry))
                        Task { try? await recognize() }
                    }
                }
                .disabled(viewModel.status != .idle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func recognizer(_ entry: UtilityEntry) -> (() async throws -> Void)? {
        switch entry {
        case .recruit: { try await viewModel.recognizeRecruit() }
        case .depot: { try await viewModel.recognizeDepot() }
        case .oper: { try await viewModel.recognizeOperBox() }
        default: nil
        }
    }
}

/// 上游任务列表（原一键长草里折叠的那段）：左边勾选、排序，右边是这项的设置。
struct UpstreamTasksScreen: View {
    @EnvironmentObject private var viewModel: MAAViewModel
    @State var selection: UUID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach($viewModel.tasks, id: \.id) { $task in
                    switch task.task {
                    case .startup(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .closedown(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .recruit(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .infrast(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .fight(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .mall(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .award(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .switchTheme(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .roguelike(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    case .reclamation(let config): TaskCell(id: task.id, config: config, enabled: $task.enabled)
                    }
                }
                .onMove { viewModel.tasks.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minWidth: 220, idealWidth: 260)
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("删除", role: .destructive) {
                    for id in ids where viewModel.tasks.count > 1 { viewModel.tasks.remove(id: id) }
                }
            }
            TaskDetail(id: selection).frame(minWidth: 420)
        }
        .navigationTitle("任务列表")
        .onReceive(viewModel.$newTaskAdded) { added in
            if added { selection = viewModel.tasks.last?.id }
        }
    }
}
