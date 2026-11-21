//
//  TodayTab.swift
//  Wado's MAA (iOS)
//
//  外壳阶段的今天页：只读显示今日两场和最近一场，完整版在 F2。
//

import SwiftUI
import WadosMAAShared

struct TodayTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if store.hasData {
                        sessions
                        lastRun
                    } else if store.connection == .connecting {
                        HStack(spacing: 12) {
                            SkeletonBlock(height: 148)
                            SkeletonBlock(height: 148)
                        }
                        SkeletonBlock(height: 76)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .connectionBanner()
            .navigationTitle("今天")
            .refreshable { store.reconnect() }
        }
    }

    @ViewBuilder private var sessions: some View {
        if let plan = store.snapshot?.todayPlan, !plan.sessions.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                ForEach(plan.sessions) { session in
                    SessionCard(session: session)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var lastRun: some View {
        if let run = store.snapshot?.lastRun {
            HStack {
                Text(LastRunText.title(run))
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(LastRunText.statusWord(run["status"]?.string ?? ""))
                    .foregroundStyle(Palette.secondary)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 60)
            .background(Palette.card, in: .rect(cornerRadius: 24, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SessionCard: View {
    let session: TodayPlan.Session

    private var stageText: String {
        if !session.enabled { return "关闭" }
        if session.skip { return "已跳过" }
        return session.stage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(session.name)
                    .font(.headline)
                Spacer(minLength: 4)
                Text(session.time)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 16)
            Text(stageText)
                .font(.system(size: 24, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(session.enabled && !session.skip ? Color.primary : Palette.secondary)
            if session.enabled, !session.skip, let drop = session.drops.first {
                Text(drop.name)
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 148, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card, in: .rect(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
