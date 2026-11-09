//
//  DailyPage.swift
//  Wado's MAA
//
//  日常：按一场日常从头到尾排——时间表（早场 / 晚场、到点自动开始、早晚场前不接手动日常）→ 要做的事 →
//  刷什么（默认关卡）→ 刷理智、剿灭、公招、信用商店、领奖的细项。每项改了就写，写完可撤销。
//  不常动的（超时、重试、自动定关的参数、日志保留）在设置 › 高级；抄作业的规则在抄作业页右上角。
//

import SwiftUI

struct DailyPage: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    static let taskNames: [(String, String)] = [
        ("fight", "刷理智"), ("infrast", "基建"), ("recruit", "公招"), ("mall", "信用商店"), ("award", "领奖"),
    ]

    /// 这一页放了哪些配置项；没放在任何一页的都进设置 › 高级。
    static let keys: Set<String> = [
        "manual_run_blackout_minutes", "medicine_expire_days", "report_drops", "annihilation_sanity",
        "recruit_times", "mall_buy_first", "mall_blacklist", "mall_reserve_max_credit", "mall_only_buy_discount",
        "award_orundum", "award_mining", "award_specialaccess",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "日常", caption: latestMeta)
                RemoteNotices()
                VStack(alignment: .leading, spacing: 0) {
                    FormGroup(title: "时间表") {
                        SessionRow(phase: "am")
                        SessionRow(phase: "pm")
                        ConfigFieldRow(key: "manual_run_blackout_minutes", title: "早晚场前不接手动日常") { value in
                            let minutes = Int(value.number ?? 0)
                            guard minutes > 0 else { return "随时都能开始手动日常" }
                            return SessionLead.windows(store, minutes: minutes).map { "\($0) 不能开始手动日常" }
                        }
                    }
                    FormGroup(title: "要做的事") {
                        ForEach(Self.taskNames, id: \.0) { key, label in
                            FormRow(title: label) {
                                Toggle(label, isOn: taskBinding(key))
                                    .toggleStyle(.switch).labelsHidden()
                            }
                        }
                    }
                    FormGroup(title: "刷什么") {
                        FormRow(title: "默认关卡", sub: autoStageText) {
                            stageMenu
                        }
                    }
                    FormGroup(title: "刷理智") {
                        ConfigFieldRow(key: "medicine_expire_days") { value in
                            let days = Int(value.number ?? 0)
                            return days > 0 ? "只吃 \(days) 天内过期的理智药" : "一瓶理智药都不吃"
                        }
                        ConfigFieldRow(key: "report_drops")
                    }
                    FormGroup(title: "剿灭") {
                        ConfigFieldRow(key: "annihilation_sanity")
                    }
                    FormGroup(title: "公招") {
                        ConfigFieldRow(key: "recruit_times")
                    }
                    FormGroup(title: "信用商店") {
                        ConfigFieldRow(key: "mall_buy_first")
                        ConfigFieldRow(key: "mall_blacklist")
                        ConfigFieldRow(key: "mall_reserve_max_credit")
                        ConfigFieldRow(key: "mall_only_buy_discount")
                    }
                    FormGroup(title: "领奖") {
                        ConfigFieldRow(key: "award_orundum")
                        ConfigFieldRow(key: "award_mining")
                        ConfigFieldRow(key: "award_specialaccess")
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

    /// 这一页上的设置最后一次是谁、几点改的。
    private var latestMeta: String? {
        var metas = (store.config?.meta ?? [:]).filter { Self.keys.contains($0.key) || $0.key == "session_schedule" }
            .map(\.value)
        if let defaults = store.defaults?.meta { metas.append(defaults) }
        return metas.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }?.text
    }

    /// 「今天自动定关：早场 TL-9、晚场 TL-9」：材料缺口自动定的关会盖过默认关卡。
    private var autoStageText: String? {
        let auto = (store.todayPlan?.sessions ?? []).filter { $0.stageSource == "auto" && !$0.stage.isEmpty }
        guard !auto.isEmpty else { return nil }
        return "今天自动定关：" + auto.map { "\($0.phase == "am" ? "早场" : "晚场") \($0.stage)" }.joined(separator: "、")
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
        .help(store.defaults?.meta?.text ?? "当天没单独改过、也没自动定关时刷这一关")
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

/// 由早晚场时间往前推出来的时段（「07:30–08:00、21:30–22:00」），只算开着的场。
@MainActor enum SessionLead {
    static func windows(_ store: RemoteStore, minutes: Int) -> String? {
        guard let sessions = store.schedule?.sessions else { return nil }
        let parts = ["am", "pm"].compactMap { key -> String? in
            guard let session = sessions[key], session.enabled, let date = Beijing.today(at: session.time)
            else { return nil }
            return "\(RunLock.beijingClock(date.addingTimeInterval(-Double(minutes) * 60)))–\(session.time)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "、")
    }
}
