//
//  Components.swift
//  Wado's MAA (iOS)
//
//  E 七段的共用小件：卡片、胶囊按钮、数据格、三环、时间线和步进器。
//

import SwiftUI
import WadosMAAShared

struct WCard<Content: View>: View {
    private let horizontal: CGFloat
    private let vertical: CGFloat
    private let content: Content

    init(horizontal: CGFloat = 18, vertical: CGFloat = 15, @ViewBuilder content: () -> Content) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: .rect(cornerRadius: 24, style: .continuous))
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Palette.hairline)
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

/// 「晚场 ›」：可点的小标题。
struct MoreLabel: View {
    let title: String
    var color: Color = Palette.secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "chevron.right")
                .scaledFont(size: 11, weight: .bold)
                .opacity(0.7)
        }
        .scaledFont(size: 15, weight: .semibold)
        .foregroundStyle(color)
        .lineLimit(1)
    }
}

struct PillLabel: View {
    let title: String
    var symbol: String?
    var isOn = false
    var fontSize: CGFloat = 15

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).scaledFont(size: 13, weight: .semibold)
            }
            Text(title).lineLimit(1).minimumScaleFactor(0.6)
        }
        .scaledFont(size: fontSize, weight: .semibold)
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(isOn ? Palette.accent : Palette.ghost, in: .capsule)
        .contentShape(.capsule)
    }
}

