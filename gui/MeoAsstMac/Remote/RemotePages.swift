//
//  RemotePages.swift
//  Wado's MAA
//
//  边栏「日常配置」（S5，K3 / K5 / K6）：状态、场次、默认值，外加 maa-remote 每一组可改的配置。
//  页面只渲染 `config get` 给的字段表（`maa_settings.FIELDS`），不在 GUI 里另写一份。
//

import SwiftUI

enum RemoteEntry: Hashable, Codable, Identifiable {
    case status
    case schedule
    case defaults
    case group(String)

    var id: String {
        switch self {
        case .status: "status"
        case .schedule: "schedule"
        case .defaults: "defaults"
        case let .group(name): "group:\(name)"
        }
    }

    var title: String {
        switch self {
        case .status: "状态"
        case .schedule: "场次"
        case .defaults: "持久默认值"
        case let .group(name): name
        }
    }

    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.33percent"
        case .schedule: "clock"
        case .defaults: "pin"
        case let .group(name):
            switch name {
            case "日常": "checklist"
            case "自动定关": "map"
            case "抄作业": "doc.on.doc"
            case "森空岛": "person.crop.circle"
            case "运行环境": "gearshape.2"
            default: "slider.horizontal.3"
            }
        }
    }
}

// MARK: - 中间栏

struct RemoteContent: View {
    @Environment(RemoteStore.self) private var store
    @Binding var selection: RemoteEntry?

    private var entries: [RemoteEntry] {
        // 「场次」组只有一项 session_schedule，用专门的场次页改（会同步 cron）。
        let groups = (store.config?.groups ?? []).filter { $0 != "场次" }.map(RemoteEntry.group)
        return [.status, .schedule, .defaults] + groups
    }

    var body: some View {
        List(entries, selection: $selection) { entry in
            Label(entry.title, systemImage: entry.icon).tag(entry)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.reload() }
                } label: {
                    Label("重读", systemImage: "arrow.clockwise")
                }
                .help("重读 maa-remote 的状态")
            }
        }
        .task { await store.reload() }
    }
}

// MARK: - 右栏

struct RemoteDetail: View {
    @Environment(RemoteStore.self) private var store
    let entry: RemoteEntry?

