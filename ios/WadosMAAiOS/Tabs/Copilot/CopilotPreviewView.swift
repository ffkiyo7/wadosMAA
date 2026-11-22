//
//  CopilotPreviewView.swift
//  Wado's MAA (iOS)
//
//  作业预览与开打（E6、E28、E31）和规则 Sheet（E21）。
//  离开页面或点取消都会立刻取消服务端的搜索；练度不够的作业不可选。
//

import SwiftUI
import WadosMAAShared

struct CopilotPreviewView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let stage: String

    private enum Phase {
        case searching, loaded(CopilotPreview), failed(String), canceled
    }

    @State private var phase: Phase = .searching
    @State private var requestID = UUID().uuidString.lowercased()
    @State private var selectedID: Int?
    @State private var expandedID: Int?
    @State private var isConfirming = false
    @State private var isLaunching = false
    @State private var didLaunch = false

    private var row: CopilotStageRow? {
        store.copilotStages?.stages.first { $0.stage == stage }
    }

    var body: some View {
        Group {
            switch phase {
            case .searching: searching
            case let .loaded(preview): loaded(preview)
            case let .failed(message):
                retryState(title: message, symbol: "exclamationmark.magnifyingglass")
            case .canceled:
                retryState(title: "已取消", symbol: "xmark.circle")
            }
        }
        .navigationTitle(stage)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if row?.isCleared != true {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("我打过了", systemImage: "checkmark.circle") {
                            Task { await store.markCopilot(stage: stage, cleared: true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .disabled(!store.canWrite)
                    .accessibilityLabel("更多")
                }
            }
        }
        .onChange(of: row?.isCleared == true) { _, isCleared in
            if isCleared { dismiss() }
        }
        .task(id: requestID) { await search() }
        .onDisappear {
            guard !didLaunch else { return }
            let id = requestID
            Task { await store.cancelPreview(requestID: id) }
        }
    }

    // MARK: - 状态

    private var searching: some View {
        VStack(spacing: 18) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("正在搜作业").font(.system(size: 21, weight: .bold))
            Button {
                let id = requestID
                phase = .canceled
                Task { await store.cancelPreview(requestID: id) }
            } label: {
                PillLabel(title: "取消").frame(width: 120)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func retryState(title: String, symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } actions: {
            Button("重新搜索") { restart() }
                .disabled(!store.canWrite)
        }
    }

    private func restart() {
        phase = .searching
        selectedID = nil
        expandedID = nil
        requestID = UUID().uuidString.lowercased()
    }

    private func search() async {
        guard case .searching = phase else { return }
        let id = requestID
        let outcome = await store.previewCopilot(stage: stage, requestID: id)
        guard id == requestID, !Task.isCancelled else { return }
        guard case .searching = phase else { return }
        switch outcome {
        case let .loaded(preview):
            selectedID = preview.bestId ?? preview.candidates.first(where: \.perfect)?.id
            phase = .loaded(preview)
        case let .failed(message):
            phase = .failed(message)
        case .canceled:
            phase = .canceled
        }
    }

    // MARK: - 结果

    private func loaded(_ preview: CopilotPreview) -> some View {
        let perfect = preview.candidates.filter(\.perfect)
        let selected = preview.candidates.first { $0.id == selectedID && $0.perfect }
        let canLaunch = selected != nil && preview.blocker?.isEmpty != false && store.canWrite
            && store.activeRun == nil && !isLaunching
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PreviewRing(candidate: selected ?? preview.candidates.first, hasPerfect: !perfect.isEmpty)
                    .frame(width: 128, height: 128)
                    .frame(maxWidth: .infinity)
                Text(perfect.isEmpty ? "没有完美作业" : "\(perfect.count) 份完美作业")
                    .font(.system(size: 30, weight: .heavy))
                    .padding(.horizontal, 4)
                if !perfect.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        FactView(label: "理智", value: preview.sanityCost.map(String.init) ?? "—", color: Palette.orange)
                        FactView(label: "模式", value: modeText(preview.modes), color: Palette.blue)
                    }
                    .padding(.horizontal, 4)
                }
                if !preview.candidates.isEmpty {
                    WCard(vertical: 2) {
                        VStack(spacing: 0) {
                            ForEach(Array(preview.candidates.enumerated()), id: \.element.id) { index, candidate in
                                if index > 0 { Hairline() }
                                candidateRow(candidate)
                            }
                        }
                    }
                }
                if let blocker = preview.blocker, !blocker.isEmpty {
                    Text(blocker)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.amber)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if perfect.isEmpty {
                    Button {
                        restart()
                    } label: {
                        launchLabel("重新搜索", enabled: store.canWrite)
                    }
                    .disabled(!store.canWrite)
                } else {
                    Button {
                        isConfirming = true
                    } label: {
                        launchLabel(store.activeRun.map { "\($0.title)运行中" } ?? "确认开打", enabled: canLaunch)
                    }
                    .disabled(!canLaunch)
                    .confirmationDialog(
                        "开打 \(preview.stage)？", isPresented: $isConfirming, titleVisibility: .visible,
                        presenting: selected
                    ) { candidate in
                        Button("开打") { launch(token: preview.token, candidate: candidate) }
                        Button("取消", role: .cancel) {}
                    } message: { candidate in
                        Text("作业：\(candidate.title ?? "#\(candidate.id)")")
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func launchLabel(_ title: String, enabled: Bool) -> some View {
        Group {
            if isLaunching {
                ProgressView().tint(.white)
            } else {
                Text(title)
            }
        }
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(enabled ? Color.white : Palette.secondary)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(enabled ? Palette.accent : Palette.ghost, in: .capsule)
    }

    private func candidateRow(_ candidate: CopilotCandidate) -> some View {
        let isSelected = selectedID == candidate.id && candidate.perfect
        let gaps = (candidate.gaps ?? []) + (candidate.softGaps ?? [])
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    guard candidate.perfect else { return }
                    selectedID = candidate.id
                } label: {
                    HStack(spacing: 12) {
                        radio(isSelected: isSelected, isPerfect: candidate.perfect)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.title?.isEmpty == false ? candidate.title ?? "" : "作业 #\(candidate.id)")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(candidate.perfect ? Color.primary : Palette.secondary)
                                .lineLimit(1)
                            Text(candidate.perfect ? statsText(candidate) : gapText(gaps))
                                .font(.system(size: 14))
                                .foregroundStyle(candidate.perfect ? Palette.secondary : Palette.red)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!candidate.perfect)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                if !gaps.isEmpty {
                    Button {
                        withAnimation(.snappy) { expandedID = expandedID == candidate.id ? nil : candidate.id }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Palette.secondary)
                            .rotationEffect(.degrees(expandedID == candidate.id ? 180 : 0))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看练度缺口")
                }
            }
            if expandedID == candidate.id {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(gaps, id: \.self) { gap in
                        Text(gap).font(.system(size: 14)).foregroundStyle(Palette.red)
                    }
                }
                .padding(.leading, 36)
                .padding(.bottom, 8)
            }
        }
        .frame(minHeight: 66)
    }

    private func radio(isSelected: Bool, isPerfect: Bool) -> some View {
        ZStack {
            if isSelected {
                Circle().fill(Palette.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white)
            } else if isPerfect {
                Circle().strokeBorder(Palette.secondary, lineWidth: 2)
            } else {
                Circle().strokeBorder(Palette.red, lineWidth: 2)
                Rectangle().fill(Palette.red).frame(width: 10, height: 2)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func statsText(_ candidate: CopilotCandidate) -> String {
        var parts: [String] = []
        if let views = candidate.views {
            parts.append(views >= 1000 ? String(format: "%.1fk", Double(views) / 1000) : "\(views)")
        }
        if let rating = candidate.ratingRatio, rating > 0 {
            parts.append("好评 \(Int((rating * 100).rounded()))%")
        }
        return parts.joined(separator: "　")
    }

    private func gapText(_ gaps: [String]) -> String {
        gaps.isEmpty ? "练度不足" : "缺 " + gaps.prefix(2).joined(separator: "　")
    }

    private func modeText(_ modes: [String]?) -> String {
        let titles = (modes ?? ["normal"]).map { $0 == "raid" ? "突袭" : "普通" }
        return titles.joined(separator: " · ")
    }

    private func launch(token: String, candidate: CopilotCandidate) {
        isLaunching = true
        Task {
            let ok = await store.goCopilot(token: token, candidateID: candidate.id)
            isLaunching = false
            guard ok else { return }
            didLaunch = true
            dismiss()
            if store.activeRun != nil {
                store.isRunSheetPresented = true
            } else {
                store.showToast(AppToast(text: "已开打 \(stage)", actionTitle: "查看", action: .showRun))
            }
        }
    }
}

/// 练度匹配度：后端不下发编队人数，这里只显示比例。
private struct PreviewRing: View {
    let candidate: CopilotCandidate?
    let hasPerfect: Bool

    private var ratio: Double {
        min(max(candidate?.ratio ?? (hasPerfect ? 1 : 0), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Palette.ghost, lineWidth: 18)
            Circle()
                .trim(from: 0, to: ratio)
                .stroke(hasPerfect ? Palette.accent : Palette.red, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("练度")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("\(Int((ratio * 100).rounded()))%")
                    .font(.system(size: 22, weight: .heavy))
                    .monospacedDigit()
            }
        }
        .padding(9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasPerfect ? "练度满足" : "没有完美作业")
    }
}

// MARK: - 规则（E21）

struct CopilotRulesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    rule("copilot_blackout_minutes", "早晚场前不开打", "分", 25, 0...180, step: 5)
                    rule("auto_copilot_min_lead_minutes", "离早晚场不足时不开新关", "分", 40, 0...240, step: 5)
                    rule("activity_search_retry_minutes", "练度不够或没作业时", "分后再找", 30, 5...1440, step: 5)
                    rule("auto_copilot_max_attempts_per_day", "同一关每天最多自动尝试", "次", 2, 0...20, zero: "不限")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .navigationTitle("规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭", systemImage: "xmark") { dismiss() }
                }
            }
            .task { await store.loadSettings() }
        }
        .presentationDetents([.medium, .large])
    }

    private func rule(
        _ key: String, _ title: String, _ unit: String, _ fallback: Int, _ range: ClosedRange<Int>, step: Int = 1,
        zero: String? = nil
    ) -> some View {
        ConfigStepperCard(
            key: key, title: title, unit: unit, color: Palette.teal, fallback: fallback, range: range, step: step,
            zeroText: zero, undo: false)
    }
}
