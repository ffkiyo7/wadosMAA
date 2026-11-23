//
//  CopilotTab.swift
//  Wado's MAA (iOS)
//
//  抄作业（E5、E27）：未通在前，已通折叠成不可进入的关卡格；左滑标记，点手动记录可撤销。
//

import SwiftUI
import WadosMAAShared

struct CopilotRoute: Hashable {
    let stage: String
}

extension CopilotStageRow {
    var isCleared: Bool { status == "cleared" }

    /// 已通的关不用再搜；没导航的关点进去也搜不了。
    var canPreview: Bool { !isCleared && nav != false && status != "no_nav" && status != "not_indexed" }

    var displayCode: String { code?.isEmpty == false ? code ?? stage : stage }

    var statusTitle: String {
        switch status {
        case "cleared": "已通"
        case "scheduled": "排程中"
        case "gap": "练度不足"
        case "no_nav", "not_indexed": "无导航"
        case "raid_pending": "突袭待补"
        case "daily_cap": "今日已达上限"
        case "locked": "未解锁"
        default: "待抄"
        }
    }

    var statusColor: Color {
        switch status {
        case "cleared": Palette.green
        case "scheduled": Palette.amber
        case "gap": Palette.red
        case "raid_pending": Palette.blue
        case "daily_cap": Palette.orange
        default: Palette.secondary
        }
    }
}

struct CopilotTab: View {
    @Environment(AppStore.self) private var store
    @State private var isRulesPresented = false
    @State private var showsCleared = false
    @State private var categoryFilter: String?

    private var rows: [CopilotStageRow] {
        store.copilotStages?.stages ?? []
    }

    private func matchesFilter(_ row: CopilotStageRow) -> Bool {
        categoryFilter == nil || row.stageCategory == categoryFilter
    }

    private var pending: [CopilotStageRow] {
        rows.filter { !$0.isCleared && matchesFilter($0) }
    }

    private var cleared: [CopilotStageRow] {
        rows.filter { $0.isCleared && matchesFilter($0) }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.copilotPath) {
            Group {
                if let tally = store.copilotTally {
                    content(tally)
                } else if store.hasData, store.copilotStages != nil {
                    ContentUnavailableView("现在没有活动", systemImage: "square.on.square")
                } else if store.connection == .connecting {
                    VStack(spacing: 12) {
                        SkeletonBlock(height: 216)
                        SkeletonBlock(height: 320)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                } else {
                    Color.clear
                }
            }
            .connectionBanner()
            .navigationTitle(store.choices?.activity?.name ?? "抄作业")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.copilotTally != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("规则") { isRulesPresented = true }
                    }
                }
            }
            .navigationDestination(for: CopilotRoute.self) { CopilotPreviewView(stage: $0.stage) }
            .sheet(isPresented: $isRulesPresented) {
                CopilotRulesSheet()
            }
        }
    }

    private var autoToggle: some View {
        Toggle(
            isOn: Binding(
                get: { store.copilotAutoEnabled },
                set: { value in Task { await store.setCopilotAuto(value) } })
        ) {
            Text("自动抄作业").scaledFont(size: 17, weight: .bold)
        }
        .toggleStyle(.switch)
        .frame(minHeight: 44)
        .disabled(!store.canWrite)
    }

    private func content(_ tally: CopilotTally) -> some View {
        ScrollViewReader { proxy in
            stageList(tally)
                .onChange(of: showsCleared) { _, isShown in
                    guard isShown else { return }
                    // 等展开的格子排好版再滚，否则定位的还是收起时的高度。
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard showsCleared else { return }
                        withAnimation(.snappy) { proxy.scrollTo(Self.clearedHeaderID, anchor: .top) }
                    }
                }
        }
    }

    private static let clearedHeaderID = "cleared-header"

    private func stageList(_ tally: CopilotTally) -> some View {
        List {
            Section {
                header(tally)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    .listRowSeparator(.hidden)
            }
            Section {
                autoToggle
            }
            .listRowBackground(Palette.card)
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { row in
                        stageRow(row)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("我打过了") {
                                    Task { await store.markCopilot(stage: row.stage, cleared: true) }
                                }
                                .tint(Palette.green)
                                .disabled(!store.canWrite)
                            }
                    }
                }
                .listRowBackground(Palette.card)
            }
            if !cleared.isEmpty {
                Section {
                    Button {
                        withAnimation(.snappy) { showsCleared.toggle() }
                    } label: {
                        HStack {
                            Text("已通 \(cleared.count)").scaledFont(size: 16, weight: .bold)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12, weight: .bold)
                                .foregroundStyle(Palette.secondary)
                                .rotationEffect(.degrees(showsCleared ? 90 : 0))
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsCleared ? "已展开" : "已收起")
                    .id(Self.clearedHeaderID)
                    if showsCleared {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(cleared) { clearedCell($0) }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listRowBackground(Palette.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .refreshable { await store.refreshSnapshot() }
    }

    private func header(_ tally: CopilotTally) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                ActivityRings(tally: tally).frame(width: 200, height: 200)
                VStack(spacing: 8) {
                    filterButton("normal", title: "普通", group: tally.normal, color: Palette.teal)
                    filterButton("ex", title: "EX", group: tally.ex, color: Palette.violet)
                    filterButton("s", title: "S", group: tally.s, color: Palette.pink)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tally.remaining == 0 ? "全部通关" : "还差 \(tally.remaining) 关")
                    .scaledFont(size: 30, weight: .heavy)
                Spacer()
                if let end = store.choices?.activity?.end {
                    Text(BeijingDay.remaining(until: end))
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
    }

    private func filterButton(_ key: String, title: String, group: CopilotTally.Group, color: Color) -> some View {
        Button {
            withAnimation(.snappy) { categoryFilter = categoryFilter == key ? nil : key }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(color)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(group.done)").scaledFont(size: 24, weight: .heavy)
                    Text("/\(group.total)")
                        .scaledFont(size: 15, weight: .semibold)
                        .foregroundStyle(Palette.secondary)
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(categoryFilter == key ? Palette.raised : Palette.card, in: .rect(cornerRadius: 16, style: .continuous))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(group.done)/\(group.total)")
        .accessibilityAddTraits(categoryFilter == key ? .isSelected : [])
    }

    @ViewBuilder private func clearedCell(_ row: CopilotStageRow) -> some View {
        if row.ledgerCleared == true {
            Menu {
                Button("撤销通关记录", systemImage: "arrow.uturn.backward", role: .destructive) {
                    Task { await store.markCopilot(stage: row.stage, cleared: false) }
                }
            } label: {
                clearedLabel(row)
            }
            .buttonStyle(.plain)
            .disabled(!store.canWrite)
        } else {
            clearedLabel(row)
        }
    }

    private func clearedLabel(_ row: CopilotStageRow) -> some View {
        Text(row.displayCode)
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(Palette.green)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Palette.green.opacity(row.ledgerCleared == true ? 0.14 : 0.05),
                in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12))
    }

    @ViewBuilder private func stageRow(_ row: CopilotStageRow) -> some View {
        if row.canPreview {
            NavigationLink(value: CopilotRoute(stage: row.stage)) {
                stageLabel(row)
            }
        } else {
            stageLabel(row)
        }
    }

    private func stageLabel(_ row: CopilotStageRow) -> some View {
        HStack(spacing: 10) {
            Circle().fill(row.statusColor).frame(width: 12, height: 12)
            Text(row.displayCode)
                .scaledFont(size: 16, weight: .bold)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.statusTitle)
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(row.statusColor)
                .lineLimit(1)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }
}
