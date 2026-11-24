//
//  AdvancedSettingsView.swift
//  Wado's MAA (iOS)
//
//  设置 → 高级（S4-3，SPEC §6.4 的 P2 分组）。只认后端 `maa_settings.FIELDS` 白名单，
//  这里不放任何降级开关、森空岛 token 或底层路径。
//

import SwiftUI
import WadosMAAShared

struct AdvancedGroup: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    let keys: [String]

    static let all: [AdvancedGroup] = [
        AdvancedGroup(
            id: "proxy", title: "代理指挥", symbol: "person.2",
            keys: ["proxy_failure_limit", "proxy_failure_salvage"]),
        AdvancedGroup(
            id: "farming", title: "自动定关", symbol: "chart.bar",
            keys: [
                "farming_weights", "farming_min_samples", "farming_target_days", "farming_activity_edge",
                "farming_rerun_days", "farming_scarcity_horizon_days", "farming_stage_table",
                "farming_manual_weights",
            ]),
        AdvancedGroup(id: "skland", title: "森空岛", symbol: "person.text.rectangle", keys: ["skland_roster_refresh_days"]),
        AdvancedGroup(
            id: "run", title: "运行参数", symbol: "timer",
            keys: [
                "game_launch_timeout", "game_quit_timeout", "game_probe_timeout", "maa_run_timeout",
                "update_wait_minutes", "connect_retry_limit", "offline_retry_limit", "retention_days",
                "resource_update_timeout", "maa_cli_update_timeout",
            ]),
        AdvancedGroup(
            id: "host", title: "Mac 窗口", symbol: "macwindow",
            keys: ["game_display_name", "disable_stage_manager_during_run"]),
    ]
}

struct AdvancedSettingsView: View {
    var body: some View {
        List(AdvancedGroup.all) { group in
            NavigationLink(value: group) {
                Label(group.title, systemImage: group.symbol)
            }
        }
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AdvancedGroup.self) { group in
            AdvancedGroupView(group: group)
        }
    }
}

/// 「掉率至少要统计多少次才可信（次）」→ 标题 + 单位。
struct FieldTitle {
    let title: String
    let unit: String

    init(_ label: String) {
        if label.hasSuffix("）"), let open = label.lastIndex(of: "（") {
            title = String(label[..<open])
            unit = String(label[label.index(after: open)..<label.index(before: label.endIndex)])
        } else {
            title = label
            unit = ""
        }
    }
}

private struct AdvancedGroupView: View {
    @Environment(AppStore.self) private var store
    let group: AdvancedGroup
    @FocusState private var focus: String?

    private var fields: [ConfigField] {
        group.keys.compactMap(store.configField)
    }

    private var scalarFields: [ConfigField] {
        fields.filter { !["weights", "stage_table", "number_table"].contains($0.kind) }
    }

    var body: some View {
        Form {
            if store.settings == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                ForEach(fields.filter { $0.kind == "weights" }) { field in
                    WeightsEditor(field: field, focus: $focus)
                }
                Section {
                    ForEach(scalarFields) { field in
                        FieldRow(field: field, focus: $focus)
                    }
                } footer: {
                    if group.id == "host" {
                        Text("改的是 Mac mini 上的游戏窗口。")
                    }
                }
                ForEach(fields.filter { $0.kind == "stage_table" || $0.kind == "number_table" }) { field in
                    TableEditor(field: field)
                }
            }
        }
        .disabled(!store.canWrite)
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focus = nil }
            }
        }
        .task { await store.loadSettings() }
    }
}

// MARK: - 单项

private struct FieldRow: View {
    @Environment(AppStore.self) private var store
    let field: ConfigField
    var focus: FocusState<String?>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            editor
            if let help = field.help, !help.isEmpty {
                Text(help).font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
    }

