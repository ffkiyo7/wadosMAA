//
//  DailyTab.swift
//  Wado's MAA (iOS)
//
//  日常长期规则（E7、E29）和信用商店（E22）。改动即时生效，带撤销提示。
//

import SwiftUI
import WadosMAAShared

private struct TimeTarget: Identifiable {
    let phase: String
    let name: String
    let time: String
    var id: String { phase }
}

struct DailyTab: View {
    @Environment(AppStore.self) private var store
    @State private var timeTarget: TimeTarget?
    @State private var isPickingStage = false
    @State private var isBlackoutPresented = false

    private static let taskKeys = ["fight", "infrast", "recruit", "mall", "award"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.settings == nil, store.snapshot?.schedule == nil, store.connection == .connecting {
                        SkeletonBlock(height: 100)
                        SkeletonBlock(height: 56)
                        SkeletonBlock(height: 120)
                        SkeletonBlock(height: 150)
                    } else {
                        scheduleCards
                        blackoutRow
                        defaultStageCard
                        tasksCard
                        medicineCard
                        recruitCard
                        ConfigStepperCard(
                            key: "annihilation_sanity", title: "剿灭预留", unit: "理智", color: Palette.red,
                            fallback: 25, range: 0...135, step: 5)
                        reportCard
                        awardCard
                        shopRow
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .connectionBanner()
            .navigationTitle("日常")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let text = lastChangeText {
                        Text(text)
                            .scaledFont(size: 14)
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondary)
                            .fixedSize()
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .refreshable {
                await store.loadSettings()
                await store.refreshSnapshot()
            }
            .task(id: store.connection.isOnline) {
                if store.connection.isOnline { await store.loadSettings() }
            }
            .sheet(item: $timeTarget) { target in
                SessionTimeSheet(target: target)
            }
            .sheet(isPresented: $isPickingStage) {
                StagePickerSheet(
                    title: "默认关卡", current: store.dailyDefaults?.stage,
                    choices: store.choices?.choices ?? [],
                    activityName: store.choices?.activity?.name,
                    activityStages: store.choices?.activity?.stages ?? []
                ) { picked in
                    if let picked { Task { await store.setDefaultStage(picked) } }
                }
            }
            .sheet(isPresented: $isBlackoutPresented) {
                BlackoutSheet()
            }
            .navigationDestination(for: CreditShopRoute.self) { _ in CreditShopView() }
        }
    }

    /// 「iOS 21:48」：配置和默认项里最近的一次修改。
    private var lastChangeText: String? {
        var metas = Array(store.settings?.meta.values ?? [:].values)
        if let meta = store.dailyDefaults?.meta { metas.append(meta) }
        let latest = metas
            .compactMap { meta -> (ChangeMeta, Date)? in
                guard let text = meta.updatedAt, let date = BeijingTime.parseISO(text) else { return nil }
                return (meta, date)
            }
            .max { $0.1 < $1.1 }
        guard let latest else { return nil }
        let who: String
        switch latest.0.source {
        case "ios": who = "iOS"
        case "gui": who = "Mac"
        case "discord": who = "Discord"
        default: who = latest.0.source ?? ""
        }
        return "\(who) \(BeijingTime.clock(latest.1))"
    }

    // MARK: - 时间表

