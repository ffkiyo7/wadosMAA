//
//  TodayWeek.swift
//  Wado's MAA
//
//  首页最下面的「近 7 天」：整行宽的矮条，7 列，每列是星期 + 上下两个点（早场、晚场）。
//  状态靠形状区分：完成实心圆、没完成菱形、跳过横线、还没到虚线圈、进行中粗环。
//  数据来自 `runs/index.jsonl`（只看 am / pm）和正在跑的 `last_run.json`；点一个点弹出那一场的简况。
//

import SwiftUI

struct WeekStrip: View {
    let now: Date

    @Environment(RemoteStore.self) private var store

    private var days: [Date] {
        let calendar = Beijing.calendar
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Text("近 7 天").font(.system(size: 14, weight: .semibold)).frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("早").frame(height: 14)
                Text("晚").frame(height: 14)
            }
            .font(.system(size: 12))
            .foregroundStyle(WM.f2)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    column(day)
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .frame(height: 56)
        .wmCard(radius: 16)
    }

    private func column(_ day: Date) -> some View {
        let today = Beijing.calendar.isDate(day, inSameDayAs: now)
        return HStack(spacing: 9) {
            Text(today ? "今天" : Self.weekday(day))
                .font(.system(size: 12, weight: today ? .semibold : .regular))
                .foregroundStyle(today ? Color.primary : Color(hex: 0xebebf5, opacity: 0.66))
            VStack(spacing: 2) {
                WeekDot(phase: "am", day: day, now: now)
                WeekDot(phase: "pm", day: day, now: now)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .background(today ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// 「周三」
    static func weekday(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[(Beijing.calendar.component(.weekday, from: date) - 1) % 7]
    }
}

/// 一个点：那一天的早场或晚场。跑过（或在跑）的能点开看简况。
private struct WeekDot: View {
    let phase: String
    let day: Date
    let now: Date

    @Environment(RemoteStore.self) private var store
    @Environment(\.wmAccent) private var accent
    @State private var showing = false

    private enum Mark { case done, failed, skipped, future, running, none }

    private var name: String { phase == "am" ? "早场" : "晚场" }

    var body: some View {
        let outcome = SessionOutcome.of(phase, on: day, store: store)
        let mark = mark(outcome)
        if let outcome {
            Button {
                showing.toggle()
            } label: {
                shape(mark)
            }
            .buttonStyle(.plain)
            .help("\(name) \(LastRunText.statusWord(outcome.status))")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                RunGlance(phase: phase, outcome: outcome, statusColor: color(mark))
            }
        } else {
            shape(mark).help(mark == .future ? "\(name) 还没到" : "\(name) 没有记录")
        }
    }

    private func mark(_ outcome: SessionOutcome?) -> Mark {
        guard let outcome else {
            let calendar = Beijing.calendar
            if calendar.isDate(day, inSameDayAs: now),
                let session = store.schedule?.sessions[phase], session.enabled,
                let date = Beijing.today(at: session.time, now: now), date > now
            {
                return .future
            }
            return .none
        }
        switch outcome.status {
        case "success": return .done
        case "skipped", "canceled", "cancelled": return .skipped
        case _ where outcome.ongoing: return .running
        default: return .failed
        }
    }

    private func color(_ mark: Mark) -> Color {
        switch mark {
        case .done: WM.ok
        case .failed: Color(hex: 0xff9a8c)
        case .running: accent.color
        case .skipped, .future, .none: Color(hex: 0xebebf5, opacity: 0.82)
        }
    }

    @ViewBuilder private func shape(_ mark: Mark) -> some View {
        Group {
            switch mark {
            case .done:
                Circle().fill(WM.ok).frame(width: 11, height: 11)
            case .failed:
                RoundedRectangle(cornerRadius: 2).fill(WM.danger).frame(width: 9, height: 9).rotationEffect(.degrees(45))
            case .skipped:
                Capsule().fill(Color(hex: 0xebebf5, opacity: 0.5)).frame(width: 11, height: 3)
            case .future:
                Circle().strokeBorder(Color(hex: 0xebebf5, opacity: 0.5), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                    .frame(width: 11, height: 11)
            case .running:
                Circle().strokeBorder(accent.color, lineWidth: 3).frame(width: 11, height: 11)
            case .none:
                Circle().fill(Color.white.opacity(0.18)).frame(width: 4, height: 4)
            }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
    }
}

/// 点开一个点看到的那一场：哪一场、哪天几点到几点、用时、状态和原因、掉落。
private struct RunGlance: View {
    let phase: String
    let outcome: SessionOutcome
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if !outcome.stage.isEmpty { Swatch(code: outcome.stage, size: 18, radius: 5) }
                Text(LastRunText.kind(phase: phase) + (outcome.stage.isEmpty ? "" : " · \(outcome.stage)"))
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(when).font(.system(size: 13)).foregroundStyle(Color(hex: 0xebebf5, opacity: 0.82)).monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(LastRunText.statusWord(outcome.status)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor)
                if !outcome.reason.isEmpty { Text(outcome.reason).font(.system(size: 14)) }
            }
            .padding(.top, 2)
            if let drops = outcome.fight?.drops, !drops.isEmpty {
                DropText(drops: drops).padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 272, alignment: .leading)
        // 气泡弹在点阵条下面的空处；底子再厚一点，背景图的颜色不透上来。
        .background(WM.panel.opacity(0.9))
    }

    /// 「11 月 7 日 星期六 · 08:00–08:18 · 用时 18 分钟」；还在跑的写「08:00 开始」。
    private var when: String {
        var parts = [Beijing.todayCaption(outcome.started)]
        if outcome.ongoing {
            parts.append("\(RunLock.beijingClock(outcome.started)) 开始")
        } else {
            parts.append(outcome.span)
            if let finished = outcome.finished, outcome.status != "skipped" {
                parts.append("用时 " + RunHistory.durationText(Int(finished.timeIntervalSince(outcome.started))))
            }
        }
        return parts.joined(separator: " · ")
    }
}