    @ViewBuilder private var editor: some View {
        switch field.kind {
        case "bool":
            Toggle(
                FieldTitle(field.label).title,
                isOn: Binding(
                    get: { store.configBool(field.key) },
                    set: { store.changeConfig(field.key, to: .bool($0)) }))
        case "int" where span <= 10:
            stepper
        case "int", "float":
            NumberFieldRow(field: field, focus: focus)
        case "text":
            TextFieldRow(field: field, focus: focus)
        default:
            LabeledContent(field.label, value: store.configValue(field.key)?.displayText ?? "—")
        }
    }

    private var span: Double {
        guard let low = field.min, let high = field.max else { return .infinity }
        return high - low
    }

    private var stepper: some View {
        let parts = FieldTitle(field.label)
        let fallback = field.default?.number.map { Int($0) } ?? 0
        let value = store.configInt(field.key, fallback: fallback)
        let range = store.configRange(field.key, fallback: 0...10)
        return Stepper(
            value: Binding(
                get: { value },
                set: { store.changeConfig(field.key, to: .number(Double($0)), debounce: .milliseconds(400)) }),
            in: range
        ) {
            HStack {
                Text(parts.title)
                Spacer(minLength: 8)
                Text(parts.unit.isEmpty ? "\(value)" : "\(value) \(parts.unit)")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// 范围大的整数和小数：直接输入，离开输入框时校验并保存。
private struct NumberFieldRow: View {
    @Environment(AppStore.self) private var store
    let field: ConfigField
    var focus: FocusState<String?>.Binding
    @State private var text = ""

    private var isInt: Bool { field.kind == "int" }

    var body: some View {
        let parts = FieldTitle(field.label)
        HStack {
            Text(parts.title)
            Spacer(minLength: 12)
            TextField("", text: $text)
                .keyboardType(isInt ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 88)
                .focused(focus, equals: field.key)
            if !parts.unit.isEmpty {
                Text(parts.unit).foregroundStyle(Palette.secondary)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: store.configValue(field.key)) { _, _ in
            if focus.wrappedValue != field.key { sync() }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            if old == field.key, new != field.key { commit() }
        }
    }

    private func sync() {
        text = store.configValue(field.key)?.number.map(Self.format) ?? ""
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let number = Double(trimmed), number.isFinite, !isInt || number.rounded() == number else {
            store.showToast(AppToast(text: isInt ? "要填整数" : "要填数字"))
            sync()
            return
        }
        if let low = field.min, let high = field.max, !(low...high).contains(number) {
            store.showToast(AppToast(text: "要在 \(Self.format(low))–\(Self.format(high)) 之间"))
            sync()
            return
        }
        guard store.configValue(field.key)?.number != number else { return }
        store.changeConfig(field.key, to: .number(number), toast: "已保存")
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }
}

private struct TextFieldRow: View {
    @Environment(AppStore.self) private var store
    let field: ConfigField
    var focus: FocusState<String?>.Binding
    @State private var text = ""

    var body: some View {
        HStack {
            Text(field.label)
            Spacer(minLength: 12)
            TextField("不挪窗口", text: $text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused(focus, equals: field.key)
                .onSubmit { focus.wrappedValue = nil }
        }
        .onAppear(perform: sync)
        .onChange(of: store.configValue(field.key)) { _, _ in
            if focus.wrappedValue != field.key { sync() }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            guard old == field.key, new != field.key else { return }
            let value = text.trimmingCharacters(in: .whitespaces)
            if store.configValue(field.key)?.string != value {
                store.changeConfig(field.key, to: .string(value), toast: "已保存")
            }
        }
    }

    private func sync() {
        text = store.configValue(field.key)?.string ?? ""
    }
}

// MARK: - 三项权重

private struct WeightsEditor: View {
    @Environment(AppStore.self) private var store
    let field: ConfigField
    var focus: FocusState<String?>.Binding
    @State private var texts: [String: String] = [:]

    private static let parts = [("scarcity", "稀缺"), ("gap", "缺口"), ("efficiency", "效率")]

    var body: some View {
        Section {
            ForEach(Self.parts, id: \.0) { key, title in
                HStack {
                    Text(title)
                    Spacer()
                    TextField(
                        "", text: Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 88)
                    .focused(focus, equals: "\(field.key).\(key)")
                }
            }
        } header: {
            // 「选关时看重什么：稀缺 / 缺口 / 效率」：三项已经是下面的行名。
            Text(field.label.split(separator: "：").first.map(String.init) ?? field.label)
        } footer: {
            if let help = field.help { Text(help) }
        }
        .onAppear(perform: sync)
        .onChange(of: store.configValue(field.key)) { _, _ in
            if !isEditing(focus.wrappedValue) { sync() }
        }
        .onChange(of: focus.wrappedValue) { old, new in
            if isEditing(old), !isEditing(new) { commit() }
        }
    }

    private func isEditing(_ key: String?) -> Bool {
        key?.hasPrefix("\(field.key).") == true
    }

    private func current() -> [String: Double] {
        (store.configValue(field.key)?.object ?? [:]).compactMapValues(\.number)
    }

    private func sync() {
        let values = current()
        texts = Dictionary(uniqueKeysWithValues: Self.parts.map { key, _ in
            (key, values[key].map(NumberFieldRow.format) ?? "")
        })
    }

    private func commit() {
        var result: [String: JSONValue] = [:]
        for (key, _) in Self.parts {
            guard let number = Double((texts[key] ?? "").trimmingCharacters(in: .whitespaces)), number >= 0,
                number.isFinite
            else {
                store.showToast(AppToast(text: "权重要填不小于 0 的数"))
                sync()
                return
            }
            result[key] = .number(number)
        }
        guard result.values.contains(where: { ($0.number ?? 0) > 0 }) else {
            store.showToast(AppToast(text: "权重不能全是 0"))
            sync()
            return
        }
        guard result.compactMapValues(\.number) != current() else { return }
        store.changeConfig(field.key, to: .object(result), toast: "已保存")
    }
}

// MARK: - 材料表

/// `farming_stage_table`（材料 → 关卡）和 `farming_manual_weights`（材料 → 权重）。
private struct TableEditor: View {
    @Environment(AppStore.self) private var store
    let field: ConfigField
    @State private var isAdding = false
    @State private var newKey = ""
    @State private var newValue = ""

    private var isStageTable: Bool { field.kind == "stage_table" }

    private var entries: [(String, JSONValue)] {
        (store.configValue(field.key)?.object ?? [:]).sorted { $0.key < $1.key }
    }

    var body: some View {
        Section {
            ForEach(entries, id: \.0) { key, value in
                LabeledContent(key, value: value.string ?? value.number.map(NumberFieldRow.format) ?? "—")
            }
            .onDelete { offsets in
                var table = store.configValue(field.key)?.object ?? [:]
                for index in offsets { table[entries[index].0] = nil }
                store.changeConfig(field.key, to: .object(table), toast: "已删除")
            }
            Button("添加", systemImage: "plus") { isAdding = true }
        } header: {
            Text(field.label)
        } footer: {
            if let help = field.help { Text(help) }
        }
        .alert(field.label, isPresented: $isAdding) {
            TextField("材料名", text: $newKey)
            TextField(isStageTable ? "关卡，如 1-7" : "权重 0–1000", text: $newValue)
                .keyboardType(isStageTable ? .asciiCapable : .decimalPad)
                .textInputAutocapitalization(.characters)
            Button("添加") { add() }
            Button("取消", role: .cancel) { reset() }
        }
    }

    private func add() {
        defer { reset() }
        let key = newKey.trimmingCharacters(in: .whitespaces)
        let raw = newValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !raw.isEmpty else { return }
        let value: JSONValue
        if isStageTable {
            value = .string(raw.uppercased())
        } else {
            guard let number = Double(raw), (0...1000).contains(number) else {
                store.showToast(AppToast(text: "权重要在 0–1000 之间"))
                return
            }
            value = .number(number)
        }
        var table = store.configValue(field.key)?.object ?? [:]
        table[key] = value
        store.changeConfig(field.key, to: .object(table), toast: "已添加")
    }

    private func reset() {
        newKey = ""
        newValue = ""
    }
}
