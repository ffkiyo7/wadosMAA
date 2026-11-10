//
//  TodayPage.swift
//  Wado's MAA
//
//  首页「今天」，从上到下：页头（日期、当期活动）、早场 / 晚场两张大卡（`TodaySessions.swift`）、
//  手动日常（`TodayManual.swift`）、待处理（`TodayPending.swift`）、近 7 天（`TodayWeek.swift`）。
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
                TimelineView(.periodic(from: .now, by: 30)) { context in WeekStrip(now: context.date) }
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