    var body: some View {
        VStack(spacing: 0) {
            RemoteBanner()
            Group {
                switch entry {
                case .status: RemoteStatusPage()
                case .schedule: RemoteSchedulePage()
                case .defaults: RemoteDefaultsPage()
                case let .group(name): RemoteGroupPage(group: name)
                case .none: Text("请选择左侧的项目").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .disabled(store.busy)
        }
    }
}

/// 顶部提示：只读、读失败、刚才那次操作的回执。
struct RemoteBanner: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = store.schemaProblem {
                Label(problem, systemImage: "lock.fill").foregroundStyle(.orange)
            }
            if let error = store.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let notice = store.notice {
                HStack(alignment: .top) {
                    Label(notice.text, systemImage: notice.ok ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(notice.ok ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        store.clearNotice()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.top, store.schemaProblem == nil && store.loadError == nil && store.notice == nil ? 0 : 8)
    }
}

// MARK: - 状态

struct RemoteStatusPage: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        Form {
            Section("maa-remote") {
                LabeledContent("HERMES_HOME") {
                    Text(RemoteConfig.hermesHome.path).textSelection(.enabled)
                }
                LabeledContent("环境") {
                    Text(RemoteConfig.isLiveHome ? "线上" : "开发副本（不改线上，不发 Discord）")
                }
                LabeledContent("run.lock") {
                    Text(store.lockHolder.map { "被占：\($0.text)" } ?? "空闲")
                }
                if let reloaded = store.reloadedAt {
                    LabeledContent("上次重读", value: reloaded.formatted(date: .omitted, time: .standard))
                }
            }
            Section("上一场") {
                LabeledContent("状态", value: store.lastRun["status"]?.displayText ?? "—")
                LabeledContent("场次", value: store.lastRun["phase"]?.displayText ?? "—")
                LabeledContent("开始", value: store.lastRun["started_at"]?.displayText ?? "—")
                LabeledContent("结束", value: store.lastRun["finished_at"]?.displayText ?? "—")
                if let summary = store.lastRun["summary"]?.displayText, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            UpstreamSection()
        }
        .formStyle(.grouped)
    }
}

struct UpstreamSection: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        Section("上游（maa-cli / MaaCore / MaaResource）") {
            if let status = store.upstream {
                LabeledContent("判定", value: verdictText(status))
                if let reason = status.blockReason, !reason.isEmpty {
                    Text(reason).foregroundStyle(.red)
                }
                LabeledContent("maa-cli", value: status.versions.maaCli ?? "未知")
                LabeledContent("MaaCore（盘上）", value: status.versions.maaCore ?? "未知")
                LabeledContent("MaaCore（本进程）", value: CorePreflight.loadedVersion ?? "没加载")
                LabeledContent("MaaResource", value: status.versions.maaResourceHead.map { String($0.prefix(10)) } ?? "未知")
                LabeledContent("基础资源", value: status.versions.resourceLastUpdated ?? "未知")
                LabeledContent("上次成功更新", value: status.lastSuccessAt.flatMap { $0.isEmpty ? nil : $0 } ?? "没有记录")
                if let mismatch = RemoteGate.coreMismatch(status) {
                    Text(mismatch).foregroundStyle(.orange)
                }
                if let online = status.online {
                    LabeledContent("maa-cli 可用", value: online.maaCliLatest ?? "—")
                    LabeledContent("MaaResource 远端", value: online.maaResourceRemoteHead.map { String($0.prefix(10)) } ?? "—")
                    ForEach(online.errors ?? [], id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                if let blocked = status.updateBlocked, !blocked.isEmpty {
                    Text("现在不能更新：\(blocked)").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(RemoteGate.lastStatusError ?? "还没查过")
            }
            HStack {
                Button("离线重查") { Task { await store.refreshUpstream(online: false) } }
                Button("联网查新版") { Task { await store.refreshUpstream(online: true) } }
                Button("更新上游") {
                    Task {
                        await store.perform(["upstream", "update"])
                        _ = await RemoteGate.waitForUpdate()
                        await store.reload()
                    }
                }
                .disabled(!(store.upstream?.updateBlocked ?? "x").isEmpty)
            }
        }
    }

    private func verdictText(_ status: UpstreamStatus) -> String {
        switch status.verdict {
        case "ok": "✅ 一致，本游戏日已更新"
        case "stale": "🕓 本游戏日还没成功更新过（不挡跑）"
        case "blocked": "⛔ 被挡住"
        case "running": "⏳ 更新中"
        default: status.verdict
        }
    }
}

// MARK: - 场次

struct RemoteSchedulePage: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        Form {
            if let meta = store.config?.meta["session_schedule"] {
                Text(meta.text).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(["am", "pm"], id: \.self) { phase in
                SessionEditor(phase: phase)
            }
            Section {
                if let schedule = store.schedule {
                    LabeledContent("Hermes 时区", value: schedule.timezone)
                    LabeledContent("任务表", value: schedule.jobsPath)
                } else if let error = store.scheduleError {
                    Text(error).foregroundStyle(.red)
                }
                Button("只把 cron 的时间对齐到配置") {
                    Task { await store.perform(["schedule", "sync"]) }
                }
                .help("不动暂停状态")
            } footer: {
                Text("改时间只改 cron 的时间，不会恢复被暂停的任务；只有拨「开」「关」才会 pause / resume。")
            }
        }
        .formStyle(.grouped)
    }
}

struct SessionEditor: View {
    @Environment(RemoteStore.self) private var store
    let phase: String
    @State private var draft = Date()
    @State private var loaded = false

    private var session: ScheduleReport.Session? { store.schedule?.sessions[phase] }
    private var title: String { phase == "am" ? "早场" : "晚场" }
    private var window: String { phase == "am" ? "05:00–11:59" : "12:00–23:59" }

    var body: some View {
        Section("\(title)（可选 \(window)）") {
            if let session {
                Toggle(
                    "开着这一场",
                    isOn: Binding(
                        get: { session.enabled },
                        set: { value in
                            Task { await store.perform(["schedule", value ? "enable" : "disable", phase]) }
                        }))
                HStack {
                    DatePicker("开跑时间（北京时间）", selection: $draft, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, RunLock.beijing)
                    Button("保存") {
                        Task { await store.perform(["schedule", "set", phase, hhmm(draft)]) }
                    }
                    .disabled(hhmm(draft) == session.time)
                }
                ForEach(session.cron.keys.sorted(), id: \.self) { script in
                    if let job = session.cron[script] {
                        LabeledContent(script == "maa_plan_card.py" ? "计划卡 cron" : "日常 cron") {
                            Text(cronText(job))
                                .foregroundStyle(job.inSync ? Color.secondary : Color.orange)
                        }
                    }
                }
            } else {
                Text("读不到场次").foregroundStyle(.secondary)
            }
        }
        .onChange(of: session?.time, initial: true) { _, time in
            if let time, let date = Self.date(from: time) { draft = date }
        }
    }

    private func cronText(_ job: ScheduleReport.CronJob) -> String {
        if job.id.isEmpty { return "找不到任务" }
        let state = job.enabled ? "运行中" : "已暂停"
        return job.expr == job.expectedExpr ? "\(job.expr)（\(state)）" : "\(job.expr) → 应为 \(job.expectedExpr)（\(state)）"
    }

    private func hhmm(_ date: Date) -> String {
        RunLock.beijingClock(date)
    }

    static func date(from hhmm: String) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RunLock.beijing
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }
}

// MARK: - 持久默认值

struct RemoteDefaultsPage: View {
    @Environment(RemoteStore.self) private var store
    @State private var stage = ""

