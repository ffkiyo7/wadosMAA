//
//  SchedulePage.swift
//  Wado's MAA
//
//  日程与默认：早场 / 晚场（时间 + 到点自动开始）、默认关卡、每次要做的事。每项改了就写（走 maa_action），写完可撤销。
//  cron 原文和「对齐」在设置页的开发者区（`DeveloperSection`）。
//

import SwiftUI

struct SchedulePage: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    static let taskNames: [(String, String)] = [
        ("fight", "刷理智"), ("infrast", "基建"), ("recruit", "公招"), ("mall", "信用商店"), ("award", "领奖"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "日程与默认", caption: store.config?.meta["session_schedule"]?.text)
                RemoteNotices()
                VStack(alignment: .leading, spacing: 0) {
                    FormGroup(title: "每天") {
                        SessionRow(phase: "am")
                        SessionRow(phase: "pm")
                    }
                    FormGroup {
                        FormRow(title: "默认关卡", help: "当天没单独改过时刷这一关") {
                            stageMenu
                        }
                    }
                    FormGroup(title: "每次要做的事") {
                        ForEach(Self.taskNames, id: \.0) { key, label in
                            FormRow(title: label) {
                                Toggle(label, isOn: taskBinding(key))
                                    .toggleStyle(.switch).labelsHidden()
                                    .help("当天没单独改过时，\(label)")
                            }
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .disabled(store.readOnly)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .task { if data.choices == nil { await data.loadChoices() } }
    }

    private var stageMenu: some View {
        let current = store.pendingValue("defaults.stage")?.string ?? store.defaults?.stage ?? ""
        return Menu {
            ForEach((data.choices?.choices ?? []).filter { !$0.stage.isEmpty }, id: \.self) { choice in
                Button(choice.label) {
                    guard choice.stage != current else { return }
                    Task {
                        await store.change(
                            ["defaults", "set", "stage", choice.stage],
                            undo: ["defaults", "set", "stage", current],
                            pendingKey: "defaults.stage", pendingValue: .string(choice.stage))
                    }
                }
            }
        } label: {
            Text(current.isEmpty ? "—" : current).fontWeight(.medium)
        }
        .fixedSize()
        .help(store.defaults?.meta?.text ?? "默认关卡")
    }

    private func taskBinding(_ key: String) -> Binding<Bool> {
        let id = "defaults.task.\(key)"
        return Binding(
            get: { store.pendingValue(id)?.bool ?? store.defaults?.tasks?[key] ?? true },
            set: { value in
                Task {
                    await store.change(
                        ["defaults", "set", "task", key, value ? "on" : "off"],
                        undo: ["defaults", "set", "task", key, value ? "off" : "on"],
                        pendingKey: id, pendingValue: .bool(value))
                }
            })
    }
}

/// 早场或晚场：时间（停手 1 秒后写）+ 到点自动开始。
struct SessionRow: View {
    @Environment(RemoteStore.self) private var store
    let phase: String
    @State private var draft = Date()
    @State private var commitTask: Task<Void, Never>?

    private var session: ScheduleReport.Session? { store.schedule?.sessions[phase] }
    private var title: String { phase == "am" ? "早场" : "晚场" }
    private var window: String { phase == "am" ? "05:00–11:59" : "12:00–23:59" }

    var body: some View {
        FormRow(title: title, help: "可选 \(window)（北京时间）") {
            if let session {
                DatePicker("开始时间", selection: $draft, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.timeZone, RunLock.beijing)
                    .help("开始时间（北京时间）")
                    .onChange(of: draft) { scheduleTimeCommit(old: session.time) }
                Toggle(
                    "到点自动开始",
                    isOn: Binding(
                        get: { store.pendingValue(enabledKey)?.bool ?? session.enabled },
                        set: { value in
                            Task {
                                await store.change(
                                    ["schedule", value ? "enable" : "disable", phase],
                                    undo: ["schedule", value ? "disable" : "enable", phase],
                                    pendingKey: enabledKey, pendingValue: .bool(value))
                            }
                        })
                )
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundStyle(WM.f2)
            } else {
                Text("读不到").foregroundStyle(WM.f3)
            }
        }
        .onChange(of: session?.time, initial: true) { _, time in
            if let time { reset(to: time) }
        }
    }

    private var enabledKey: String { "schedule.\(phase).enabled" }

    private func reset(to time: String) {
        if let date = Beijing.today(at: time), RunLock.beijingClock(date) != RunLock.beijingClock(draft) { draft = date }
    }

    /// 时间是一位一位敲的：停手 1 秒再写，不然敲到一半（例如 0 点几分）就写进去了。写失败（超出可选范围）就退回原来的时间。
    private func scheduleTimeCommit(old: String) {
        commitTask?.cancel()
        let time = RunLock.beijingClock(draft)
        guard time != old else { return }
        commitTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await store.change(["schedule", "set", phase, time], undo: ["schedule", "set", phase, old])
            if let current = store.schedule?.sessions[phase]?.time { reset(to: current) }
        }
    }
}
