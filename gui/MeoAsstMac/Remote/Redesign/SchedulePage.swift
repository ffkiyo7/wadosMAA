//
//  SchedulePage.swift
//  Wado's MAA
//
//  日程与默认：早场 / 晚场（时间 + 到点自动开始）、默认关卡、每次要做的事。每项改了就写（走 maa_action）。
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
}

/// 早场或晚场：时间（改了出「保存」）+ 到点自动开始。
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
                }
                DatePicker("开始时间", selection: $draft, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .environment(\.timeZone, RunLock.beijing)
                    .help("开始时间（北京时间）")
                Toggle(
                    "到点自动开始",
                    isOn: Binding(
                        get: { session.enabled },
                        set: { value in Task { await store.perform(["schedule", value ? "enable" : "disable", phase]) } })
                )
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundStyle(WM.f2)
            } else {
                Text("读不到").foregroundStyle(WM.f3)
            }
        }
        .onChange(of: session?.time, initial: true) { _, time in
            if let time, let date = Beijing.today(at: time) { draft = date }
        }
    }
}