    static let taskNames: [(String, String)] = [
        ("fight", "刷理智"), ("infrast", "基建"), ("recruit", "公招"), ("mall", "信用商店"), ("award", "领奖励"),
    ]

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("默认刷哪关", text: $stage, prompt: Text("例如 1-7、CE-6"))
                    Button("保存") { Task { await store.perform(["defaults", "set", "stage", stage]) } }
                        .disabled(stage.isEmpty || stage == store.defaults?.stage)
                }
                ForEach(Self.taskNames, id: \.0) { key, label in
                    Toggle(
                        label,
                        isOn: Binding(
                            get: { store.defaults?.tasks?[key] ?? true },
                            set: { value in
                                Task { await store.perform(["defaults", "set", "task", key, value ? "on" : "off"]) }
                            }))
                }
            } header: {
                Text("计划卡没改过的那一场用这些")
            } footer: {
                VStack(alignment: .leading) {
                    Text("不碎石、只吃临期药、不借助战：这几项固定，不能改（K11）。")
                    if let meta = store.defaults?.meta { Text(meta.text) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.defaults?.stage, initial: true) { _, value in stage = value ?? "" }
    }
}

// MARK: - 配置组

struct RemoteGroupPage: View {
    @Environment(RemoteStore.self) private var store
    let group: String

    var body: some View {
        Form {
            if let config = store.config {
                ForEach(config.fields.filter { $0.group == group }) { field in
                    ConfigFieldRow(field: field, value: config.values[field.key] ?? field.default ?? .null,
                                   meta: config.meta[field.key])
                }
            } else {
                Text("还没读到配置").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ConfigFieldRow: View {
    @Environment(RemoteStore.self) private var store
    let field: ConfigField
    let value: JSONValue
    let meta: ChangeMeta?

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            editor
            Group {
                if let help = field.help { Text(help) }
                Text(meta?.text ?? "默认值：\(field.default?.displayText ?? "—")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: value, initial: true) { _, new in draft = Self.draftText(field.kind, new) }
    }

    @ViewBuilder private var editor: some View {
        switch field.kind {
        case "bool":
            Toggle(
                field.label,
                isOn: Binding(
                    get: { value.bool ?? false },
                    set: { new in Task { await store.setConfig(field.key, .bool(new)) } }))
        case "int", "float", "text":
            HStack {
                TextField(field.label, text: $draft)
                    .onSubmit(apply)
                if let range = rangeText { Text(range).font(.caption).foregroundStyle(.secondary) }
                applyButton
            }
        default:
            VStack(alignment: .leading) {
                HStack {
                    Text(field.label)
                    Spacer()
                    applyButton
                }
                TextEditor(text: $draft)
                    .font(.body.monospaced())
                    .frame(minHeight: 60, maxHeight: 160)
                Text(field.kind == "str_list" ? "一行一项" : "JSON，按 maa-remote 的格式填")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var applyButton: some View {
        Button("应用", action: apply)
            .disabled(draft == Self.draftText(field.kind, value))
    }

    private var rangeText: String? {
        guard let min = field.min, let max = field.max else { return nil }
        let format: (Double) -> String = { $0.rounded() == $0 ? String(Int($0)) : String($0) }
        return "\(format(min))–\(format(max))"
    }

    private func apply() {
        let parsed: JSONValue?
        switch field.kind {
        case "int", "float":
            parsed = Double(draft.trimmingCharacters(in: .whitespaces)).map(JSONValue.number)
        case "text":
            parsed = .string(draft)
        case "str_list":
            parsed = .array(
                draft.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(JSONValue.string))
        default:
            parsed = JSONValue.parse(draft)
        }
        guard let parsed else {
            store.post(false, "「\(field.label)」填的不是合法的值")
            return
        }
        Task { await store.setConfig(field.key, parsed) }
    }

    static func draftText(_ kind: String, _ value: JSONValue) -> String {
        switch kind {
        case "int", "float", "text": value.displayText == "—" ? "" : value.displayText
        case "str_list": (value.array ?? []).map(\.displayText).joined(separator: "\n")
        default: value.prettyText
        }
    }
}
