//
//  TodayModel.swift
//  Wado's MAA (iOS)
//
//  把计划、锁和场次索引合成「今天这一场现在是什么状态」。
//

import Foundation
import SwiftUI
import WadosMAAShared

enum SessionStatus: Equatable {
    case planned
    case skipped
    case closed
    case running
    case finished(RunRecord)
    case failed(RunRecord)

    /// 已开跑或已结束的场次不能再改。
    var isEditable: Bool {
        self == .planned || self == .skipped
    }
}

extension RunRecord {
    /// 「有的事没做完」在手机上收成一个词，其他原因照原样显示。
    var displayReason: String {
        reason == RunHistory.failureText["task_failed"] ? "未完成" : reason
    }
}

enum BeijingDay {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BeijingTime.zone
        return calendar
    }

    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 「今天」「昨天」「11 月 19 日」。
    static func title(_ date: Date, now: Date = Date()) -> String {
        let calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "昨天"
        }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }

    /// `plan.date` + `HH:MM` → 这一刻。
    static func date(day: String, time: String) -> Date? {
        let dayParts = day.split(separator: "-").compactMap { Int($0) }
        let timeParts = time.split(separator: ":").compactMap { Int($0) }
        guard dayParts.count == 3, timeParts.count == 2 else { return nil }
        return calendar.date(
            from: DateComponents(
                year: dayParts[0], month: dayParts[1], day: dayParts[2], hour: timeParts[0], minute: timeParts[1]))
    }

    /// 「剩 6 小时」「剩 3 天」。
    static func remaining(until end: Date, now: Date = Date()) -> String {
        let seconds = Int(end.timeIntervalSince(now))
        if seconds <= 0 { return "已结束" }
        if seconds < 3600 { return "剩 \(max(seconds / 60, 1)) 分钟" }
        if seconds < 48 * 3600 { return "剩 \(seconds / 3600) 小时" }
        return "剩 \(seconds / 86400) 天"
    }
}

func shortDuration(_ seconds: Int) -> String {
    if seconds < 60 { return "不到 1 分" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes) 分" }
    return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分"
}

struct CopilotTally: Equatable {
    struct Group: Equatable {
        var done = 0
        var total = 0

        var fraction: Double {
            total > 0 ? Double(done) / Double(total) : 0
        }
    }

    var normal = Group()
    var ex = Group()
    var s = Group()

    var cleared: Int { normal.done + ex.done + s.done }
    var total: Int { normal.total + ex.total + s.total }
    var remaining: Int { total - cleared }

    init(stages: [CopilotStageRow]) {
        for row in stages {
            let done = row.status == "cleared"
            switch row.stageCategory {
            case "ex":
                ex.total += 1
                if done { ex.done += 1 }
            case "s":
                s.total += 1
                if done { s.done += 1 }
            default:
                normal.total += 1
                if done { normal.done += 1 }
            }
        }
    }
}

extension AppStore {
    var planSessions: [TodayPlan.Session] {
        snapshot?.todayPlan?.sessions ?? []
    }

    /// 最近场次：索引还没读到时，用 `last_run` 顶一行。
    var recentRecords: [RunRecord] {
        if !recentRuns.isEmpty { return recentRuns }
        guard let run = snapshot?.lastRun, let phase = run["phase"]?.string, let status = run["status"]?.string,
            !LastRunText.ongoing.contains(status)
        else { return [] }
        let record = RunRecord(
            id: run["run_id"]?.string ?? phase,
            phase: phase,
            stage: LastRunText.stage(run),
            status: status,
            failure: run["failure"]?.string ?? "",
            skipReason: run["skip_reason"]?.string ?? "",
            startedAt: run["started_at"]?.string.flatMap(BeijingTime.parseISO),
            finishedAt: run["finished_at"]?.string.flatMap(BeijingTime.parseISO),
            durationSeconds: nil,
            progressPath: run["progress"]?.string)
        return [record]
    }

    func todayRecord(for session: TodayPlan.Session) -> RunRecord? {
        guard let day = snapshot?.todayPlan?.date else { return nil }
        return recentRecords.first { record in
            record.phase == session.phase && record.startedAt.map(BeijingDay.key) == day
        }
    }

