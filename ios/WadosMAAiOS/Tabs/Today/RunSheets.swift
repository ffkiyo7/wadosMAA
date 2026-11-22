//
//  RunSheets.swift
//  Wado's MAA (iOS)
//
//  现在开一场（E14 + E31）和换关（E15）。
//

import SwiftUI
import WadosMAAShared

// MARK: - 现在开一场

struct StartRunSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private static let order = ["fight", "annihilation", "infrast", "recruit", "mall", "award"]

    @State private var stage = ""
    @State private var switches: [String: Bool] = [:]
    @State private var didSetUp = false
    @State private var isConfirming = false
    @State private var forceTitle: String?
    @State private var isStarting = false
    @State private var isPickingStage = false

    private var choices: [RunChoices.Choice] { store.choices?.choices ?? [] }
    private var keys: [String] {
        let available = store.choices?.switches ?? Self.order
        return Self.order.filter(available.contains)
    }

    /// 剿灭不算「有事可做」：后端要求五项主环节至少开一项。
    private var hasWork: Bool {
        keys.contains { $0 != "annihilation" && (switches[$0] ?? false) }
    }

    private var enabledCount: Int {
        keys.filter { switches[$0] ?? false }.count
    }

    private var busyText: String {
        if let run = store.activeRun { return "\(run.title)运行中" }
        return store.choices?.busy ?? ""
    }

    private var canStart: Bool {
        store.canWrite && busyText.isEmpty && hasWork && !stage.isEmpty && !isStarting
    }

    private var quickStages: [RunChoices.Choice] {
        Array(choices.prefix(4))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stageSection
                    switchSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                startButton
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .navigationTitle("现在开一场")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
            .task {
                await store.refreshChoices()
                setUp()
            }
            .sheet(isPresented: $isPickingStage) {
                StagePickerSheet(title: "全部关卡", current: stage, choices: choices, showsAuto: false) { picked in
                    if let picked { stage = picked }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关卡")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            WCard(vertical: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(quickStages.enumerated()), id: \.element) { index, choice in
                        if index > 0 { Hairline() }
                        Button {
                            stage = choice.stage
                        } label: {
                            StageChoiceRow(
                                title: choice.label.isEmpty ? choice.stage : choice.label,
                                detail: choice.description, isSelected: stage == choice.stage)
                        }
                        .buttonStyle(.plain)
                    }
                    if !quickStages.isEmpty { Hairline() }
                    Button {
                        isPickingStage = true
                    } label: {
                        HStack {
                            Text("全部关卡").scaledFont(size: 16)
                            Spacer()
                            if !quickStages.contains(where: { $0.stage == stage }), !stage.isEmpty {
                                Text(stage).foregroundStyle(Palette.blue).scaledFont(size: 16, weight: .semibold)
                            }
                            Image(systemName: "chevron.right")
                                .scaledFont(size: 12, weight: .bold)
                                .foregroundStyle(Palette.secondary)
                        }
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var switchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("环节")
                .scaledFont(size: 15, weight: .semibold)
                .foregroundStyle(Palette.secondary)
                .padding(.horizontal, 4)
            WCard(horizontal: 12, vertical: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(keys, id: \.self) { key in
                        Button {
                            switches[key] = !(switches[key] ?? false)
                        } label: {
                            PillLabel(
                                title: key == "mall" ? "商店" : DailyTaskName.title(key),
                                symbol: DailyTaskName.symbol(key), isOn: switches[key] ?? false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits((switches[key] ?? false) ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var startButton: some View {
        Button {
            let blackout = store.choices?.blackout ?? ""
            forceTitle = blackout.isEmpty ? nil : blackout
            isConfirming = true
        } label: {
            Group {
                if isStarting {
                    ProgressView().tint(.white)
                } else if !busyText.isEmpty {
                    Text(busyText)
                } else {
                    Label("开始", systemImage: "play.fill")
                }
            }
            .scaledFont(size: 18, weight: .bold)
            .foregroundStyle(canStart ? Color.white : Palette.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(canStart ? Palette.accent : Palette.ghost, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .confirmationDialog(forceTitle ?? "现在开一场？", isPresented: $isConfirming, titleVisibility: .visible) {
            if forceTitle == nil {
                Button("开始") { start(force: false) }
            } else {
                Button("仍要开始", role: .destructive) { start(force: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(forceTitle == nil ? "\(stage) · 本次 \(enabledCount) 个环节" : "现在开始会占用这段时间")
        }
    }

    private func setUp() {
        guard !didSetUp, !choices.isEmpty else { return }
        didSetUp = true
        let session = store.focusSession
        let planned = session?.stage ?? ""
        stage = choices.contains { $0.stage == planned } ? planned : choices.first?.stage ?? planned
        var values: [String: Bool] = [:]
        for key in keys {
            values[key] = key == "annihilation" ? false : (session?.tasks[key] ?? true)
        }
        switches = values
    }

    private func start(force: Bool) {
        isStarting = true
        Task {
            var payload: [String: Bool] = [:]
            for key in keys { payload[key] = switches[key] ?? false }
            let outcome = await store.startRun(stage: stage, switches: payload, force: force)
            isStarting = false
            switch outcome {
            case .started: dismiss()
            case let .needsForce(message):
                forceTitle = message.isEmpty ? "定时场快开始了" : message
                isConfirming = true
            case .failed: break
            }
        }
    }
}

struct StageChoiceRow: View {
    let title: String
    var detail = ""
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(size: 16, weight: isSelected ? .bold : .regular)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .scaledFont(size: 14)
                        .foregroundStyle(Palette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(Palette.blue)
            }
        }
        .frame(minHeight: 48)
        .contentShape(.rect)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 换关（E15）

struct ChangeStageSheet: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session

    var body: some View {
        StagePickerSheet(
            title: "\(session.name)关卡",
            current: session.stageSource == "auto" ? nil : session.stage,
            choices: session.choices.isEmpty ? (store.choices?.choices ?? []) : session.choices,
            showsAuto: true,
            autoDetail: autoDetail,
            activityName: store.choices?.activity?.name,
            activityStages: store.choices?.activity?.stages ?? []
        ) { picked in
            Task {
                if let picked {
                    await store.setStage(phase: session.phase, stage: picked)
                } else {
                    await store.setAutoStage(phase: session.phase)
                }
            }
        }
    }

    private var autoDetail: String {
        let drop = session.drops.first?.name
        return [session.stageSource == "auto" ? session.stage : session.fallbackStage, drop]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// 选关：`nil` 代表自动定关。
struct StagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let current: String?
    let choices: [RunChoices.Choice]
    var showsAuto = false
    var autoDetail = ""
    var activityName: String?
    var activityStages: [String] = []
    let onPick: (String?) -> Void

    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filtered: [RunChoices.Choice] {
        guard !trimmedQuery.isEmpty else { return choices }
        return choices.filter {
            $0.stage.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.label.localizedCaseInsensitiveContains(trimmedQuery)
                || $0.description.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    private var activityChoices: [RunChoices.Choice] {
        filtered.filter { activityStages.contains($0.stage) }
    }

    private var otherChoices: [RunChoices.Choice] {
        filtered.filter { !activityStages.contains($0.stage) }
    }

    /// 列表外的关卡名，交给后端白名单校验。
    private var customStage: String? {
        let text = trimmedQuery.uppercased()
        guard text.range(of: #"^[A-Z0-9]{1,8}(-[A-Z0-9]{1,4}){1,2}$"#, options: .regularExpression) != nil,
            !choices.contains(where: { $0.stage.uppercased() == text })
        else { return nil }
        return text
    }

    var body: some View {
        NavigationStack {
            List {
                if showsAuto, trimmedQuery.isEmpty {
                    Section {
                        Button {
                            pick(nil)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "sparkles").foregroundStyle(Palette.blue).frame(width: 24)
                                StageChoiceRow(title: "自动定关", detail: autoDetail, isSelected: current == nil)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !activityChoices.isEmpty {
                    Section(activityName ?? "活动") {
                        ForEach(activityChoices, id: \.self, content: row)
                    }
                }
                if !otherChoices.isEmpty {
                    Section {
                        ForEach(otherChoices, id: \.self, content: row)
                    }
                }
                if let customStage {
                    Section {
                        Button {
                            pick(customStage)
                        } label: {
                            StageChoiceRow(title: customStage, isSelected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索关卡或材料")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ choice: RunChoices.Choice) -> some View {
        Button {
            pick(choice.stage)
        } label: {
            StageChoiceRow(
                title: choice.label.isEmpty ? choice.stage : choice.label,
                detail: choice.description, isSelected: current == choice.stage)
        }
        .buttonStyle(.plain)
    }

    private func pick(_ stage: String?) {
        onPick(stage)
        dismiss()
    }
}
