//
//  HistoryViews.swift
//  Wado's MAA (iOS)
//
//  历史记录（E18）、场次详情（E4 / E26）、截图（E19）和日志（E20）。
//

import SwiftUI
import UIKit
import WadosMAAShared

struct HistoryRoute: Hashable {}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, daily, copilot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .daily: "日常"
        case .copilot: "抄作业"
        }
    }

    var kind: String? {
        self == .all ? nil : rawValue
    }
}

// MARK: - 历史

struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: HistoryFilter = .all
    @State private var items: [RunRecord] = []
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var didLoad = false

    private var sections: [(title: String, rows: [RunRecord])] {
        var result: [(title: String, rows: [RunRecord])] = []
        for record in items {
            let title = record.startedAt.map { BeijingDay.title($0) } ?? "更早"
            if result.last?.title == title {
                result[result.count - 1].rows.append(record)
            } else {
                result.append((title, [record]))
            }
        }
        return result
    }

    var body: some View {
        List {
            Section {
                Picker("筛选", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows) { record in
                        NavigationLink(value: RunRoute(id: record.id)) {
                            RunRow(record: record)
                        }
                    }
                }
            }
            if hasMore || (isLoading && !items.isEmpty) {
                Section {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                                Text("加载中").foregroundStyle(Palette.secondary)
                            } else {
                                Text("加载更多")
                            }
                            Spacer()
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(isLoading)
                }
            }
        }
        .overlay {
            if items.isEmpty {
                if isLoading || !didLoad {
                    ProgressView()
                } else {
                    ContentUnavailableView("没有记录", systemImage: "clock")
                }
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(reset: true) }
        .task(id: filter) { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        guard !isLoading || reset else { return }
        isLoading = true
        defer {
            isLoading = false
            didLoad = true
        }
        let current = filter
        let page = await store.history(kind: current.kind, offset: reset ? 0 : items.count)
        guard !Task.isCancelled, current == filter else { return }
        guard let page else {
            if reset { items = [] }
            hasMore = false
            return
        }
        items = reset ? page.items : items + page.items
        hasMore = page.hasMore
    }
}

// MARK: - 场次详情

struct RunDetailView: View {
    @Environment(AppStore.self) private var store
    let runID: String

    @State private var report: RunReport?
    @State private var record: RunRecord?
    @State private var thumbnail: UIImage?
    @State private var isLoading = true
    @State private var isShowingScreenshot = false

    private var isCopilot: Bool {
        report?.isCopilot ?? record?.isCopilot ?? false
    }

    private var progress: RunProgressFile? {
        guard let progress = store.snapshot?.progress, progress.runId == runID else { return nil }
        return progress
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading, report == nil, record == nil {
                    SkeletonBlock(height: 190)
                    SkeletonBlock(height: 120)
                    SkeletonBlock(height: 196)
                } else if isCopilot {
                    copilotContent
                } else {
                    dailyContent
                }
                if !isLoading || report != nil || record != nil {
                    screenshotCard
                    NavigationLink {
                        RunLogView(runID: runID)
                    } label: {
                        WCard(vertical: 0) {
                            HStack {
                                Text("日志").font(.system(size: 16, weight: .semibold))
                                Spacer()
                                MoreLabel(title: "")
                            }
                            .frame(minHeight: 56)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: runID) { await load() }
        .fullScreenCover(isPresented: $isShowingScreenshot) {
            ScreenshotViewer(runID: runID, preview: thumbnail)
        }
    }

    private var navigationTitle: String {
        guard let date = record?.startedAt ?? progress?.startedAt else { return "场次详情" }
        return "\(BeijingDay.title(date)) \(BeijingTime.clock(date))"
    }

    // MARK: 日常（E4）

    @ViewBuilder private var dailyContent: some View {
        if let progress {
            TimelineLanes(
                items: LaneItem.daily(progress, showDurations: false),
                startLabel: progress.startedAt.map(BeijingTime.clock),
                endLabel: (progress.steps.compactMap(\.finishedAt).max()).map(BeijingTime.clock),
                labelWidth: 70)
                .padding(.horizontal, 4)
        }
        Text(dailyHeadline)
            .font(.system(size: 30, weight: .heavy))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 4)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 14) {
            if let stage = record?.stage, !stage.isEmpty {
                FactView(
                    label: "刷理智",
                    value: (progress?.fightsDone ?? 0) > 0 ? "\(stage) ×\(progress?.fightsDone ?? 0)" : stage,
                    color: Palette.orange)
            }
            if let drop = progress?.drops.first {
                FactView(label: "掉落", value: "\(drop.name) ×\(drop.count)", color: Palette.violet)
            }
            if let sanity = progress?.sanity {
                FactView(label: "理智", value: "\(sanity.current)/\(sanity.max)", color: Palette.orange)
            }
            if let seconds = record?.durationSeconds ?? report?.durationSeconds {
                FactView(label: "用时", value: shortDuration(seconds), color: Palette.blue)
            }
        }
        .padding(.horizontal, 4)
        if let summary = report?.summary, progress == nil, !summary.isEmpty {
            WCard {
                Text(summary).font(.system(size: 15))
            }
        }
        notesCard(progress?.notes.map(\.text) ?? report?.notes ?? [])
    }

