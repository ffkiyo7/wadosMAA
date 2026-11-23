//
//  TodayTab.swift
//  Wado's MAA (iOS)
//
//  今天（E1 概览、E2/E3 场次、E24 状态、E25 理智）。
//

import SwiftUI
import WadosMAAShared

private enum TodaySelection: Hashable {
    case overview, session, sanity
}

struct StageSheetTarget: Identifiable {
    let session: TodayPlan.Session
    var id: String { session.phase }
}

struct TodayTab: View {
    @Environment(AppStore.self) private var store
    @State private var selection: TodaySelection = .overview
    @State private var stageTarget: StageSheetTarget?

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ConnectionBanner()
                    ResourceStrip()
                    if store.hasData {
                        chips
                        switch selection {
                        case .overview:
                            TodayOverview(
                                onOpenSession: { withAnimation(.snappy) { selection = .session } },
                                onChangeStage: { stageTarget = StageSheetTarget(session: $0) })
                        case .session:
                            if let session = store.focusSession {
                                SessionPage(
                                    session: session,
                                    onChangeStage: { stageTarget = StageSheetTarget(session: $0) })
                            }
                        case .sanity:
                            SanityPage()
                        }
                    } else if store.connection == .connecting {
                        SkeletonBlock(height: 62)
                        SkeletonBlock(height: 211)
                        SkeletonBlock(height: 209)
                        SkeletonBlock(height: 123)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .refreshable { await store.refreshSnapshot() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("今天")
            .navigationDestination(for: RunRoute.self) { RunDetailView(runID: $0.id) }
            .navigationDestination(item: $store.runDetailRoute) { RunDetailView(runID: $0.id) }
            .navigationDestination(for: HistoryRoute.self) { _ in HistoryView() }
            .sheet(item: $stageTarget) { target in
                ChangeStageSheet(session: target.session)
            }
            .onChange(of: store.sanityStatus == nil) { _, missing in
                if missing, selection == .sanity { selection = .overview }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                chipButton(.overview, label: "概览") {
                    SevenDial(segments: DailyStep.allCases.map { .init(color: $0.color, fill: 1) })
                        .frame(width: 36, height: 36)
                }
                if let session = store.focusSession {
                    chipButton(.session, label: session.name) {
                        chipText(dot: chipColor(session), title: session.name, value: chipValue(session))
                    }
                }
                if let sanity = store.sanityStatus {
                    chipButton(.sanity, label: "理智") {
                        chipText(dot: Palette.orange, title: "理智", value: "\(sanity.current)/\(sanity.max)")
                    }
                }
                if let tally = store.copilotTally {
                    Button {
                        store.openCopilotList()
                    } label: {
                        chipText(
                            dot: Palette.teal, title: "抄作业",
                            value: tally.remaining == 0 ? "已通" : "差 \(tally.remaining) 关")
                            .chipBackground(isOn: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chipButton<Label: View>(
        _ value: TodaySelection, label: String, @ViewBuilder content: () -> Label
    ) -> some View {
        Button {
            withAnimation(.snappy) { selection = value }
        } label: {
            content().chipBackground(isOn: selection == value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }

    private func chipText(dot: Color, title: String, value: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(dot).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .scaledFont(size: 13)
                    .foregroundStyle(Palette.secondary)
                Text(value)
                    .scaledFont(size: 15, weight: .bold)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func chipColor(_ session: TodayPlan.Session) -> Color {
        switch store.status(of: session) {
        case .running: Palette.green
        case .failed: Palette.red
        case .skipped, .closed: Palette.secondary
        default: Palette.blue
        }
    }

    private func chipValue(_ session: TodayPlan.Session) -> String {
        if store.status(of: session) == .running, let position = store.activeRun?.dailyPosition {
            return "\(position)/\(DailyStep.allCases.count)"
        }
        return session.time
    }
}

private extension View {
    func chipBackground(isOn: Bool) -> some View {
        padding(.leading, 11)
            .padding(.trailing, 15)
            .frame(minWidth: 62, minHeight: 62)
            .background(isOn ? Palette.raised : Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
            .contentShape(.rect(cornerRadius: 20))
    }
}

// MARK: - 概览（E1）

private struct TodayOverview: View {
    @Environment(AppStore.self) private var store
    let onOpenSession: () -> Void
    let onChangeStage: (TodayPlan.Session) -> Void

    var body: some View {
        let focus = store.focusSession
        VStack(alignment: .leading, spacing: 12) {
            Text(store.headline(for: focus))
                .scaledFont(size: 30, weight: .heavy)
                .padding(.horizontal, 4)
                .padding(.top, 6)
            if let focus {
                FocusSessionCard(session: focus, onOpen: onOpenSession, onChangeStage: onChangeStage)
            }
            ForEach(store.planSessions.filter { $0.phase != focus?.phase }) { session in
                OtherSessionCard(session: session)
            }
            if let activity = store.choices?.activity, let tally = store.copilotTally {
                OverviewActivityCard(activity: activity, tally: tally)
            }
            RecentRunsCard()
        }
    }
}

private struct FocusSessionCard: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session
    let onOpen: () -> Void
    let onChangeStage: (TodayPlan.Session) -> Void

    private var status: SessionStatus { store.status(of: session) }

    var body: some View {
        WCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: onOpen) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                MoreLabel(title: session.name).frame(height: 24)
                                Text(session.time)
                                    .scaledFont(size: 42, weight: .heavy)
                                    .monospacedDigit()
                                    .tracking(-1)
                                Text(stageLine)
                                    .scaledFont(size: 16, weight: .semibold)
                                    .foregroundStyle(stageColor)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if status != .skipped {
                                SessionDial(session: session, status: status)
                                    .frame(width: 104, height: 104)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if store.canRestore(session) {
                        SessionRestoreButton(session: session, title: "恢复")
                            .frame(width: 92)
                    }
                }
                if status != .skipped {
                    Hairline()
                    SessionControls(session: session, status: status, onChangeStage: onChangeStage)
                }
            }
        }
    }

    private var stageLine: String {
        switch status {
        case .skipped: "已跳过"
        case .closed: "已关闭"
        case let .failed(record): record.reason.isEmpty ? "未完成" : record.displayReason
        default: session.stage.isEmpty ? "上次的关" : session.stage
        }
    }

    private var stageColor: Color {
        switch status {
        case .skipped, .closed: Palette.secondary
        case .failed: Palette.red
        default: Palette.blue
        }
    }
}

/// 另一场：跑完的显示结果，没跑的显示计划。
private struct OtherSessionCard: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session

    private var status: SessionStatus { store.status(of: session) }

    private var record: RunRecord? {
        switch status {
        case let .finished(record), let .failed(record): record
        default: nil
        }
    }

    var body: some View {
        if let record {
            NavigationLink(value: RunRoute(id: record.id)) {
                content(record: record)
            }
            .buttonStyle(.plain)
        } else {
            content(record: nil)
        }
    }

    private func content(record: RunRecord?) -> some View {
        WCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        if record != nil {
                            MoreLabel(title: session.name).frame(height: 24)
                        } else {
                            Text(session.name)
                                .scaledFont(size: 15, weight: .semibold)
                                .foregroundStyle(Palette.secondary)
                                .frame(height: 24)
                        }
                        ForEach(lines(record), id: \.text) { line in
                            HStack(spacing: 9) {
                                Circle().fill(line.color).frame(width: 12, height: 12)
                                Text(line.text)
                                    .scaledFont(size: 18, weight: .bold)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if store.canRestore(session) {
                        SessionRestoreButton(session: session, title: "恢复")
                            .frame(width: 92)
                    } else {
                        SessionDial(session: session, status: status)
                            .frame(width: 104, height: 104)
                    }
                }
                if let record, record.startedAt != nil {
                    Hairline()
                    HStack(spacing: 18) {
                        FactView(
                            label: "开始", value: record.startedAt.map(BeijingTime.clock) ?? "—", valueSize: 18)
                        FactView(label: "用时", value: durationText(record), valueSize: 18)
                    }
                }
            }
        }
    }

    private func lines(_ record: RunRecord?) -> [(text: String, color: Color)] {
        guard let record else {
            switch status {
            case .skipped: return [("已跳过", Palette.secondary)]
            case .closed: return [("已关闭", Palette.secondary)]
            default: return [(session.stage.isEmpty ? "上次的关" : session.stage, Palette.blue), (session.time, Palette.violet)]
            }
        }
        if record.status != "success" {
            return [(record.reason.isEmpty ? "未完成" : record.displayReason, Palette.red)]
        }
        guard let progress = store.progress(for: record) else {
            return [(record.stage.isEmpty ? "完成" : record.stage, Palette.orange)]
        }
        var result: [(String, Color)] = []
        if !record.stage.isEmpty {
            result.append((progress.fightsDone > 0 ? "\(record.stage) ×\(progress.fightsDone)" : record.stage, Palette.orange))
        }
        if let drop = progress.drops.first { result.append(("\(drop.name) ×\(drop.count)", Palette.violet)) }
        if let sanity = progress.sanity { result.append(("理智 \(sanity.current)/\(sanity.max)", Palette.green)) }
        return result
    }

    private func durationText(_ record: RunRecord) -> String {
        if let seconds = record.durationSeconds { return shortDuration(seconds) }
        if let start = record.startedAt, let end = record.endedAt {
            return shortDuration(Int(end.timeIntervalSince(start)))
        }
        return "—"
    }
}

private struct OverviewActivityCard: View {
    @Environment(AppStore.self) private var store
    let activity: RunChoices.Activity
    let tally: CopilotTally

    var body: some View {
        Button {
            store.openCopilotList()
        } label: {
            WCard(vertical: 13) {
                HStack {
                    VStack(alignment: .leading, spacing: 0) {
                        MoreLabel(title: activity.name).frame(height: 24)
                        Text(activity.end.map { BeijingDay.remaining(until: $0) } ?? "进行中")
                            .scaledFont(size: 30, weight: .heavy)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        HStack(spacing: 12) {
                            Text("普通 \(tally.normal.done)/\(tally.normal.total)").foregroundStyle(Palette.teal)
                            Text("EX \(tally.ex.done)/\(tally.ex.total)").foregroundStyle(Palette.violet)
                            Text("S \(tally.s.done)/\(tally.s.total)").foregroundStyle(Palette.pink)
                        }
                        .scaledFont(size: 15, weight: .semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 8)
                    ActivityRings(tally: tally).frame(width: 96, height: 96)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RecentRunsCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = Array(store.recentRecords.prefix(3))
        if !rows.isEmpty {
            WCard(vertical: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    NavigationLink(value: HistoryRoute()) {
                        MoreLabel(title: "最近").frame(height: 28)
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Hairline() }
                        NavigationLink(value: RunRoute(id: record.id)) {
                            RunRow(record: record, showsDay: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct RunRow: View {
    @Environment(AppStore.self) private var store
    let record: RunRecord
    var showsDay = false

    var body: some View {
        HStack {
            Text(timeText)
                .scaledFont(size: 16)
                .monospacedDigit()
                .fixedSize()
            Spacer(minLength: 12)
            Text(store.recentText(record))
                .scaledFont(size: 16)
                .foregroundStyle(isBad ? Palette.red : Palette.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 48)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var isBad: Bool {
        !["success", "skipped", "cancelled", "canceled"].contains(record.status)
    }

    private var timeText: String {
        guard let date = record.startedAt else { return "—" }
        return showsDay ? "\(BeijingDay.title(date)) \(BeijingTime.clock(date))" : BeijingTime.clock(date)
    }
}

// MARK: - 场次控件

struct SessionDial: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session
    let status: SessionStatus

    var body: some View {
        SevenDial(segments: segments, label: label, accessibilityText: accessibilityText)
    }

    private var progress: RunProgressFile? {
        switch status {
        case .running: store.activeRun?.progress
        case let .finished(record), let .failed(record): store.progress(for: record)
        default: nil
        }
    }

    private var segments: [SevenDial.Segment] {
        if let progress { return .daily(progress.steps) }
        if case .finished = status {
            return DailyStep.allCases.map { .init(color: $0.color, fill: 1) }
        }
        return DailyStep.allCases.map { .init(color: $0.color, fill: 0) }
    }

    private var doneCount: Int {
        progress?.steps.filter { $0.state == .done }.count ?? 0
    }

    private var label: String? {
        switch status {
        case .running:
            store.activeRun?.dailyPosition.map { "\($0)/\(DailyStep.allCases.count)" }
        case .finished, .failed:
            progress == nil ? nil : "\(doneCount)/\(DailyStep.allCases.count)"
        default:
            nil
        }
    }

    private var accessibilityText: String {
        label.map { "\(session.name) \($0)" } ?? session.name
    }
}

struct SessionControls: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session
    let status: SessionStatus
    let onChangeStage: (TodayPlan.Session) -> Void
    @State private var isBusy = false

    private var isEditable: Bool {
        status.isEditable && store.canWrite && !isBusy
    }

    var body: some View {
        switch status {
        case .closed:
            Button {
                store.selectedTab = .daily
            } label: {
                PillLabel(title: "去日常")
            }
            .buttonStyle(.plain)
        case let .failed(record), let .finished(record):
            NavigationLink(value: RunRoute(id: record.id)) {
                PillLabel(title: "查看战报")
            }
            .buttonStyle(.plain)
        case .skipped:
            if store.canRestore(session) {
                SessionRestoreButton(session: session, title: "恢复\(session.name)")
            }
        default:
            HStack(spacing: 8) {
                Button {
                    onChangeStage(session)
                } label: {
                    PillLabel(title: "换关")
                }
                .accessibilityLabel("换关，当前 \(session.stage)")
                Button {
                    run { await store.setFight(phase: session.phase, fight: !session.fight) }
                } label: {
                    PillLabel(title: "刷理智", isOn: session.fight)
                }
                .accessibilityAddTraits(session.fight ? .isSelected : [])
                Button {
                    run { await store.setSkip(phase: session.phase, skip: true) }
                } label: {
                    PillLabel(title: "跳过")
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            .opacity(isEditable ? 1 : 0.45)
        }
    }

    private func run(_ action: @escaping @MainActor () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

/// 跳过的场次只留恢复，换关和刷理智等恢复后再改。
private struct SessionRestoreButton: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session
    let title: String
    @State private var isBusy = false

    private var isEnabled: Bool { store.canWrite && !isBusy }

    var body: some View {
        Button {
            isBusy = true
            Task {
                await store.setSkip(phase: session.phase, skip: false)
                isBusy = false
            }
        } label: {
            PillLabel(title: title, isOn: true, fontSize: 17)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - 场次页（E2 待跑 / E3 运行中）

private struct SessionPage: View {
    @Environment(AppStore.self) private var store
    let session: TodayPlan.Session
    let onChangeStage: (TodayPlan.Session) -> Void

    private var status: SessionStatus { store.status(of: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if status == .running, let run = store.activeRun {
                runningContent(run)
            } else {
                plannedContent
            }
        }
    }

    private func runningContent(_ run: ActiveRun) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SevenDial(
                segments: .daily(run.progress?.steps ?? []),
                label: run.dailyPosition.map { "\($0)/\(DailyStep.allCases.count)" },
                accessibilityText: run.dailyPosition.map { "第 \($0) 步，共 \(DailyStep.allCases.count) 步" })
                .frame(width: 236, height: 236)
                .frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline) {
                Text(run.currentDailyStep?.title ?? "准备中")
                    .scaledFont(size: 30, weight: .heavy)
                    .foregroundStyle(run.currentDailyStep?.color ?? Color.primary)
                Spacer()
                if let eta = run.progress?.eta {
                    Text("约 \(BeijingTime.clock(eta))")
                        .scaledFont(size: 17, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 4)
            if let progress = run.progress {
                TimelineLanes(
                    items: LaneItem.daily(progress, showDurations: true),
                    startLabel: progress.startedAt.map(BeijingTime.clock),
                    endLabel: progress.eta.map(BeijingTime.clock),
                    labelWidth: 150, rowHeight: 26, barHeight: 13)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 12) {
                    FactView(label: "刷理智", value: fightText(progress), color: Palette.orange)
                    FactView(
                        label: "掉落", value: progress.drops.first.map { "\($0.name) ×\($0.count)" } ?? "—",
                        color: Palette.violet)
                    if let sanity = progress.sanity ?? store.sanityStatus.map({ .init(current: $0.current, max: $0.max) }) {
                        FactView(label: "理智", value: "\(sanity.current)/\(sanity.max)", color: Palette.orange)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func fightText(_ progress: RunProgressFile) -> String {
        let stage = session.stage.isEmpty ? "刷理智" : session.stage
        return progress.fightsDone > 0 ? "\(stage) ×\(progress.fightsDone)" : stage
    }

    private var plannedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SevenDial(
                segments: plannedSegments,
                label: session.time,
                accessibilityText: "\(session.name) \(session.time)，计划 \(enabledCount) 步")
                .frame(width: 264, height: 264)
                .frame(maxWidth: .infinity)
            Text(title)
                .scaledFont(size: 30, weight: .heavy)
                .padding(.horizontal, 4)
            SessionControls(session: session, status: status, onChangeStage: onChangeStage)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 18) {
                FactView(label: "定关", value: sourceText, color: Palette.blue)
                FactView(label: "目标", value: targetText, color: Palette.violet)
                if let sanity = store.sanityStatus {
                    FactView(
                        label: "理智", value: "\(sanity.current)/\(sanity.max)",
                        note: sanity.measuredAt.map(BeijingTime.clock), color: Palette.orange)
                }
                FactView(label: "环节", value: "\(enabledCount) 项", color: Palette.green)
            }
            .padding(.horizontal, 4)
        }
    }

    private var title: String {
        switch status {
        case .skipped: "\(session.name)已跳过"
        case .closed: "\(session.name)已关闭"
        case .failed: "\(session.name)没打完"
        default: "\(session.name) \(session.stage.isEmpty ? "上次的关" : session.stage)"
        }
    }

    private var sourceText: String {
        switch session.stageSource {
        case "auto": "自动"
        case "discord": "手动"
        default: "默认"
        }
    }

    private var targetText: String {
        guard let drop = session.drops.first else { return "—" }
        return "\(drop.name) ×\(drop.count)"
    }

    /// 启动和剿灭不在计划开关里，算默认要做。
    private var enabledCount: Int {
        2 + ["fight", "infrast", "recruit", "mall", "award"].filter { session.tasks[$0] ?? true }.count
    }

    private var plannedSegments: [SevenDial.Segment] {
        let keys: [DailyStep: String] = [
            .fight: "fight", .infrast: "infrast", .recruit: "recruit", .mall: "mall", .award: "award",
        ]
        return DailyStep.allCases.map { step in
            let enabled = keys[step].map { session.tasks[$0] ?? true } ?? true
            return .init(color: step.color, fill: enabled ? 1 : 0, style: .outlined)
        }
    }
}

// MARK: - 理智（E25）

private struct SanityPage: View {
    @Environment(AppStore.self) private var store

    /// 1 点 / 6 分。
    private static let secondsPerPoint: TimeInterval = 360

    var body: some View {
        if let sanity = store.sanityStatus {
            let next = store.nextPlannedSession
            let projected = projected(sanity, at: next?.date)
            VStack(alignment: .leading, spacing: 16) {
                SanityGauge(current: sanity.current, projected: projected ?? sanity.estimatedNow, max: sanity.max)
                    .frame(width: 236, height: 236)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(accessibilityText(sanity, projected: projected, next: next?.session))
                HStack(alignment: .top, spacing: 18) {
                    FactView(
                        label: "实测", value: "\(sanity.current)",
                        note: sanity.measuredAt.map(BeijingTime.clock), color: Palette.orange)
                    if let projected, let next {
                        FactView(
                            label: "预计 \(next.session.time)", value: "≈\(projected)",
                            note: "+\(projected - sanity.current)", color: Palette.orange.opacity(0.75))
                    } else if let estimated = sanity.estimatedNow {
                        FactView(
                            label: "现在", value: "≈\(estimated)", note: "+\(estimated - sanity.current)",
                            color: Palette.orange.opacity(0.75))
                    }
                }
                .padding(.horizontal, 4)
                WCard(vertical: 0) {
                    VStack(spacing: 0) {
                        row("恢复速度", "1 点 / 6 分")
                        if let next {
                            Hairline()
                            row("下一场", "\(next.session.name) \(next.session.time)")
                        }
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Palette.secondary).monospacedDigit()
        }
        .scaledFont(size: 16)
        .frame(minHeight: 48)
    }

    private func projected(_ sanity: SanityStatus, at date: Date?) -> Int? {
        guard let date, let measured = sanity.measuredAt, date > measured else { return nil }
        let gained = Int(date.timeIntervalSince(measured) / Self.secondsPerPoint)
        return min(sanity.current + gained, sanity.max)
    }

    private func accessibilityText(_ sanity: SanityStatus, projected: Int?, next: TodayPlan.Session?) -> String {
        var text = "实测 \(sanity.current)"
        if let projected, let next { text += "，预计 \(next.time) 约 \(projected)" }
        return text + "，上限 \(sanity.max)"
    }
}

/// 实测实心，估算虚线。
private struct SanityGauge: View {
    let current: Int
    let projected: Int?
    let max: Int

    private func fraction(_ value: Int) -> Double {
        guard max > 0 else { return 0 }
        return min(Double(value) / Double(max), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.ghost, lineWidth: 26)
            if let projected {
                Circle()
                    .trim(from: 0, to: fraction(projected))
                    .stroke(
                        Palette.orange.opacity(0.65),
                        style: StrokeStyle(lineWidth: 26, lineCap: .butt, dash: [5, 5]))
                    .rotationEffect(.degrees(-90))
            }
            Circle()
                .trim(from: 0, to: fraction(current))
                .stroke(Palette.orange, style: StrokeStyle(lineWidth: 26, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(current)")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("/\(max)")
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            }
        }
        .padding(13)
    }
}

// MARK: - 游戏资源提示条（E23）

struct ResourceStrip: View {
    @Environment(AppStore.self) private var store

    private enum Kind {
        case blocked, stale, running
    }

    private var kind: Kind? {
        guard let upstream = store.snapshot?.upstream else { return nil }
        if upstream.running || store.isUpdatingResources || upstream.verdict == "running" { return .running }
        switch upstream.verdict {
        case "blocked": return .blocked
        case "stale": return .stale
        default: return nil
        }
    }

    private var updateBlocked: Bool {
        !(store.snapshot?.upstream?.updateBlocked ?? "").isEmpty
    }

    var body: some View {
        if let kind {
            HStack(spacing: 10) {
                if kind == .running {
                    ProgressView().frame(width: 22)
                } else {
                    Image(systemName: kind == .blocked ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(kind == .blocked ? Palette.red : Palette.amber)
                        .frame(width: 22)
                }
                Text(title(kind))
                    .scaledFont(size: 15, weight: .semibold)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if kind != .running {
                    Button("现在更新") {
                        Task { await store.updateResources() }
                    }
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(Palette.blue)
                    .frame(minHeight: 44)
                    .disabled(!store.canWrite || updateBlocked)
                    .opacity(store.canWrite && !updateBlocked ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func title(_ kind: Kind) -> String {
        switch kind {
        case .blocked: "游戏资源必须更新"
        case .stale: "游戏资源有更新"
        case .running: "正在更新资源"
        }
    }
}
