//
//  ConfigPage.swift
//  Wado's MAA
//
//  日常配置：日常 / 高级分段，整页一起保存。底层仍然逐项 `config set`（字段表来自 `config get`，不在 GUI 另写）。
//

import SwiftUI

struct ConfigPage: View {
    @Environment(RemoteStore.self) private var store
    @AppStorage("WMConfigTab") private var tab = "daily"

    @State private var draft: [String: JSONValue] = [:]
    @State private var editing: ConfigField?
    @State private var saving = false

    private var groups: [String] {
        let all = (store.config?.groups ?? []).filter { $0 != "场次" }
        return tab == "daily" ? all.filter { $0 == "日常" } : all.filter { $0 != "日常" }
    }

    private func current(_ field: ConfigField) -> JSONValue {
        store.config?.values[field.key] ?? field.default ?? .null
    }

    private func value(_ field: ConfigField) -> JSONValue { draft[field.key] ?? current(field) }

    private var changedKeys: [String] {
        (store.config?.fields ?? []).filter { draft[$0.key] != nil && draft[$0.key] != current($0) }.map(\.key)
    }

    var body: some View {
        let dirty = !changedKeys.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "日常配置", caption: latestMeta) {
                    Picker("分组", selection: $tab) {
                        Text("日常").tag("daily")
                        Text("高级").tag("adv")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("日常：每天会碰到的；高级：自动定关、抄作业、森空岛、运行环境")
                }
                RemoteNotices()
                VStack(alignment: .leading, spacing: 0) {
                    if store.config == nil {
                        Text("还没读到配置").foregroundStyle(WM.f2)
                    }
                    ForEach(groups, id: \.self) { group in
                        FormGroup(title: group) {
                            ForEach((store.config?.fields ?? []).filter { $0.group == group }) { field in
                                fieldRow(field)
                            }
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .disabled(saving || store.readOnly)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { saveBar(dirty) }
        .sheet(item: $editing) { field in
            JSONFieldEditor(field: field, value: value(field)) { draft[field.key] = $0 }
        }
    }

    private var latestMeta: String? {
        store.config?.meta.values.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }?.text
    }

    private func saveBar(_ dirty: Bool) -> some View {
        HStack(spacing: 8) {
            if dirty {
                Text("\(changedKeys.count) 项未保存").fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
            if saving { ProgressView().controlSize(.small) }
            Spacer()
            Button("还原") { draft = [:] }
                .buttonStyle(WMButtonStyle()).disabled(!dirty || saving)
                .help("放弃这页上没保存的修改")
            Button("保存") { Task { await save() } }
                .buttonStyle(WMButtonStyle(kind: .accent)).disabled(!dirty || saving || store.readOnly)
                .keyboardShortcut("s", modifiers: .command)
                .help("写入 maa-remote，同步到 Discord ⌘S")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(WM.line).frame(height: 1) }
    }

    private func help(_ field: ConfigField) -> String {
        var parts: [String] = []
        if let help = field.help, !help.isEmpty { parts.append(help) }
        if let min = field.min, let max = field.max { parts.append("范围 \(fmt(min))–\(fmt(max))") }
        parts.append(store.config?.meta[field.key]?.text ?? "默认值：\(field.default?.displayText ?? "—")")
        return parts.joined(separator: "\n")
    }

    private func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(v) }

    @ViewBuilder private func fieldRow(_ field: ConfigField) -> some View {
        let changed = draft[field.key] != nil && draft[field.key] != current(field)
        let title = field.label + (changed ? " ·" : "")
        switch field.kind {
        case "bool":
            FormRow(title: title, help: help(field)) {
                Toggle(field.label, isOn: Binding(
                    get: { value(field).bool ?? false }, set: { draft[field.key] = .bool($0) }))
                    .toggleStyle(.switch).labelsHidden().help(help(field))
            }
        case "int", "float":
            let unit = Self.unit(field.label)
            FormRow(title: Self.stripUnit(field.label) + (changed ? " ·" : ""), help: help(field)) {
                WMStepper(
                    value: Binding(get: { value(field).number ?? 0 }, set: { draft[field.key] = .number($0) }),
                    step: field.kind == "float" ? 0.1 : 1,
                    range: (field.min ?? 0)...(field.max ?? 1_000_000),
                    unit: unit, label: field.label)
            }
        case "text":
            FormRow(title: title, help: help(field)) {
                TextField(field.label, text: Binding(
                    get: { value(field).string ?? "" }, set: { draft[field.key] = .string($0) }))
                    .labelsHidden().frame(width: 200).help(help(field))
            }
        default:
            FormRow(title: title, sub: summary(value(field)), help: help(field)) {
                Button("编辑…") { editing = field }.buttonStyle(WMButtonStyle()).help("编辑「\(field.label)」")
            }
        }
    }

    private func summary(_ value: JSONValue) -> String {
        switch value {
        case let .array(items): items.isEmpty ? "无" : items.map(\.displayText).joined(separator: "、")
        case let .object(object): object.isEmpty ? "无" : "\(object.count) 项"
        default: value.displayText
        }
    }

    /// 「公招次数」→ 无单位；「…（分钟）」→ 分钟。
    static func unit(_ label: String) -> String {
        guard let open = label.lastIndex(of: "（"), label.hasSuffix("）") else { return "" }
        return String(label[label.index(after: open)..<label.index(before: label.endIndex)])
    }

    static func stripUnit(_ label: String) -> String {
        guard let open = label.lastIndex(of: "（"), label.hasSuffix("）") else { return label }
        return String(label[..<open])
    }

    private func save() async {
        guard !store.readOnly else { return }
        saving = true
        defer { saving = false }
        var failures: [String] = []
        let keys = changedKeys
        for key in keys {
            guard let value = draft[key] else { continue }
            do {
                let receipt = try await RemoteBridge.run(["config", "set", key, value.jsonText])
                if receipt.ok { draft[key] = nil } else { failures.append(receipt.message) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await store.reload()
        store.notice = failures.isEmpty
            ? (true, "已保存 \(keys.count) 项。")
            : (false, "有 \(failures.count) 项没保存：\(failures.joined(separator: "；"))")
    }
}

/// 列表 / 表格类字段的编辑框：字符串列表一行一项，其余是 JSON。
struct JSONFieldEditor: View {
    let field: ConfigField
    let value: JSONValue
    let apply: (JSONValue) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(field.label).font(.system(size: 16, weight: .bold))
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 420, minHeight: 240)
                .help(field.kind == "str_list" ? "一行一项" : "JSON，按 maa-remote 的格式填")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(WM.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WMButtonStyle()).keyboardShortcut(.cancelAction)
                Button("好") { done() }.buttonStyle(WMButtonStyle(kind: .accent))
                    .help("先记在这页上，点底部「保存」才写入")
            }
        }
        .padding(20)
        .onAppear {
            text = field.kind == "str_list"
                ? (value.array ?? []).map(\.displayText).joined(separator: "\n") : value.prettyText
        }
    }

    private func done() {
        let parsed: JSONValue?
        if field.kind == "str_list" {
            parsed = .array(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map(JSONValue.string))
        } else {
            parsed = JSONValue.parse(text)
        }
        guard let parsed else {
            error = "不是合法的 JSON"
            return
        }
        apply(parsed)
        dismiss()
    }
}