    func status(of session: TodayPlan.Session) -> SessionStatus {
        if activeRun?.phase == session.phase { return .running }
        if let record = todayRecord(for: session) {
            switch record.status {
            case "success": return .finished(record)
            case "skipped": return .skipped
            default: return .failed(record)
            }
        }
        if !session.enabled { return .closed }
        return session.skip ? .skipped : .planned
    }

    /// 只有计划里的跳过能恢复；已经记成跳过的场次时间已过。
    func canRestore(_ session: TodayPlan.Session) -> Bool {
        session.skip && status(of: session) == .skipped && todayRecord(for: session) == nil
    }

    /// 首屏主角：在跑的 → 下一场待跑的 → 最后一场没跑成的 → 最后一场。
    var focusSession: TodayPlan.Session? {
        let sessions = planSessions
        if let running = sessions.first(where: { status(of: $0) == .running }) { return running }
        if let planned = sessions.first(where: { status(of: $0) == .planned }) { return planned }
        if let open = sessions.last(where: {
            if case .finished = status(of: $0) { return false }
            return true
        }) {
            return open
        }
        return sessions.last
    }

    func headline(for session: TodayPlan.Session?) -> String {
        guard let session else { return "今天" }
        switch status(of: session) {
        case .running: return "\(session.name)运行中"
        case .planned: return session.phase == "pm" ? "今晚还有一场" : "今早还有一场"
        case .skipped: return "\(session.name)已跳过"
        case .closed: return "\(session.name)已关闭"
        case .failed: return "\(session.name)没打完"
        case .finished: return "今天都打完了"
        }
    }

    /// 这一场的进度文件：快照只带最近一场。
    func progress(for record: RunRecord) -> RunProgressFile? {
        guard let progress = snapshot?.progress, progress.runId == record.id else { return nil }
        return progress
    }

    /// 「TL-9 ×5　电极单元 ×5」；没有把数时退回关卡名。
    func recentText(_ record: RunRecord) -> String {
        if record.isCopilot {
            if record.status == "skipped" { return "已跳过" }
            let word = record.status == "success" ? "通关" : LastRunText.statusWord(record.status)
            if let won = record.won, let total = record.total, total > 1 {
                return "\(won)/\(total) 关\(word)"
            }
            return [record.stage, word].filter { !$0.isEmpty }.joined(separator: " ")
        }
        switch record.status {
        case "success": break
        case "skipped": return "已跳过"
        case "cancelled", "canceled": return "已取消"
        default: return record.reason.isEmpty ? "未完成" : record.displayReason
        }
        guard let progress = progress(for: record) else { return record.stage.isEmpty ? "完成" : record.stage }
        var parts: [String] = []
        if !record.stage.isEmpty {
            parts.append(progress.fightsDone > 0 ? "\(record.stage) ×\(progress.fightsDone)" : record.stage)
        }
        if let drop = progress.drops.first { parts.append("\(drop.name) ×\(drop.count)") }
        return parts.isEmpty ? "完成" : parts.joined(separator: "　")
    }

    /// 理智：优先快照的实测值，没有就用这一场进度里的。
    var sanityStatus: SanityStatus? {
        if let sanity = snapshot?.sanity { return sanity }
        guard let sanity = snapshot?.progress?.sanity else { return nil }
        return SanityStatus(
            current: sanity.current, max: sanity.max, measuredAt: snapshot?.progress?.updatedAt, estimatedNow: nil)
    }

    /// 下一场还没开跑的定时场。
    var nextPlannedSession: (session: TodayPlan.Session, date: Date)? {
        guard let day = snapshot?.todayPlan?.date else { return nil }
        for session in planSessions where status(of: session) == .planned {
            if let date = BeijingDay.date(day: day, time: session.time), date > Date() {
                return (session, date)
            }
        }
        return nil
    }

    var copilotTally: CopilotTally? {
        guard let stages = copilotStages, stages.inActivity else { return nil }
        return CopilotTally(stages: stages.stages)
    }
}
