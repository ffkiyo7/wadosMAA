//
//  TodayHeat.swift
//  Wado's MAA
//
//  首页最下面的近况热力格：最近 5 周排成一行，每周 7 格（周一起头），每天一格。
//  只有两种颜色：有报错（早场或晚场任一没完成，红、缺一个角）、全成功（跳过也算，绿）。
//  没有记录、本周还没到的日子是淡空槽；今天加一圈描边，还没跑完时是空槽加描边。
//  数据来自 `runs/index.jsonl` 和正在跑的 `last_run.json`；点一格弹出那天两场的简况。
//

import SwiftUI

struct HeatStrip: View {
    let now: Date

    static let weekCount = 5

    /// 5 组，每组周一到周日。
    private var weeks: [[Date]] {
        let calendar = Beijing.calendar
        let today = calendar.startOfDay(for: now)
        // 周一 = 0
        let offset = (calendar.component(.weekday, from: today) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -offset - 7 * (Self.weekCount - 1), to: today) else {
            return []
        }
        return (0..<Self.weekCount).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: monday) }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 4) {
                    ForEach(week, id: \.self) { day in
                        HeatCell(day: day, now: now)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .wmCard(radius: 16)
    }
}

/// 一天一格。有记录的能点开看那天两场。
private struct HeatCell: View {
    let day: Date
    let now: Date

    @Environment(RemoteStore.self) private var store
    @State private var showing = false

    private enum Mark { case ok, failed, pending, empty }

    private static let phases = [("am", "早场"), ("pm", "晚场")]

    var body: some View {
        let runs = Self.phases.compactMap { phase, name in
            SessionOutcome.of(phase, on: day, store: store).map { (phase: phase, name: name, outcome: $0) }
        }
        let mark = mark(runs.map(\.outcome))
        let today = Beijing.calendar.isDate(day, inSameDayAs: now)
        let caption = Beijing.todayCaption(day)
        Group {
            if runs.isEmpty {
                cell(mark, today: today).help(caption)
            } else {
                Button {
                    showing.toggle()
                } label: {
                    cell(mark, today: today)
                }
                .buttonStyle(.plain)
                .help(caption)
                .popover(isPresented: $showing, arrowEdge: .bottom) {
                    DayGlance(caption: caption, runs: runs.map { ($0.name, $0.outcome) })
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
    }

    /// 有一场没完成就是红；今天还有场次没到或正在跑、又还没出错，算没跑完；其余有记录的是绿。
    private func mark(_ outcomes: [SessionOutcome]) -> Mark {
        if outcomes.contains(where: { !$0.ongoing && !Self.fine($0.status) }) { return .failed }
        if Beijing.calendar.isDate(day, inSameDayAs: now), pendingToday(outcomes) { return .pending }
        return outcomes.isEmpty ? .empty : .ok
    }

    /// 跳过、取消都不算报错。
    private static func fine(_ status: String) -> Bool {
        ["success", "skipped", "canceled", "cancelled"].contains(status)
    }

    private func pendingToday(_ outcomes: [SessionOutcome]) -> Bool {
        if outcomes.contains(where: \.ongoing) { return true }
        return Self.phases.contains { phase, _ in
            guard let session = store.schedule?.sessions[phase], session.enabled,
                let time = Beijing.today(at: session.time, now: now), time > now
            else { return false }
            return SessionOutcome.of(phase, on: day, store: store) == nil
        }
    }

    private func cell(_ mark: Mark, today: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Group {
            switch mark {
            case .ok: shape.fill(WM.ok)
            // 缺右上角：红绿亮度相近，色弱也能靠形状分开。
            case .failed: shape.fill(WM.danger).mask(NotchedCorner(cut: 7))
            case .pending, .empty: shape.fill(Color.white.opacity(0.06))
            }
        }
        .overlay {
            if showing || today {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(showing ? Color.white : Color(hex: 0xf2f1f8, opacity: 0.85), lineWidth: showing ? 2 : 1.5)
                    .padding(-2.5)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 右上角切掉一个三角的矩形，做遮罩用。
private struct NotchedCorner: Shape {
    let cut: CGFloat

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// 点开一格看到的那天：日期，然后早场、晚场各一块（时间、状态、关卡和原因或把数、掉落）。
private struct DayGlance: View {
    let caption: String
    let runs: [(name: String, outcome: SessionOutcome)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(caption).font(.system(size: 15, weight: .semibold)).monospacedDigit()
            ForEach(runs, id: \.name) { run in
                VStack(alignment: .leading, spacing: 7) {
                    Divider().padding(.bottom, 4)
                    block(run.name, run.outcome)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340, alignment: .leading)
        // 气泡压在背景图上：用实色底，后面的颜色不透上来。
        .background(WM.panel)
    }

    @ViewBuilder private func block(_ name: String, _ outcome: SessionOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.system(size: 14, weight: .semibold))
            Text(outcome.ongoing ? "\(RunLock.beijingClock(outcome.started)) 开始" : outcome.span)
                .font(.system(size: 13)).foregroundStyle(WM.f2).monospacedDigit()
            Spacer(minLength: 0)
            Text(LastRunText.statusWord(outcome.status)).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor(outcome))
        }
        let note = note(outcome)
        if !outcome.stage.isEmpty || !note.isEmpty {
            HStack(spacing: 7) {
                if !outcome.stage.isEmpty {
                    Swatch(code: outcome.stage, size: 16, radius: 4)
                    Text(outcome.stage).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                if !note.isEmpty { Text(note).font(.system(size: 13)) }
            }
        }
        if let drops = outcome.fight?.drops, !drops.isEmpty {
            DropText(drops: drops)
        }
    }

    /// 没成功写原因；成功写刷了几把。
    private func note(_ outcome: SessionOutcome) -> String {
        if !outcome.reason.isEmpty, outcome.reason != RunHistory.skipText["plan"] { return outcome.reason }
        if outcome.status == "success", let done = outcome.fight?.done, done > 0 { return "刷了 \(done) 把" }
        return ""
    }

    private func statusColor(_ outcome: SessionOutcome) -> Color {
        switch outcome.status {
        case "success": WM.ok
        case _ where outcome.ongoing: Color.primary
        case "skipped", "canceled", "cancelled": WM.f2
        default: Color(hex: 0xff9a8c)
        }
    }
}
