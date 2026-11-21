//
//  ConfigFields.swift
//  Wado's MAA
//
//  一项设置一行（字段表来自 `config get`，GUI 不另写）：改了就写（`config set`），写完底部出「已保存 · 撤销」。
//  开关一拨就写；数字停手 0.8 秒再写；文字回车或离开输入框时写；列表 / 表格在编辑框点「好」时写。
//

import SwiftUI
import WadosMAAShared

/// 按键名找字段画一行；`config get` 里没有这个键（旧版后端）就什么都不画。
/// `sub`：由当前值算出来的一行灰字，直接说这个值的效果。
struct ConfigFieldRow: View {
    @Environment(RemoteStore.self) private var store
    let key: String
    var title: String?
    var sub: ((JSONValue) -> String?)?

    var body: some View {
        if let field = store.configField(key) {
            ConfigFieldControl(field: field, title: title, sub: sub)
        }
    }
}

struct ConfigFieldControl: View {
    @Environment(RemoteStore.self) private var store
    let field: ConfigField
    var title: String?
    var sub: ((JSONValue) -> String?)?

    /// 正在调、还没写的数字 / 文字。
    @State private var number: Double?
    @State private var text: String?
    @State private var numberCommit: Task<Void, Never>?
    @State private var editing = false
    @FocusState private var focused: Bool

    private var stored: JSONValue { store.configValue(field) }

    private var shown: JSONValue {
        if let number { return .number(number) }
        if let text { return .string(text) }
        return stored
    }

    private var label: String { title ?? Self.stripUnit(field.label) }

    var body: some View {
        let sub = sub?(shown)
        switch field.kind {
        case "bool":
            FormRow(title: label, sub: sub, help: help) {
                Toggle(label, isOn: Binding(get: { shown.bool ?? false }, set: { commit(.bool($0)) }))
                    .toggleStyle(.switch).labelsHidden()
            }
        case "int", "float":
            FormRow(title: label, sub: sub, help: help) {
                WMStepper(
                    value: Binding(get: { shown.number ?? 0 }, set: { nudge($0) }),
                    step: field.kind == "float" ? 0.1 : 1,
                    range: (field.min ?? 0)...(field.max ?? 1_000_000),
                    unit: Self.unit(field.label), label: label)
            }
        case "text":
            FormRow(title: label, sub: sub, help: help) {
                TextField(label, text: Binding(get: { shown.string ?? "" }, set: { text = $0 }))
                    .labelsHidden().frame(width: 200)
                    .focused($focused)
                    .onSubmit { commitText() }
                    .onChange(of: focused) { if !focused { commitText() } }
            }
        default:
            FormRow(title: label, sub: sub ?? Self.summary(shown), help: help) {
                Button("编辑…") { editing = true }.buttonStyle(WMButtonStyle())
            }
            .sheet(isPresented: $editing) {
                JSONFieldEditor(field: field, value: shown) { commit($0) }
            }
        }
    }

    private var help: String {
        var parts: [String] = []
        if let help = field.help, !help.isEmpty { parts.append(help) }
        if let min = field.min, let max = field.max { parts.append("范围 \(Self.fmt(min))–\(Self.fmt(max))") }
        parts.append(store.config?.meta[field.key]?.text ?? "默认：\(field.default?.displayText ?? "—")")
        return parts.joined(separator: "\n")
    }

    /// 步进器每点一下先记着，停手 0.8 秒后写一次（撤销回到点之前的值）。
    private func nudge(_ value: Double) {
        number = value
        numberCommit?.cancel()
        numberCommit = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commit(.number(value))
        }
    }

    private func commitText() {
        guard let text else { return }
        commit(.string(text.trimmingCharacters(in: .whitespaces)))
    }

    private func commit(_ value: JSONValue) {
        let old = stored
        guard value != old else {
            number = nil
            text = nil
            return
        }
        Task {
            await store.change(
                ["config", "set", field.key, value.jsonText],
                undo: ["config", "set", field.key, old.jsonText],
                pendingKey: "config.\(field.key)", pendingValue: value)
            number = nil
            text = nil
        }
    }

    static func summary(_ value: JSONValue) -> String {
        switch value {
        case let .array(items): items.isEmpty ? "无" : items.map(\.displayText).joined(separator: "、")
        case let .object(object): object.isEmpty ? "无" : "\(object.count) 项"
        default: value.displayText
        }
    }

    static func fmt(_ v: Double) -> String { v.rounded() == v ? String(Int(v)) : String(v) }

    /// 「公招次数」→ 无单位；「…（分钟）」→ 分钟。
    static func unit(_ label: String) -> String {
        guard let open = label.lastIndex(of: "（"), label.hasSuffix("）") else { return "" }
        return String(label[label.index(after: open)..<label.index(before: label.endIndex)])
    }

    static func stripUnit(_ label: String) -> String {
        guard let open = label.lastIndex(of: "（"), label.hasSuffix("）") else { return label }
        return String(label[..<open])
    }
}

/// 列表 / 表格类字段的编辑框：字符串列表一行一项，其余是 JSON。点「好」就写。
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
                .help(field.kind == "str_list" ? "一行一项" : "照原来的格式改")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(WM.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(WMButtonStyle()).keyboardShortcut(.cancelAction)
                Button("好") { done() }.buttonStyle(WMButtonStyle(kind: .accent))
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
            error = "格式不对，检查一下括号、引号和逗号"
            return
        }
        apply(parsed)
        dismiss()
    }
}

/// 改完一项设置后窗口底部的回执：「已保存 · 撤销」，几秒后自己收起。
struct SavedToast: View {
    @Environment(RemoteStore.self) private var store
    let change: SavedChange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(WM.ok)
            Text(change.text)
            if change.undo != nil {
                Button("撤销") { Task { await store.undoSaved() } }
                    .buttonStyle(WMLinkStyle())
            }
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(WM.line2, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}
