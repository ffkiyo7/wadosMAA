//
//  TodayPage.swift
//  Wado's MAA
//
//  首页「今天」，从上到下：页头（日期、当期活动）、早场 / 晚场两张大卡（`TodaySessions.swift`）、
//  手动日常（`TodayManual.swift`）、待处理（`TodayPending.swift`）、最近几场。
//

import SwiftUI

struct TodayPage: View {
    let go: (WMPage) -> Void

    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if RemoteNotices.any(store) { RemoteNotices(gap: 0) }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    // 进行中的那张展开，另一张不跟着拉伸。
                    HStack(alignment: .top, spacing: 14) {
                        SessionCard(phase: "am", name: "早场", now: context.date)
                        SessionCard(phase: "pm", name: "晚场", now: context.date)
                    }
                }
                ForEach([store.schedule == nil ? store.scheduleError : nil, store.todayPlan == nil ? store.todayPlanError : nil]
                    .compactMap { $0 }, id: \.self)
                { error in
                    Text(error).font(.system(size: 12)).foregroundStyle(WM.danger)
                }
                ManualRunRow()
                TodayPending(go: go)
                RecentRunsSection()
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .task {
            await store.reload()
            // 活动跟着日子变；进首页顺手重读一次关卡选项（里面带当期活动）。
            await data.loadChoices()
        }
    }

    /// 「今天 11 月 10 日 星期二」；有活动时右边一个胶囊「『活动名』还剩 N 天」。
    private var header: some View {
        HStack(spacing: 12) {
            Text("今天").font(.system(size: 30, weight: .bold)).tracking(-0.5)
            Text(Beijing.todayCaption()).font(.system(size: 15)).foregroundStyle(WM.f2).padding(.top, 4)
            Spacer(minLength: 0)
            if let activity = data.choices?.activity, let end = activity.end, end > .now {
                HStack(spacing: 8) {
                    Swatch(code: activity.stages.first ?? "", size: 14, radius: 4)
                    Text(activity.name).font(.system(size: 13, weight: .semibold))
                    Text(Beijing.left(until: end)).font(.system(size: 13)).foregroundStyle(WM.f2).monospacedDigit()
                }
                .padding(.leading, 10)
                .padding(.trailing, 14)
                .frame(height: 30)
                .wmCard(radius: 15)
                .help(activity.start.map { "\(Beijing.slashDay($0))–\(Beijing.slashDay(end))" } ?? "")
            }
        }
        .frame(height: 38)
    }
}

/// 只读、读失败、刚才那次操作的回执（各页顶部共用）。
struct RemoteNotices: View {
    /// 下面留多少空：首页的区块之间本来就有间距，传 0。
    var gap: CGFloat = 14
    @Environment(RemoteStore.self) private var store

    /// 有没有要显示的。
    static func any(_ store: RemoteStore) -> Bool {
        store.schemaProblem != nil || store.loadError != nil || store.notice != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = store.schemaProblem {
                Label(problem, systemImage: "eye").foregroundStyle(WM.game).font(.system(size: 12))
            }
            if let error = store.loadError {
                NoticeLine(ok: false, text: error)
            }
            if let notice = store.notice {
                NoticeLine(ok: notice.ok, text: notice.text) { store.clearNotice() }
            }
        }
        .padding(.bottom, Self.any(store) ? gap : 0)
    }
}

// MARK: - 最近几场

struct RecentRunsSection: View {
    @Environment(RemoteStore.self) private var store

    /// 正在跑的那一场还没进索引，先放在最上面。
    private var running: Bool {
        LastRunText.ongoing.contains(store.lastRun["status"]?.string ?? "") && store.lastRun["status"] != nil
    }

    var body: some View {
        let runs = Array(store.recentRuns.prefix(RunHistory.shown))
        VStack(alignment: .leading, spacing: 0) {
            if runs.isEmpty {
                SectionTitle(title: "最近一次")
            } else {
                SectionTitle(title: "最近几场") { rateText }
            }
            VStack(spacing: 0) {
                if runs.isEmpty {
                    if store.lastRun["status"] == nil {
                        Text("还没有记录").foregroundStyle(WM.f2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    } else {
                        lastRunRow
                    }
                } else {
                    if running {
                        lastRunRow
                        RowDivider()
                    }
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        if index > 0 { RowDivider() }
                        recordRow(run)
                    }
                }
            }
            .wmCard()
        }
    }

    @ViewBuilder private var rateText: some View {
        if let rate = RunHistory.successRate(store.recentRuns) {
            Text("近 \(rate.total) 场成功 \(rate.ok * 100 / rate.total)%")
                .font(.system(size: 12)).foregroundStyle(WM.f2).monospacedDigit()
                .help("\(rate.total) 场里成功 \(rate.ok) 场，跳过和停下的不算")
        }
    }

    private func recordRow(_ run: RunRecord) -> some View {
        var when = run.startedAt.map { "\(Beijing.monthDay($0)) \(RunLock.beijingClock($0))" } ?? ""
        if let seconds = run.durationSeconds, run.status != "skipped" {
            when += (when.isEmpty ? "" : " · ") + RunHistory.durationText(seconds)
        }
        return HStack(spacing: 12) {
            Swatch(code: run.stage, size: 24, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).fontWeight(.semibold)
                Text(when).font(.system(size: 11.5)).foregroundStyle(WM.f2).monospacedDigit().lineLimit(1)
            }
            Spacer()
            Text(LastRunText.statusWord(run.status))
                .font(.system(size: 12))
                .foregroundStyle(Self.statusColor(run.status))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(run.reason)
    }

    static func statusColor(_ status: String) -> Color {
        status == "success" ? WM.ok
            : status == "skipped" || status == "cancelled" ? WM.f3
            : LastRunText.ongoing.contains(status) ? WM.game : WM.danger
    }

    private var lastRunRow: some View {
        let run = store.lastRun
        // 抄作业（phase 是 copilot-<token>）没有 plan，关卡在顶层 stage；下面一行用 summary。
        let plan = LastRunText.isCopilot(run) ? nil : run["plan"]?.object
        let stage = LastRunText.stage(run)
        let names = ["fight": "刷理智", "infrast": "基建", "recruit": "公招", "mall": "信用商店", "award": "领奖"]
        let tasks = Set((plan?["tasks"]?.object ?? [:]).filter { $0.value.bool == true }.keys)
        let order = ["fight", "infrast", "recruit", "mall", "award"]
        let taskText = order.filter { tasks.contains($0) }.compactMap { names[$0] }.joined(separator: "、")
        let started = run["started_at"]?.string.flatMap(RunLock.parseISO)
        let status = run["status"]?.string ?? ""
        let title = LastRunText.title(run)
        return HStack(spacing: 12) {
            Swatch(code: stage, size: 24, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(taskText.isEmpty ? (run["summary"]?.displayText ?? "") : taskText)
                    .font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(1)
            }
            Spacer()
            if let started {
                Text("\(Beijing.monthDay(started)) \(RunLock.beijingClock(started))")
                    .font(.system(size: 12)).foregroundStyle(WM.f2).monospacedDigit()
            }
            Text(LastRunText.statusWord(status))
                .font(.system(size: 12))
                .foregroundStyle(Self.statusColor(status))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help(run["summary"]?.displayText ?? "")
    }
}