    private var scheduleCards: some View {
        HStack(spacing: 10) {
            sessionCard(phase: "am", name: "早场", color: Palette.amber, fallback: "08:00")
            sessionCard(phase: "pm", name: "晚场", color: Palette.blue, fallback: "22:00")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionCard(phase: String, name: String, color: Color, fallback: String) -> some View {
        let session = store.snapshot?.schedule?.sessions[phase]
        let time = session?.time ?? fallback
        let enabled = session?.enabled ?? true
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(color)
                Spacer()
                Toggle(
                    name,
                    isOn: Binding(
                        get: { enabled },
                        set: { value in Task { await store.setSessionEnabled(phase: phase, enabled: value) } })
                )
                .labelsHidden()
                .disabled(!store.canWrite || session == nil)
            }
            Button {
                timeTarget = TimeTarget(phase: phase, name: name, time: time)
            } label: {
                Text(time)
                    .scaledFont(size: 30, weight: .heavy)
                    .monospacedDigit()
                    .foregroundStyle(enabled ? Color.primary : Palette.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!store.canWrite || session == nil)
            .accessibilityLabel("\(name)时间 \(time)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private var blackoutRow: some View {
        Button {
            isBlackoutPresented = true
        } label: {
            WCard(vertical: 0) {
                HStack {
                    Text("保护窗口").scaledFont(size: 16, weight: .semibold)
                    Spacer()
                    MoreLabel(title: "\(store.configInt("manual_run_blackout_minutes", fallback: 30)) 分")
                }
                .frame(minHeight: 56)
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.canWrite)
    }

    // MARK: - 默认项

    private var defaultStageCard: some View {
        Button {
            isPickingStage = true
        } label: {
            WCard {
                VStack(alignment: .leading, spacing: 4) {
                    MoreLabel(title: "默认关卡", color: Palette.blue)
                    Text(defaultStageText)
                        .scaledFont(size: 30, weight: .heavy)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.canWrite)
    }

    private var defaultStageText: String {
        guard let stage = store.dailyDefaults?.stage else { return "—" }
        return stage.isEmpty ? "上次的关" : stage
    }

    private var tasksCard: some View {
        WCard(horizontal: 16, vertical: 13) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Self.taskKeys, id: \.self) { task in
                    let isOn = store.defaultTask(task)
                    Button {
                        Task { await store.setDefaultTask(task, enabled: !isOn) }
                    } label: {
                        PillLabel(title: DailyTaskName.title(task), symbol: DailyTaskName.symbol(task), isOn: isOn)
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.canWrite)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - 刷理智与公招

    private var medicineCard: some View {
        let value = store.configInt("medicine_expire_days", fallback: 2)
        let bounds = store.configRange("medicine_expire_days", fallback: 0...7)
        return WCard(vertical: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("临期药")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Palette.orange)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            Capsule()
                                .fill(day <= value ? Palette.orange : Palette.ghost)
                                .frame(width: 6, height: 22)
                        }
                    }
                    .accessibilityHidden(true)
                }
                HStack {
                    if value == 0 {
                        Text("不吃").scaledFont(size: 30, weight: .heavy)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("\(value)").scaledFont(size: 30, weight: .heavy).monospacedDigit()
                            Text("天内")
                                .scaledFont(size: 15, weight: .semibold)
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    Spacer()
                    StepperPill(
                        canDecrease: store.canWrite && value > bounds.lowerBound,
                        canIncrease: store.canWrite && value < bounds.upperBound,
                        decrease: { changeMedicine(value - 1) },
                        increase: { changeMedicine(value + 1) },
                        title: "临期药天数")
                }
            }
        }
    }

    private func changeMedicine(_ next: Int) {
        store.changeConfig(
            "medicine_expire_days", to: .number(Double(next)),
            toast: next == 0 ? "临期药改为不吃" : "临期药改为 \(next) 天", debounce: .milliseconds(450))
    }

    private var recruitCard: some View {
        let value = store.configInt("recruit_times", fallback: 4)
        let bounds = store.configRange("recruit_times", fallback: 0...4)
        return WCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("公招")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Palette.pink)
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach(1...4, id: \.self) { index in
                            Circle()
                                .fill(index <= value ? Palette.pink : Palette.ghost)
                                .frame(width: 16, height: 16)
                        }
                    }
                    .accessibilityHidden(true)
                }
                HStack {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(value)").scaledFont(size: 30, weight: .heavy).monospacedDigit()
                        Text("次")
                            .scaledFont(size: 15, weight: .semibold)
                            .foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    StepperPill(
                        canDecrease: store.canWrite && value > bounds.lowerBound,
                        canIncrease: store.canWrite && value < bounds.upperBound,
                        decrease: { changeRecruit(value - 1) },
                        increase: { changeRecruit(value + 1) },
                        title: "公招次数")
                }
            }
        }
    }

    private func changeRecruit(_ next: Int) {
        store.changeConfig(
            "recruit_times", to: .number(Double(next)), toast: "公招改为 \(next) 次", debounce: .milliseconds(450))
    }

    private var reportCard: some View {
        WCard(vertical: 0) {
            ConfigToggleRow(key: "report_drops", title: "掉落上报")
        }
    }

    private var awardCard: some View {
        WCard(vertical: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("领奖")
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Palette.violet)
                    .padding(.top, 4)
                ConfigToggleRow(key: "award_orundum", title: "幸运墙")
                Hairline()
                ConfigToggleRow(key: "award_mining", title: "采矿")
                Hairline()
                ConfigToggleRow(key: "award_specialaccess", title: "月卡")
            }
        }
    }

    private var shopRow: some View {
        NavigationLink(value: CreditShopRoute()) {
            WCard(vertical: 0) {
                HStack {
                    Text("信用商店").scaledFont(size: 16, weight: .semibold)
                    Spacer()
                    MoreLabel(title: store.configBool("mall_reserve_max_credit") ? "300 停买" : "")
                }
                .frame(minHeight: 56)
            }
        }
        .buttonStyle(.plain)
    }
}

struct ConfigToggleRow: View {
    @Environment(AppStore.self) private var store
    let key: String
    let title: String

    var body: some View {
        Toggle(
            title,
            isOn: Binding(
                get: { store.configBool(key) },
                set: { value in
                    store.changeConfig(key, to: .bool(value), toast: "\(title)已\(value ? "打开" : "关闭")")
                })
        )
        .scaledFont(size: 16)
        .frame(minHeight: 48)
        .disabled(!store.canWrite || store.settings == nil)
    }
}

