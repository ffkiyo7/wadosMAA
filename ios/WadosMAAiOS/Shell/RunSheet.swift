//
//  RunSheet.swift
//  Wado's MAA (iOS)
//
//  实时进度（E12 日常 / E13 抄作业）。半屏看概况，拉满看逐步时间线。
//

import SwiftUI
import WadosMAAShared

struct RunSheet: View {
    @Environment(AppStore.self) private var store
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        @Bindable var store = store
        Group {
            if let run = store.activeRun {
                content(run)
            } else {
                ContentUnavailableView("这一场已结束", systemImage: "checkmark.circle")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .alert(
            "运行已变化",
            isPresented: Binding(
                get: { store.runChangedNotice != nil },
                set: { if !$0 { store.runChangedNotice = nil } }),
            presenting: store.runChangedNotice
        ) { _ in
            if store.activeRun != nil {
                Button("查看当前") {}
                Button("取消", role: .cancel) {
                    store.isRunSheetPresented = false
                }
            } else {
                Button("好", role: .cancel) {
                    store.isRunSheetPresented = false
                }
            }
        } message: { notice in
            Text(notice.message)
        }
        .onChange(of: store.activeRun == nil) { _, ended in
            if ended, store.runChangedNotice == nil {
                store.isRunSheetPresented = false
            }
        }
    }

    private func content(_ run: ActiveRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch run.kind {
                case .daily: DailyRunSummary(run: run, expanded: detent == .large)
                case .copilot: CopilotRunSummary(run: run, expanded: detent == .large)
                case .other: OtherRunSummary(run: run)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if run.canStop {
                stopButton
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
    }

    private var stopButton: some View {
        @Bindable var store = store
        return Button {
            store.requestStop()
        } label: {
            Group {
                if store.isStopping {
                    ProgressView().tint(.white)
                } else {
                    Text("停止").font(.headline)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.stop, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!store.canWrite || store.isStopping)
        .opacity(store.canWrite ? 1 : 0.4)
        .alert(
            store.activeRun?.stopTitle ?? "",
            isPresented: $store.isStopConfirmationPresented
        ) {
            Button("停止", role: .destructive) {
                Task { await store.confirmStop() }
            }
            Button("继续运行", role: .cancel) {}
        } message: {
            if let message = store.activeRun?.stopMessage, !message.isEmpty {
                Text(message)
            }
        }
        // 这一场不能再停时按钮会消失，别把待确认状态留给下一场。
        .onDisappear { store.isStopConfirmationPresented = false }
    }
}

// MARK: - 日常

private struct DailyRunSummary: View {
    let run: ActiveRun
    let expanded: Bool

    private var progress: RunProgressFile? { run.progress }

    var body: some View {
        HStack(spacing: 18) {
            SevenDial(
                segments: .daily(progress?.steps ?? []),
                label: run.dailyPosition.map { "\($0)/\(DailyStep.allCases.count)" })
                .frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 4) {
                Text(run.statusText)
                    .scaledFont(size: 30, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let eta = progress?.eta {
                    Text("约 \(BeijingTime.clock(eta))")
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                }
            }
        }
        FactGrid(facts: facts)
        if expanded {
            VStack(spacing: 0) {
                ForEach(DailyStep.allCases) { step in
                    DailyTimelineRow(step: step, progress: progress?.steps.first { $0.key == step.rawValue })
                }
            }
            .padding(.vertical, 6)
            .background(Palette.ghost, in: .rect(cornerRadius: 24, style: .continuous))
        }
    }

    private var facts: [Fact] {
        guard let progress else { return [] }
        var result: [Fact] = []
        if let estimate = progress.fightEstimate {
            result.append(Fact(label: "刷理智", value: "\(progress.fightsDone)/\(estimate)"))
        } else if progress.fightsDone > 0 {
            result.append(Fact(label: "刷理智", value: "\(progress.fightsDone) 次"))
        }
        if let drop = progress.drops.first {
            result.append(Fact(label: "掉落", value: "\(drop.name) ×\(drop.count)"))
        }
        if let sanity = progress.sanity {
            result.append(Fact(label: "理智", value: "\(sanity.current)/\(sanity.max)"))
        }
        return result
    }
}

private struct DailyTimelineRow: View {
    let step: DailyStep
    let progress: RunProgressStep?

    private var state: RunProgressStep.State { progress?.state ?? .pending }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(state == .pending || state == .skipped ? Palette.secondary : step.color)
                .frame(width: 28)
            Text(step.title)
                .font(.body.weight(state == .running ? .semibold : .regular))
                .foregroundStyle(state == .pending || state == .skipped ? Palette.secondary : Color.primary)
            Spacer()
            Text(trailing)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(state == .failed ? Palette.red : Palette.secondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var trailing: String {
        switch state {
        case .done: progress?.finishedAt.map(BeijingTime.clock) ?? "完成"
        case .running: "进行中"
        case .failed: "没完成"
        case .skipped: "跳过"
        case .pending: ""
        }
    }
}

// MARK: - 抄作业

private struct CopilotRunSummary: View {
    let run: ActiveRun
    let expanded: Bool

    private var copilot: RunProgressCopilot? { run.progress?.copilot }

    private var position: Int {
        guard let copilot, copilot.total > 0 else { return 0 }
        return min(copilot.done + 1, copilot.total)
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                CopilotRing(done: copilot?.done ?? 0, total: copilot?.total ?? 0, lineWidth: 12, isRunning: true)
                Text("\(position)/\(copilot?.total ?? 0)")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 112, height: 112)
            Text(run.copilotTitle)
                .scaledFont(size: 30, weight: .heavy)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        FactGrid(facts: facts)
        if expanded, let steps = run.progress?.steps, !steps.isEmpty {
            VStack(spacing: 0) {
                ForEach(steps) { step in
                    HStack {
                        Text(step.label)
                            .font(.body.weight(step.state == .running ? .semibold : .regular))
                        Spacer()
                        Text(word(step.state))
                            .font(.subheadline)
                            .foregroundStyle(step.state == .failed ? Palette.red : Palette.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
            }
            .padding(.vertical, 6)
            .background(Palette.ghost, in: .rect(cornerRadius: 24, style: .continuous))
        }
    }

    private var facts: [Fact] {
        var result: [Fact] = []
        if let mode = copilot?.currentMode {
            result.append(Fact(label: "模式", value: mode == "raid" ? "突袭" : "普通"))
        }
        if let seconds = copilot?.elapsedSeconds {
            result.append(Fact(label: "已用时", value: "\(seconds / 60) 分钟"))
        }
        return result
    }

    private func word(_ state: RunProgressStep.State) -> String {
        switch state {
        case .done: "已通关"
        case .running: "进行中"
        case .pending: "排队"
        case .failed: "没完成"
        case .skipped: "跳过"
        }
    }
}

private struct OtherRunSummary: View {
    let run: ActiveRun

    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(run.statusText)
                .scaledFont(size: 30, weight: .heavy)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - 数据格

private struct Fact: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct FactGrid: View {
    let facts: [Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 12) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.label)
                        .scaledFont(size: 14)
                        .foregroundStyle(Palette.secondary)
                    Text(fact.value)
                        .scaledFont(size: 21, weight: .semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
