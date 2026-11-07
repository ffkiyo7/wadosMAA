//
//  SchedulePage.swift
//  Wado's MAA
//
//  日程与默认：定时场（时间 + 开关）、默认关卡、每场环节；cron 收在底部。每项改了就写（走 maa_action）。
//

import SwiftUI

struct SchedulePage: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data
    @State private var showCron = false

    static let taskNames: [(String, String)] = [
        ("fight", "刷理智"), ("infrast", "基建"), ("recruit", "公招"), ("mall", "信用商店"), ("award", "领奖"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "日程与默认", caption: store.config?.meta["session_schedule"]?.text)
                RemoteNotices()
                VStack(alignment: .leading, spacing: 0) {
                    FormGroup(title: "定时场") {
                        SessionRow(phase: "am")
                        SessionRow(phase: "pm")
                    }
                    FormGroup {
                        FormRow(title: "默认关卡", help: "计划卡没改过的那一场刷这一关；和 Discord 计划卡同一份关卡列表") {
                            stageMenu
                        }
                    }
                    FormGroup(title: "每一场的环节") {
                        ForEach(Self.taskNames, id: \.0) { key, label in
                            FormRow(title: label) {
                                Toggle(label, isOn: taskBinding(key))
                                    .toggleStyle(.switch).labelsHidden()
                                    .help("计划卡没改过时，这一场\(label)")
                            }
                        }
                    }
                    FormGroup {
                        FormRow(title: "cron 表达式", help: "Hermes 里四条任务的时间") {
                            Button("查看…") { showCron = true }.buttonStyle(WMButtonStyle())
                                .help("看 cron 表达式和是否对齐")
                                .popover(isPresented: $showCron, arrowEdge: .bottom) { cronPopover }
                        }
                        FormRow(title: "对齐 cron 时间", help: "只把 cron 时间对齐到配置，不动暂停状态") {
                            Button("对齐") { Task { await store.perform(["schedule", "sync"]) } }
                                .buttonStyle(WMButtonStyle())
                                .help("改时间只改 cron 的时间，不会恢复被暂停的任务")
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .disabled(store.busy || store.readOnly)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .task { if data.choices == nil { await data.loadChoices() } }
    }

    private var stageMenu: some View {
        let current = store.defaults?.stage ?? ""
        return Menu {
            ForEach((data.choices?.choices ?? []).filter { !$0.stage.isEmpty }, id: \.self) { choice in
                Button(choice.label) {
                    Task { await store.perform(["defaults", "set", "stage", choice.stage]) }
                }
            }
        } label: {
            Text(current.isEmpty ? "—" : current).fontWeight(.medium)
        }
        .fixedSize()
        .help(store.defaults?.meta?.text ?? "默认关卡")
    }

    private func taskBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { store.defaults?.tasks?[key] ?? true },
            set: { value in Task { await store.perform(["defaults", "set", "task", key, value ? "on" : "off"]) } })
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

/// 一场：时间（改了出「保存」）+ 开关。
struct SessionRow: View {
    @Environment(RemoteStore.self) private var store
    let phase: String
    @State private var draft = Date()

    private var session: ScheduleReport.Session? { store.schedule?.sessions[phase] }
    private var title: String { phase == "am" ? "早场" : "晚场" }
    private var window: String { phase == "am" ? "05:00–11:59" : "12:00–23:59" }

    var body: some View {
        FormRow(title: title, help: "可选 \(window)（北京时间）") {
            if let session {
                if RunLock.beijingClock(draft) != session.time {
                    Button("保存") { Task { await store.perform(["schedule", "set", phase, RunLock.beijingClock(draft)]) } }
                        .buttonStyle(WMButtonStyle(kind: .accent))
                        .help("写入场次并同步 cron 时间")
                }
                DatePicker("开跑时间", selection: $draft, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.timeZone, RunLock.beijing)
                    .help("开跑时间（北京时间）")
                Toggle(
                    title,
                    isOn: Binding(
                        get: { session.enabled },
                        set: { value in Task { await store.perform(["schedule", value ? "enable" : "disable", phase]) } })
                )
                .toggleStyle(.switch).labelsHidden()
                .help("开关这一场（pause / resume cron）")
            } else {
                Text("读不到").foregroundStyle(WM.f3)
            }
        }
        .onChange(of: session?.time, initial: true) { _, time in
            if let time, let date = Beijing.today(at: time) { draft = date }
        }
    }
}