struct FactView: View {
    let label: String
    let value: String
    var note: String?
    var color: Color = Palette.secondary
    var valueSize: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .scaledFont(size: 14, weight: .semibold)
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .scaledFont(size: valueSize, weight: .bold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let note {
                Text(note)
                    .scaledFont(size: 14)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 普通 / EX / S 三环。
struct ActivityRings: View {
    let tally: CopilotTally

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let line = side * 0.1
            ZStack {
                ring(tally.normal, color: Palette.teal, diameter: side * 100 / 120, line: line)
                ring(tally.ex, color: Palette.violet, diameter: side * 70 / 120, line: line)
                ring(tally.s, color: Palette.pink, diameter: side * 40 / 120, line: line)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(
            "普通 \(tally.normal.done)/\(tally.normal.total)，EX \(tally.ex.done)/\(tally.ex.total)，S \(tally.s.done)/\(tally.s.total)"
        )
    }

    private func ring(_ group: CopilotTally.Group, color: Color, diameter: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: line)
            Circle()
                .trim(from: 0, to: group.fraction)
                .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

/// 时间线的一行。
struct LaneItem: Identifiable {
    let id: String
    let title: String
    var symbol: String?
    let color: Color
    let start: Double
    let width: Double
    var duration: String?
    var isPending = false
    var isFailed = false
}

/// 失败条和七段图同一个形状：灰槽里一个感叹号，不靠颜色也能认出来。
private struct FailedLaneBar: View {
    let color: Color
    let height: CGFloat

    var body: some View {
        let line = height * 0.62
        HStack(spacing: height * 0.3) {
            Capsule().fill(color).frame(height: line)
            Circle().fill(color).frame(width: line, height: line)
        }
        .padding(.horizontal, (height - line) / 2)
        .frame(height: height)
        .background(Palette.ghost, in: .rect(cornerRadius: 4, style: .continuous))
    }
}

struct TimelineLanes: View {
    let items: [LaneItem]
    let startLabel: String?
    let endLabel: String?
    var labelWidth: CGFloat = 92
    var rowHeight: CGFloat = 28
    var barHeight: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        if let symbol = item.symbol {
                            Image(systemName: symbol)
                                .scaledFont(size: 13, weight: .semibold)
                                .frame(width: 18)
                        }
                        Text(item.title).lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                        if let duration = item.duration {
                            Text(duration)
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .scaledFont(size: 14, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(item.isPending ? Palette.secondary : item.color)
                    .frame(width: labelWidth, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .bottomLeading) {
                            Rectangle().fill(Palette.hairline).frame(height: 0.5)
                            if item.isFailed {
                                let width = min(max(proxy.size.width * item.width, barHeight * 2), proxy.size.width)
                                FailedLaneBar(color: item.color, height: barHeight)
                                    .frame(width: width)
                                    .offset(x: min(proxy.size.width * item.start, proxy.size.width - width))
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(item.isPending ? Palette.ghost : item.color)
                                    .frame(width: max(proxy.size.width * item.width, 4), height: barHeight)
                                    .offset(x: proxy.size.width * min(item.start, 0.98))
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(height: barHeight)
                }
                .frame(height: rowHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    [item.title, item.isFailed ? "失败" : nil, item.duration].compactMap { $0 }.joined(separator: " "))
            }
            if startLabel != nil || endLabel != nil {
                HStack {
                    Text(startLabel ?? "")
                    Spacer()
                    Text(endLabel ?? "")
                }
                .scaledFont(size: 13, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(Palette.secondary)
                .padding(.leading, labelWidth + 8)
                .padding(.top, 4)
            }
        }
    }
}

extension LaneItem {
    /// 日常七步：跑过的按真实时间排，没跑的平分剩下的空间。
    static func daily(_ progress: RunProgressFile, now: Date = Date(), showDurations: Bool) -> [LaneItem] {
        let start = progress.startedAt ?? progress.steps.compactMap(\.startedAt).min() ?? now
        let lastFinished = progress.steps.compactMap(\.finishedAt).max()
        let end = max(progress.eta ?? lastFinished ?? now, lastFinished ?? now, start.addingTimeInterval(60))
        let total = end.timeIntervalSince(start)
        var cursor = 0.0
        var result: [LaneItem] = []
        let steps = DailyStep.allCases
        for (index, step) in steps.enumerated() {
            let item = progress.steps.first { $0.key == step.rawValue }
            let state = item?.state ?? .pending
            if let began = item?.startedAt, state != .pending, state != .skipped {
                let finished = item?.finishedAt ?? (state == .running ? now : began)
                let x = max(0, began.timeIntervalSince(start) / total)
                let width = max(finished.timeIntervalSince(began) / total, 0.02)
                cursor = min(x + width, 1)
                result.append(
                    LaneItem(
                        id: step.rawValue, title: step.title, symbol: showDurations ? step.symbol : nil,
                        color: state == .failed ? Palette.red : step.color, start: x, width: min(width, 1 - x),
                        duration: showDurations ? shortDuration(Int(finished.timeIntervalSince(began))) : nil,
                        isFailed: state == .failed))
            } else {
                let remaining = Double(steps.count - index)
                let width = max((1 - cursor) / remaining, 0.02)
                result.append(
                    LaneItem(
                        id: step.rawValue, title: step.title, symbol: showDurations ? step.symbol : nil,
                        color: step.color, start: cursor, width: width, isPending: true))
                cursor = min(cursor + width, 1)
            }
        }
        return result
    }

    /// 抄作业逐关：有起止时间按真实比例，缺时间就等分。
    static func copilot(_ results: [RunReport.StageResult]) -> (items: [LaneItem], start: Date?, end: Date?) {
        let starts = results.compactMap(\.startedAt)
        let ends = results.compactMap(\.finishedAt)
        guard let start = starts.min(), let end = ends.max(), end > start, starts.count == results.count,
            ends.count == results.count
        else {
            let width = results.isEmpty ? 0 : 1 / Double(results.count)
            let items = results.enumerated().map { index, row in
                LaneItem(
                    id: "\(row.id)", title: row.stage, color: stageColor(row.stage, outcome: row.outcome),
                    start: Double(index) * width, width: width, isFailed: isFailed(row.outcome))
            }
            return (items, starts.min(), ends.max())
        }
        let total = end.timeIntervalSince(start)
        let items = results.map { row in
            let began = row.startedAt ?? start
            let finished = row.finishedAt ?? began
            return LaneItem(
                id: "\(row.id)", title: row.stage, color: stageColor(row.stage, outcome: row.outcome),
                start: began.timeIntervalSince(start) / total,
                width: max(finished.timeIntervalSince(began) / total, 0.02),
                isFailed: isFailed(row.outcome))
        }
        return (items, start, end)
    }

    private static func isFailed(_ outcome: String) -> Bool {
        outcome == "failed" || outcome == "unknown"
    }

    private static func stageColor(_ stage: String, outcome: String) -> Color {
        if isFailed(outcome) { return Palette.red }
        let upper = stage.uppercased()
        if upper.contains("-EX-") { return Palette.violet }
        if upper.contains("-S-") { return Palette.pink }
        return Palette.teal
    }
}

/// − / + 胶囊。
struct StepperPill: View {
    let canDecrease: Bool
    let canIncrease: Bool
    let decrease: () -> Void
    let increase: () -> Void
    var title = ""

    var body: some View {
        HStack(spacing: 0) {
            Button(action: decrease) {
                Image(systemName: "minus").frame(width: 48, height: 40).contentShape(.rect)
            }
            .disabled(!canDecrease)
            .accessibilityLabel("减少\(title)")
            Rectangle().fill(Palette.hairline).frame(width: 0.5, height: 20)
            Button(action: increase) {
                Image(systemName: "plus").frame(width: 48, height: 40).contentShape(.rect)
            }
            .disabled(!canIncrease)
            .accessibilityLabel("增加\(title)")
        }
        .scaledFont(size: 16, weight: .semibold)
        .buttonStyle(.plain)
        .background(Palette.ghost, in: .capsule)
    }
}

/// 一行「名字 + 数值 + 步进器」，配置项共用。
struct ConfigStepperCard: View {
    @Environment(AppStore.self) private var store
    let key: String
    let title: String
    let unit: String
    let color: Color
    let fallback: Int
    let range: ClosedRange<Int>
    var step = 1
    var zeroText: String?
    var undo = true

    private var value: Int { store.configInt(key, fallback: fallback) }
    private var bounds: ClosedRange<Int> { store.configRange(key, fallback: range) }

    var body: some View {
        WCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .scaledFont(size: 15, weight: .semibold)
                    .foregroundStyle(color)
                HStack(alignment: .center) {
                    valueText
                    Spacer()
                    StepperPill(
                        canDecrease: store.canWrite && value > bounds.lowerBound,
                        canIncrease: store.canWrite && value < bounds.upperBound,
                        decrease: { change(max(value - step, bounds.lowerBound)) },
                        increase: { change(min(value + step, bounds.upperBound)) },
                        title: title)
                }
            }
        }
    }

    @ViewBuilder private var valueText: some View {
        if value == 0, let zeroText {
            Text(zeroText).scaledFont(size: 30, weight: .heavy)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)").scaledFont(size: 30, weight: .heavy).monospacedDigit()
                Text(unit).scaledFont(size: 15, weight: .semibold).foregroundStyle(Palette.secondary)
            }
        }
    }

    private func change(_ next: Int) {
        let text = next == 0 ? (zeroText ?? "0\(unit)") : "\(next) \(unit)"
        store.changeConfig(
            key, to: .number(Double(next)), toast: undo ? "\(title)改为 \(text)" : nil, debounce: .milliseconds(450))
    }
}
