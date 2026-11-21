//
//  RunStatus.swift
//  Wado's MAA
//
//  本场进度的几块小视图：步骤条（✅ 启动游戏  ⏳ 刷理智 3/≈7  ○ 基建 …）、
//  日志检查器顶部的「本场」卡片。数据都来自 `RunProgress`（maa-remote 的 progress.json；旧版退回日志）。
//

import AppKit
import SwiftUI
import WadosMAAShared

/// 步骤条：计划里要做的事一格一格排开，放不下就换行。
struct RunStepsView: View {
    let progress: RunProgress

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 6) {
            ForEach(progress.steps) { step in
                HStack(spacing: 4) {
                    Image(systemName: icon(step.state))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(color(step.state))
                    Text(text(step))
                        .foregroundStyle(step.state == .pending || step.state == .skipped ? WM.f3 : .primary)
                        .fontWeight(step.state == .running ? .semibold : .regular)
                        .monospacedDigit()
                        .strikethrough(step.state == .skipped, color: WM.f3)
                }
                .font(.system(size: 12))
                .fixedSize()
            }
        }
    }

    private func text(_ step: RunProgress.Step) -> String {
        guard step.key == "Fight", let fights = progress.fightText else { return step.label }
        return "\(step.label) \(fights)"
    }

    private func icon(_ state: RunProgress.Step.State) -> String {
        switch state {
        case .pending: "circle"
        case .running: "hourglass"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func color(_ state: RunProgress.Step.State) -> Color {
        switch state {
        case .pending, .skipped: WM.f3
        case .running: WM.game
        case .done: WM.ok
        case .failed: WM.danger
        }
    }
}

/// 一场的详情：哪一场、几点开始、步骤条和整体进度。状态条的弹出框和日志检查器的「本场」卡片共用。
struct RunSessionSummary: View {
    let progress: RunProgress
    /// 没有步骤条时（抄作业、清点仓库……）显示的「现在在做什么」。
    var doing: String?
    /// 步骤条下面列最近几条重试 / 重启之类的说明（「本场」卡片用）。
    var noteLimit = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(progress.title).fontWeight(.semibold).lineLimit(1)
                if let outcome = progress.outcome {
                    Text(LastRunText.statusWord(outcome))
                        .foregroundStyle(outcome == "success" ? WM.ok : outcome == "skipped" ? WM.f2 : WM.danger)
                }
                Spacer(minLength: 0)
                if let eta = progress.eta, progress.outcome == nil {
                    Text("约 \(RunLock.beijingClock(eta)) 结束").foregroundStyle(WM.f3).monospacedDigit()
                } else if let started = progress.startedAt {
                    Text("\(RunLock.beijingClock(started)) 开始").foregroundStyle(WM.f3).monospacedDigit()
                }
            }
            if !progress.steps.isEmpty {
                RunStepsView(progress: progress)
            } else if let doing {
                Text(doing).foregroundStyle(WM.f2)
            }
            if noteLimit > 0, !progress.notes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(progress.notes.suffix(noteLimit)) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            if let date = note.date {
                                Text(RunLock.beijingClock(date)).foregroundStyle(WM.f3).monospacedDigit()
                            }
                            Text(note.text).foregroundStyle(WM.game)
                        }
                    }
                }
                .font(.system(size: 11.5))
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(progress.outcome == nil || progress.outcome == "success" ? WM.game : WM.danger)
            }
        }
    }
}

/// 日志检查器顶部的「本场」卡片：正在跑或刚跑完的那一场。
struct RunSessionCard: View {
    @Environment(RemoteStore.self) private var store

    var body: some View {
        let progress = store.progress
        VStack(alignment: .leading, spacing: 10) {
            RunSessionSummary(progress: progress, doing: progress.outcome == nil ? progress.current?.label : nil, noteLimit: 3)
            if let log = progress.logURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([log])
                } label: {
                    Label("在 Finder 中显示本场日志", systemImage: "folder")
                }
                .buttonStyle(.plain)
                .foregroundStyle(WM.f2)
                .font(.system(size: 11.5))
                .disabled(!FileManager.default.fileExists(atPath: log.path))
            }
        }
        .font(.system(size: 12.5))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WM.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(WM.line, lineWidth: 0.5))
    }
}

/// 从左到右排，一行放不下就换行。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// 「停止」：早场 / 晚场 / 手动日常、抄作业在跑时都显示，点了先确认再 `run cancel`。
/// 状态条、手动日常卡、今天的日常卡用的是同一个；锁空着或不是能停的那种时不占位置。
struct StopRunButton: View {
    @Environment(RemoteStore.self) private var store
    @State private var confirming: LockHolder?

    static func title(_ run: LockHolder?) -> String { "停止\(run?.name ?? "")？" }
    static let message = "已经打完的不受影响，游戏会被关掉。"

    var body: some View {
        if let run = store.cancelableRun {
            Button {
                confirming = run
            } label: {
                if store.stopping {
                    ProgressView().controlSize(.mini)
                } else {
                    Label("停止", systemImage: "stop.fill")
                }
            }
            .buttonStyle(WMButtonStyle(kind: .danger))
            .disabled(store.stopping || store.readOnly)
            .help("停下正在跑的\(run.name)")
            .alert(
                Self.title(confirming),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
            ) {
                Button("停止", role: .destructive) { Task { await store.stopRun() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text(Self.message)
            }
        }
    }
}