// MARK: - 时间选择（E29）

private struct SessionTimeSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let target: TimeTarget
    @State private var hour = 8
    @State private var minute = 0

    /// 早场 05:00–11:59，晚场 12:00–23:59。
    private var hours: ClosedRange<Int> {
        target.phase == "am" ? 5...11 : 12...23
    }

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("时", selection: $hour) {
                    ForEach(Array(hours), id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .pickerStyle(.wheel)
                Picker("分", selection: $minute) {
                    ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
                }
                .pickerStyle(.wheel)
            }
            .monospacedDigit()
            .padding(.horizontal, 16)
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let time = String(format: "%02d:%02d", hour, minute)
                        if time != target.time {
                            Task { await store.setSessionTime(phase: target.phase, time: time) }
                        }
                        dismiss()
                    }
                    .disabled(!store.canWrite)
                }
            }
            .onAppear {
                let parts = target.time.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2 {
                    hour = min(max(parts[0], hours.lowerBound), hours.upperBound)
                    minute = parts[1]
                }
            }
        }
        .presentationDetents([.height(340)])
    }
}

private struct BlackoutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConfigStepperCard(
                key: "manual_run_blackout_minutes", title: "早晚场前不接手动日常", unit: "分",
                color: Palette.blue, fallback: 30, range: 0...180, step: 5, zeroText: "不保护")
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("保护窗口")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
        .presentationDetents([.height(230)])
    }
}

// MARK: - 信用商店（E22）

struct CreditShopRoute: Hashable {}

struct CreditShopView: View {
    @Environment(AppStore.self) private var store
    @State private var editMode: EditMode = .inactive
    @State private var buyFirst: [String] = []
    @State private var blacklist: [String] = []
    @State private var addTarget: AddTarget?
    @State private var newItem = ""

    private enum AddTarget: String, Identifiable {
        case buy, block
        var id: String { rawValue }
    }

    private var isEditing: Bool { editMode == .active }

    var body: some View {
        List {
            itemSection("优先买", color: Palette.green, items: $buyFirst, key: "mall_buy_first", target: .buy)
            itemSection("不买", color: Palette.red, items: $blacklist, key: "mall_blacklist", target: .block)
            if !isEditing {
                Section {
                    ConfigToggleRow(key: "mall_reserve_max_credit", title: "低于 300 停买")
                    ConfigToggleRow(key: "mall_only_buy_discount", title: "只买打折")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("信用商店")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "完成" : "编辑") {
                    withAnimation { editMode = isEditing ? .inactive : .active }
                }
                .disabled(!store.canWrite)
            }
        }
        .task {
            await store.loadSettings()
            sync()
        }
        .onChange(of: store.settings?.values["mall_buy_first"]) { _, _ in sync() }
        .onChange(of: store.settings?.values["mall_blacklist"]) { _, _ in sync() }
        .alert(
            addTarget == .block ? "添加不买" : "添加优先买",
            isPresented: Binding(get: { addTarget != nil }, set: { if !$0 { addTarget = nil } })
        ) {
            TextField("物品名", text: $newItem)
            Button("添加") { addItem() }
            Button("取消", role: .cancel) { newItem = "" }
        }
    }

    private func itemSection(
        _ title: String, color: Color, items: Binding<[String]>, key: String, target: AddTarget
    ) -> some View {
        Section {
            if isEditing {
                ForEach(items.wrappedValue, id: \.self) { Text($0) }
                    .onMove { source, destination in
                        items.wrappedValue.move(fromOffsets: source, toOffset: destination)
                        save(key, items.wrappedValue)
                    }
                    .onDelete { offsets in
                        items.wrappedValue.remove(atOffsets: offsets)
                        save(key, items.wrappedValue)
                    }
                Button("添加", systemImage: "plus") { addTarget = target }
            } else if items.wrappedValue.isEmpty {
                Text("—").foregroundStyle(Palette.secondary)
            } else {
                Text(items.wrappedValue.joined(separator: "、"))
                    .scaledFont(size: 16)
            }
        } header: {
            Text(title).foregroundStyle(color)
        }
    }

    private func sync() {
        buyFirst = store.configList("mall_buy_first")
        blacklist = store.configList("mall_blacklist")
    }

    private func save(_ key: String, _ items: [String]) {
        store.changeConfig(key, to: .array(items.map(JSONValue.string)), debounce: .milliseconds(300))
    }

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        newItem = ""
        guard !text.isEmpty, let target = addTarget else { return }
        switch target {
        case .buy where !buyFirst.contains(text):
            buyFirst.append(text)
            save("mall_buy_first", buyFirst)
        case .block where !blacklist.contains(text):
            blacklist.append(text)
            save("mall_blacklist", blacklist)
        default:
            break
        }
    }
}