    private var dailyHeadline: String {
        let name: String
        switch record?.phase {
        case "am": name = "早场"
        case "pm": name = "晚场"
        default: name = "手动场"
        }
        switch record?.status ?? report?.status ?? "" {
        case "success": return "\(name)打完了"
        case "skipped": return "\(name)已跳过"
        case "cancelled", "canceled": return "\(name)已停止"
        default: return "\(name)没打完"
        }
    }

    // MARK: 抄作业（E26）

    @ViewBuilder private var copilotContent: some View {
        if let report {
            let lanes = LaneItem.copilot(report.results)
            if !lanes.items.isEmpty {
                TimelineLanes(
                    items: lanes.items,
                    startLabel: lanes.start.map(BeijingTime.clock),
                    endLabel: lanes.end.map(BeijingTime.clock))
                    .padding(.horizontal, 4)
            }
            Text(copilotHeadline(report))
                .font(.system(size: 30, weight: .heavy))
                .padding(.horizontal, 4)
            HStack(alignment: .center, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible())], spacing: 14) {
                    FactView(
                        label: "通关", value: "\(report.won ?? 0)/\(report.total ?? report.results.count)",
                        color: Palette.teal)
                    if let seconds = report.durationSeconds {
                        FactView(label: "用时", value: shortDuration(seconds), color: Palette.blue)
                    }
                    FactView(label: "失败", value: "\(report.failedCount) 关", color: Palette.red)
                    if let tally = store.copilotTally {
                        FactView(label: "还差", value: "\(tally.remaining) 关", color: Palette.pink)
                    }
                }
                if let tally = store.copilotTally {
                    ActivityRings(tally: tally).frame(width: 84, height: 84)
                }
            }
            .padding(.horizontal, 4)
            if !report.results.isEmpty {
                WCard(vertical: 2) {
                    VStack(spacing: 0) {
                        ForEach(Array(report.results.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Hairline() }
                            resultRow(row)
                        }
                    }
                }
            }
            if let reason = report.stopReason {
                WCard {
                    Text(reason).font(.system(size: 15)).foregroundStyle(Palette.red)
                }
            }
        } else {
            ContentUnavailableView("没有战报", systemImage: "doc.text")
        }
    }

    private func copilotHeadline(_ report: RunReport) -> String {
        switch report.status {
        case "success": "抄作业打完了"
        case "cancelled", "canceled": "抄作业已停止"
        default: "抄作业没打完"
        }
    }

    private func resultRow(_ row: RunReport.StageResult) -> some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.stage).font(.system(size: 16, weight: .bold))
                Text(row.modeTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
            Spacer()
            Text(row.outcomeTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.outcome == "won" ? Palette.green : row.outcome == "skipped" ? Palette.secondary : Palette.red)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func notesCard(_ notes: [String]) -> some View {
        if !notes.isEmpty {
            WCard {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(notes, id: \.self) { note in
                        Text(note).font(.system(size: 15))
                    }
                }
            }
        }
    }

    // MARK: 截图

    @ViewBuilder private var screenshotCard: some View {
        if let thumbnail {
            Button {
                isShowingScreenshot = true
            } label: {
                WCard(horizontal: 10, vertical: 10) {
                    ZStack(alignment: .bottomLeading) {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: 176)
                            .clipped()
                        Text(isCopilot ? "结算截图" : "主页截图")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Palette.background.opacity(0.9), in: .capsule)
                            .padding(12)
                    }
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("放大截图")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        record = store.recentRecords.first { $0.id == runID }
        async let loadedReport = store.runReport(id: runID)
        async let loadedThumbnail = store.runScreenshot(id: runID, thumbnail: true)
        let (fetchedReport, fetchedThumbnail) = await (loadedReport, loadedThumbnail)
        report = fetchedReport
        thumbnail = fetchedThumbnail
        // 深链打开的旧场次不在最近列表里，翻历史补时间和关卡。
        if record == nil, let page = await store.history(kind: nil, offset: 0, limit: 200) {
            record = page.items.first { $0.id == runID }
        }
    }
}

// MARK: - 截图全屏（E19）

private struct ScreenshotViewer: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let runID: String
    let preview: UIImage?
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let shown = image ?? preview {
                ZoomableImage(image: shown).ignoresSafeArea()
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .circle)
            }
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .statusBarHidden()
        .task { image = await store.runScreenshot(id: runID, thumbnail: false) }
    }
}

/// 系统滚动视图的双指缩放和双击放大。
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .black
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.imageView = view
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func toggleZoom(_ gesture: UITapGestureRecognizer) {
            guard let scroll = imageView?.superview as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(
                    to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                    animated: true)
            }
        }
    }
}

// MARK: - 日志（E20）

private struct RunLogView: View {
    @Environment(AppStore.self) private var store
    let runID: String
    @State private var lines: [String] = []
    @State private var isLoading = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                } else if lines.isEmpty {
                    ContentUnavailableView("没有日志", systemImage: "doc.plaintext")
                }
            }
            .task {
                lines = await store.runLog(id: runID)?.lines ?? []
                isLoading = false
                if !lines.isEmpty {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(lines.count - 1, anchor: .bottom)
                }
            }
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
    }
}
