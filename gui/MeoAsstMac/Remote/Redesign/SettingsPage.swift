//
//  SettingsPage.swift
//  Wado's MAA
//
//  设置：外观（强调色、背景图、玻璃卡片）、日志文件、账号（森空岛）、游戏与设备；
//  底部默认收起的「高级」：日常 / 抄作业页没放的配置项（超时、重试、自动定关参数、日志保留），
//  再加环境、HERMES_HOME、Python、cron（给维护的人用，普通界面不出现这些词）。
//

import SwiftUI
import WadosMAAShared

struct SettingsPage: View {
    @AppStorage(WM.accentKey) private var accent = AccentChoice.gold
    @AppStorage(AppearanceKeys.glass) private var glass = true
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""

    @Environment(RemoteStore.self) private var store
    @State private var showBackground = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "设置")
                VStack(alignment: .leading, spacing: 0) {
                    FormGroup(title: "外观") {
                        FormRow(title: "强调色") {
                            HStack(spacing: 10) {
                                ForEach(AccentChoice.allCases) { choice in
                                    Button { accent = choice } label: {
                                        Circle().fill(choice.color).frame(width: 26, height: 26)
                                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                            .padding(3)
                                            .overlay(Circle().strokeBorder(accent == choice ? Color.primary : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                    .help(choice.name)
                                }
                            }
                        }
                        FormRow(title: "背景图", sub: backgroundText, help: "浅色、深色各一张；只设一张时共用") {
                            Button("选择…") { showBackground = true }.buttonStyle(WMButtonStyle())
                                .help("选背景图，调填充、遮罩和模糊")
                        }
                        FormRow(title: "玻璃卡片", help: "有背景图时，卡片用 Liquid Glass") {
                            Toggle("玻璃卡片", isOn: $glass).toggleStyle(.switch).labelsHidden()
                                .help("有背景图时，卡片用 Liquid Glass")
                        }
                    }
                    FormGroup(title: "日志") {
                        FormRow(title: "本场日志", help: "最近一场日常或抄作业的完整日志") {
                            let url = AppLog.runLogURL(store.lastRun)
                            Button("打开") { if let url { NSWorkspace.shared.open(url) } }
                                .buttonStyle(WMButtonStyle())
                                .disabled(url == nil)
                        }
                        FormRow(title: "App 日志", help: "本 App 每次操作的结果") {
                            Button("在 Finder 中显示") { AppLog.shared.revealInFinder() }
                                .buttonStyle(WMButtonStyle())
                        }
                    }
                    FormGroup(title: "账号") {
                        ConfigFieldRow(key: "skland_roster_refresh_days", title: "森空岛干员练度多久强制刷新")
                    }
                    FormGroup(title: "游戏与设备") {
                        ConfigFieldRow(key: "game_display_name") { value in
                            (value.string ?? "").isEmpty ? "不挪游戏窗口" : nil
                        }
                        ConfigFieldRow(key: "disable_stage_manager_during_run")
                        FormRow(title: "游戏资源版本", sub: resourceUpdated, help: "首页在有新版本、今天还没更新时会提示") {
                            Text(store.upstream?.versions.maaCore ?? "未知")
                                .foregroundStyle(WM.f2).monospacedDigit().textSelection(.enabled)
                        }
                    }
                    .disabled(store.readOnly)
                    // copy-guard: developer
                    AdvancedSection()
                    // copy-guard: end
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showBackground) {
            VStack(spacing: 0) {
                AppearanceSettingsView()
                HStack {
                    Spacer()
                    Button("完成") { showBackground = false }.buttonStyle(WMButtonStyle(kind: .accent))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
            .frame(minWidth: 480, minHeight: 360)
        }
    }

    /// 「11 月 10 日 08:03 更新」；没成功更新过就不写。
    private var resourceUpdated: String? {
        guard let date = store.upstream?.lastSuccessAt.flatMap(RunLock.parseISO) else { return nil }
        return "\(Beijing.monthDay(date)) \(RunLock.beijingClock(date)) 更新"
    }

    private var backgroundText: String {
        let names = [lightPath, darkPath].filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent }
        return names.isEmpty ? "未设置" : names.joined(separator: "、")
    }
}

// copy-guard: developer
/// 高级：默认收起，每次进设置页都重新收起。先是别的页没放的配置项（按 maa-remote 的分组），
/// 再是开发者用的（环境、HERMES_HOME、Python、cron、诊断）。这里的字是给维护的人看的，可以用技术词。
struct AdvancedSection: View {
    /// 日常页、抄作业规则、设置页上面已经放了的配置项。
    static let placed: Set<String> = DailyPage.keys.union(CopilotRules.keys).union([
        "session_schedule", "skland_roster_refresh_days", "game_display_name", "disable_stage_manager_during_run",
    ])
    /// 分组排序和显示名：算法参数在前，运行相关在后。
    static let groupTitles: [(String, String)] = [("自动定关", "自动定关"), ("日常", "代理指挥"), ("运行", "运行")]

    @Environment(RemoteStore.self) private var store
    @AppStorage(RemoteConfig.hermesHomeKey) private var hermesHome = ""
    @AppStorage(RemoteConfig.pythonKey) private var python = ""

    @State private var expanded = false
    @State private var askLive = false
    @State private var showCron = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("高级")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(WM.f3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.top, 28)
            if expanded {
                ForEach(groups, id: \.title) { group in
                    FormGroup(title: group.title) {
                        ForEach(group.fields) { field in
                            ConfigFieldControl(field: field)
                        }
                    }
                    .disabled(store.readOnly)
                }
                FormGroup(title: "开发者") {
                    FormRow(title: "环境", help: "开发 = 开发副本，不改线上、不发 Discord") {
                        Picker("环境", selection: envBinding) {
                            Text("开发").tag(false)
                            Text("线上").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("切到线上之前先读 PLAN_MACGUI 的 S7")
                    }
                    FormRow(title: "HERMES_HOME", sub: RemoteConfig.hermesHome.path) {
                        TextField("HERMES_HOME", text: $hermesHome, prompt: Text("开发副本"))
                            .labelsHidden().frame(width: 220)
                            .help("留空 = \(RemoteConfig.developmentHermesHome)")
                    }
                    FormRow(title: "Python", sub: RemoteConfig.python) {
                        TextField("Python", text: $python, prompt: Text("自动"))
                            .labelsHidden().frame(width: 220)
                            .help("留空时自动找 Homebrew 的 python3，再退回 /usr/bin/python3")
                    }
                    FormRow(title: "cron 表达式", help: "Hermes 里四条任务的时间") {
                        Button("查看…") { showCron = true }.buttonStyle(WMButtonStyle())
                            .popover(isPresented: $showCron, arrowEdge: .bottom) { cronPopover }
                    }
                    FormRow(title: "对齐 cron 时间", help: "只把 cron 时间对齐到配置，不动暂停状态") {
                        Button("对齐") { Task { await store.perform(["schedule", "sync"]) } }
                            .buttonStyle(WMButtonStyle())
                            .disabled(store.busy || store.readOnly)
                    }
                    FormRow(title: "诊断信息", help: "最近的报错、版本和路径") {
                        Button("复制") { Diagnostics.copy() }.buttonStyle(WMButtonStyle())
                    }
                }
            }
        }
        .alert("切到线上？", isPresented: $askLive) {
            Button("切到线上", role: .destructive) { hermesHome = RemoteConfig.liveHermesHome }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后的改动会写进 \(RemoteConfig.liveHermesHome)，并同步到 Discord。")
        }
    }

    /// 没放在别处的配置项，按分组排；认不出的分组排在最后、用原名。
    private var groups: [(title: String, fields: [ConfigField])] {
        let rest = (store.config?.fields ?? []).filter { !Self.placed.contains($0.key) }
        let known = Self.groupTitles.map(\.0)
        let order = known + (store.config?.groups ?? []).filter { !known.contains($0) }
        return order.compactMap { group in
            let fields = rest.filter { $0.group == group }
            guard !fields.isEmpty else { return nil }
            return (Self.groupTitles.first { $0.0 == group }?.1 ?? group, fields)
        }
    }

    private var envBinding: Binding<Bool> {
        Binding(
            get: { RemoteConfig.isLiveHome },
            set: { live in
                if live { askLive = true } else { hermesHome = "" }
            })
    }

    private var cronPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let schedule = store.schedule {
                Text("时区 \(schedule.timezone)" + (schedule.backend == "daemon" ? " · 内置调度器" : ""))
                    .foregroundStyle(WM.f2)
                ForEach(["am", "pm"], id: \.self) { phase in
                    if let session = schedule.sessions[phase] {
                        if session.cron.isEmpty {
                            HStack {
                                Text(phase == "am" ? "早场" : "晚场")
                                Spacer(minLength: 20)
                                Text("\(session.time)（\(session.enabled ? "运行中" : "已暂停")）")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(WM.f2)
                            }
                        } else {
                            ForEach(session.cron.keys.sorted(), id: \.self) { script in
                                if let job = session.cron[script] {
                                    HStack {
                                        Text((phase == "am" ? "早场 " : "晚场 ") + (script == "maa_plan_card.py" ? "计划卡" : "日常"))
                                        Spacer(minLength: 20)
                                        Text(cronText(job)).font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(job.inSync ? WM.f2 : WM.game)
                                    }
                                }
                            }
                        }
                    }
                }
                if let depotEnabled = schedule.depotEnabled {
                    HStack {
                        Text("仓库对表 04:30")
                        Spacer(minLength: 20)
                        Text(depotEnabled ? "运行中" : "已暂停")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(WM.f2)
                    }
                }
                if !schedule.displayPath.isEmpty {
                    Text(schedule.displayPath).font(.system(size: 11)).foregroundStyle(WM.f3).textSelection(.enabled)
                }
            } else {
                Text(store.scheduleError ?? "读不到场次").foregroundStyle(WM.danger)
            }
        }
        .padding(14)
        .frame(minWidth: 360)
    }

    private func cronText(_ job: ScheduleReport.CronJob) -> String {
        if job.id.isEmpty { return "找不到任务" }
        let state = job.enabled ? "运行中" : "已暂停"
        return job.expr == job.expectedExpr ? "\(job.expr)（\(state)）" : "\(job.expr) → \(job.expectedExpr)（\(state)）"
    }
}
// copy-guard: end
