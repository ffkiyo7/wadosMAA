//
//  SettingsPage.swift
//  Wado's MAA
//
//  设置：外观（强调色、背景图、玻璃卡片）、连接与游戏、帮助与日志文件；
//  底部默认收起的「开发者」：环境、HERMES_HOME、Python、cron（给维护的人用，普通界面不出现这些词）。
//  原来的连接 / 游戏 / 系统设置页原样放进弹出页里用；⌘, 的设置窗口也还在。
//

import SwiftUI

struct SettingsPage: View {
    @AppStorage(WM.accentKey) private var accent = AccentChoice.gold
    @AppStorage(AppearanceKeys.glass) private var glass = true
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""

    @State private var sheet: SettingsSheet?

    enum SettingsSheet: String, Identifiable {
        case background, connection, game, system
        var id: String { rawValue }
    }

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
                            Button("选择…") { sheet = .background }.buttonStyle(WMButtonStyle())
                                .help("选背景图，调填充、遮罩和模糊")
                        }
                        FormRow(title: "玻璃卡片", help: "有背景图时，卡片用 Liquid Glass") {
                            Toggle("玻璃卡片", isOn: $glass).toggleStyle(.switch).labelsHidden()
                                .help("有背景图时，卡片用 Liquid Glass")
                        }
                    }
                    FormGroup(title: "连接与游戏") {
                        FormRow(title: "连接设置", help: "连接地址、触控方式") {
                            Button("打开…") { sheet = .connection }.buttonStyle(WMButtonStyle()).help("连接地址、触控方式")
                        }
                        FormRow(title: "游戏设置", help: "客户端、启动游戏") {
                            Button("打开…") { sheet = .game }.buttonStyle(WMButtonStyle()).help("客户端、启动游戏")
                        }
                        FormRow(title: "系统选项", help: "防休眠、通知等") {
                            Button("打开…") { sheet = .system }.buttonStyle(WMButtonStyle()).help("防休眠、通知等")
                        }
                    }
                    FormGroup {
                        FormRow(title: "帮助与公告") {
                            Link(destination: URL(string: "https://docs.maa.plus/zh-cn/mac.html")!) {
                                Text("打开…")
                            }
                            .buttonStyle(WMButtonStyle())
                            .help("docs.maa.plus 的 Mac 版说明")
                        }
                        FormRow(title: "日志文件") {
                            Button("在 Finder 中显示") { OpenLogFileView.revealLogInFinder() }
                                .buttonStyle(WMButtonStyle()).help("运行日志所在的文件夹")
                        }
                    }
                    // copy-guard: developer
                    DeveloperSection()
                    // copy-guard: end
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .sheet(item: $sheet) { which in
            VStack(spacing: 0) {
                switch which {
                case .background: AppearanceSettingsView()
                case .connection: ConnectionSettingsView()
                case .game: GameSettingsView()
                case .system: SystemSettingsView()
                }
                HStack {
                    Spacer()
                    Button("完成") { sheet = nil }.buttonStyle(WMButtonStyle(kind: .accent))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
            .frame(minWidth: 480, minHeight: 360)
        }
    }

    private var backgroundText: String {
        let names = [lightPath, darkPath].filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent }
        return names.isEmpty ? "未设置" : names.joined(separator: "、")
    }
}

// copy-guard: developer
/// 开发者区：默认收起，每次进设置页都重新收起。这里的字是给维护的人看的，可以用技术词。
struct DeveloperSection: View {
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
                    Text("开发者")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(WM.f3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)
            .padding(.top, 28)
            if expanded {
                FormGroup {
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
                .padding(.top, -12)
            }
        }
        .alert("切到线上？", isPresented: $askLive) {
            Button("切到线上", role: .destructive) { hermesHome = RemoteConfig.liveHermesHome }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后的改动会写进 \(RemoteConfig.liveHermesHome)，并同步到 Discord。")
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
                Text("时区 \(schedule.timezone)").foregroundStyle(WM.f2)
                ForEach(["am", "pm"], id: \.self) { phase in
                    if let session = schedule.sessions[phase] {
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
                Text(schedule.jobsPath).font(.system(size: 11)).foregroundStyle(WM.f3).textSelection(.enabled)
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
