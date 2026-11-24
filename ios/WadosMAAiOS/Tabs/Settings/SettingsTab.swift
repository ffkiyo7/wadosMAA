//
//  SettingsTab.swift
//  Wado's MAA (iOS)
//
//  设置（E8）：连接卡片和各项入口；连接详情沿用 E30。
//

import SwiftUI
import WadosMAAShared

private enum SettingsRoute: Hashable {
    case push, resources, scheduler, signing, advanced
}

struct SettingsTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ConnectionBanner()
                    connectionCard
                    entries.dimmedWhenDisconnected()
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .navigationTitle("设置")
            .navigationDestination(isPresented: $store.isConnectionDetailPresented) {
                ConnectionDetailView()
            }
            .navigationDestination(isPresented: $store.isSigningDetailPresented) {
                SigningDetailView()
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .push: PushDetailView()
                case .resources: ResourceDetailView()
                case .scheduler: SchedulerDetailView()
                case .signing: SigningDetailView()
                case .advanced: AdvancedSettingsView()
                }
            }
        }
    }

    // MARK: - 连接

    private var connectionCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                store.isConnectionDetailPresented = true
            } label: {
                WCard(vertical: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            node("iphone")
                            HStack {
                                ForEach(0..<5, id: \.self) { index in
                                    if index > 0 { Spacer(minLength: 0) }
                                    Circle()
                                        .fill(linkColor)
                                        .frame(width: index == 2 ? 10 : 6, height: index == 2 ? 10 : 6)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            node("macmini")
                        }
                        .frame(height: 72)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            MoreLabel(title: routeTitle, color: linkColor)
                            latencyText
                        }
                    }
                }
                .contentShape(.rect(cornerRadius: 24))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("连接详情，\(store.connection.summary)")

            Button {
                Task { await store.testConnection() }
            } label: {
                Group {
                    if store.isTestingConnection {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44).background(Palette.ghost, in: .capsule)
                    } else {
                        PillLabel(title: "测试")
                    }
                }
                .frame(width: 96)
            }
            .buttonStyle(.plain)
            .disabled(store.isTestingConnection)
            .padding(18)
        }
    }

    private func node(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .scaledFont(size: 26, weight: .medium)
            .frame(width: 64, height: 64)
            .background(Palette.ghost, in: .circle)
    }

    private var linkColor: Color {
        switch store.connection {
        case .online(.lan, _): Palette.blue
        case .online(.remote, _): Palette.teal
        case .connecting: Palette.secondary
        default: Palette.red
        }
    }

    private var routeTitle: String {
        switch store.connection {
        case .online(.lan, _): "局域网"
        case .online(.remote, _): "远程"
        default: store.connection.summary
        }
    }

    @ViewBuilder private var latencyText: some View {
        if case let .online(_, latency) = store.connection {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(latency)").scaledFont(size: 34, weight: .heavy).monospacedDigit()
                Text("ms")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundStyle(Palette.secondary)
            }
        } else {
            Text("—").scaledFont(size: 34, weight: .heavy)
        }
    }

    // MARK: - 入口

    private var entries: some View {
        WCard(vertical: 0) {
            VStack(spacing: 0) {
                Button {
                    store.isPairingPresented = true
                } label: {
                    EntryRow(symbol: "qrcode.viewfinder", title: "扫码配对")
                }
                .buttonStyle(.plain)
                entryDivider
                link(.push, symbol: "bell", title: "推送", value: pushValue)
                entryDivider
                link(.resources, symbol: "shippingbox", title: "游戏资源", value: resourceValue)
                entryDivider
                link(.scheduler, symbol: "clock", title: "调度器", value: schedulerValue)
                entryDivider
                link(.signing, symbol: "checkmark.seal", title: "iOS 签名", value: signingValue)
                entryDivider
                link(.advanced, symbol: "gearshape", title: "高级", value: nil)
            }
        }
    }

    private var entryDivider: some View {
        Hairline().padding(.leading, 36)
    }

    private func link(_ route: SettingsRoute, symbol: String, title: String, value: String?) -> some View {
        NavigationLink(value: route) {
            EntryRow(symbol: symbol, title: title, value: value)
        }
        .buttonStyle(.plain)
    }

    private var pushValue: String? {
        guard let notify = store.snapshot?.notify else { return nil }
        return notify.configured ? "Bark" : "未配置"
    }

    private var resourceValue: String? {
        guard let upstream = store.snapshot?.upstream else { return nil }
        return upstream.resourceTitle
    }

    private var schedulerValue: String? {
        let count = store.snapshot?.schedule?.jobs?.count ?? store.snapshot?.scheduler?.jobs.count ?? 0
        return count > 0 ? "\(count) 项" : nil
    }

    private var signingValue: String? {
        guard let resign = store.snapshot?.resign else { return nil }
        if resign.status == "running" { return "续签中" }
        guard let text = resign.expirationDate, let date = BeijingTime.parseISO(text) else { return nil }
        return date > Date() ? BeijingDay.remaining(until: date) : "已过期"
    }
}

private struct EntryRow: View {
    let symbol: String
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .scaledFont(size: 17, weight: .medium)
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(title).scaledFont(size: 16)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .scaledFont(size: 16)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(Palette.secondary.opacity(0.7))
        }
        .frame(minHeight: 50)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension ConnectionState {
    var summary: String {
        switch self {
        case .connecting: "连接中"
        case let .online(route, latency): "\(route == .lan ? "局域网" : "远程") · \(latency) ms"
        case .offline: "离线"
        case .tokenInvalid: "Token 失效"
        case .certificateMismatch: "证书不匹配"
        case .tunnelDown: "隧道不通"
        }
    }
}

extension UpstreamStatus {
    var resourceTitle: String {
        if running || verdict == "running" { return "更新中" }
        switch verdict {
        case "blocked": return "必须更新"
        case "stale": return "有更新"
        default: return "最新"
        }
    }
}

// MARK: - 连接详情（E30）

private struct ConnectionDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var isEditing = false

    var body: some View {
        Form {
            Section("局域网") {
                LabeledContent("地址", value: store.config?.lanURL.absoluteString ?? "")
                LabeledContent("主指纹", value: mask(store.config?.primaryPin))
                if let backup = store.config?.backupPin, !backup.isEmpty {
                    LabeledContent("备指纹", value: mask(backup))
                }
            }
            Section("远程") {
                LabeledContent("域名", value: store.config?.remoteURL.host() ?? "")
            }
            Section("鉴权") {
                LabeledContent("Token", value: "••••••••")
            }
            Section {
                Button {
                    Task { await store.testConnection() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if store.isTestingConnection {
                            ProgressView()
                        } else {
                            Text(store.connection.summary)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .disabled(store.isTestingConnection)
                Button("重新配对") {
                    store.isPairingPresented = true
                }
            }
        }
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.pairedConfig != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { isEditing = true }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            PairingFlow(isSheet: true, opensEditor: true)
        }
    }

    private func mask(_ pin: String?) -> String {
        guard let pin, pin.count > 8 else { return "" }
        return "\(pin.prefix(4))…\(pin.suffix(4))"
    }
}

// MARK: - 推送

private struct PushDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                LabeledContent("Bark", value: statusText)
            }
            Section {
                Button {
                    Task { await store.sendTestPush() }
                } label: {
                    HStack {
                        Text("发一条测试推送")
                        Spacer()
                        if store.isSendingTestPush { ProgressView() }
                    }
                }
                .disabled(!store.canWrite || store.isSendingTestPush || store.snapshot?.notify?.configured == false)
            }
        }
        .navigationTitle("推送")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        guard let notify = store.snapshot?.notify else { return "—" }
        return notify.configured ? "已配置" : "未配置"
    }
}

// MARK: - 游戏资源

private struct ResourceDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            if let upstream = store.snapshot?.upstream {
                Section {
                    LabeledContent("状态", value: upstream.resourceTitle)
                    if let text = upstream.lastSuccessAt, let date = BeijingTime.parseISO(text) {
                        LabeledContent("上次更新", value: "\(BeijingDay.title(date)) \(BeijingTime.clock(date))")
                    }
                    if let reason = upstream.blockReason, !reason.isEmpty {
                        Text(reason).foregroundStyle(Palette.red)
                    }
                }
                Section {
                    LabeledContent("maa-cli", value: upstream.versions.maaCli ?? "—")
                    LabeledContent("MaaCore", value: upstream.versions.maaCore ?? "—")
                    LabeledContent("MaaResource", value: resourceVersion(upstream))
                }
                Section {
                    Button {
                        Task { await store.updateResources() }
                    } label: {
                        HStack {
                            Text("现在更新")
                            Spacer()
                            if store.isUpdatingResources || upstream.running { ProgressView() }
                        }
                    }
                    .disabled(
                        !store.canWrite || store.isUpdatingResources || upstream.running
                            || !(upstream.updateBlocked ?? "").isEmpty)
                    if let blocked = upstream.updateBlocked, !blocked.isEmpty {
                        Text(blocked).foregroundStyle(Palette.secondary)
                    }
                }
            } else {
                ContentUnavailableView("读不到资源状态", systemImage: "shippingbox")
            }
        }
        .navigationTitle("游戏资源")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resourceVersion(_ upstream: UpstreamStatus) -> String {
        if let head = upstream.versions.maaResourceHead, !head.isEmpty { return String(head.prefix(8)) }
        return upstream.versions.resourceLastUpdated ?? "—"
    }
}

// MARK: - 调度器

private struct SchedulerDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var depotOverride: Bool?

    private static let names: [String: String] = [
        "plan_card_am": "早场计划", "daily_am": "早场日常", "plan_card_pm": "晚场计划", "daily_pm": "晚场日常",
        "activity_watch": "活动监控", "depot": "仓库对表",
    ]
    private static let order = ["plan_card_am", "daily_am", "plan_card_pm", "daily_pm", "activity_watch"]

    private var values: [String: ScheduleReport.ScheduledJob] {
        store.snapshot?.schedule?.jobs ?? [:]
    }

    private var jobs: [ScheduleReport.ScheduledJob] {
        let known = Self.order.compactMap { values[$0] }
        let others = values.values.filter { !Self.order.contains($0.id) && $0.id != "depot" }.sorted { $0.id < $1.id }
        return known + others
    }

    private var depotEnabled: Bool {
        depotOverride ?? store.snapshot?.schedule?.depotEnabled ?? values["depot"]?.enabled ?? false
    }

    var body: some View {
        Form {
            if values.isEmpty {
                ContentUnavailableView("读不到调度器", systemImage: "clock")
            } else {
                Section {
                    ForEach(jobs, id: \.id) { job in
                        JobRow(title: Self.names[job.id] ?? job.id, job: job)
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { depotEnabled }, set: setDepot)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("仓库对表")
                            if depotEnabled, let job = values["depot"] {
                                JobStatusLine(job: job)
                            }
                        }
                    }
                    .disabled(!store.canWrite)
                }
            }
        }
        .navigationTitle("调度器")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setDepot(_ value: Bool) {
        depotOverride = value
        Task {
            await store.setDepotEnabled(value)
            depotOverride = nil
        }
    }
}

private struct JobRow: View {
    let title: String
    let job: ScheduleReport.ScheduledJob

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).foregroundStyle(job.enabled ? Color.primary : Palette.secondary)
                Spacer()
                Text(job.enabled ? JobStatusLine.next(job) : "关闭")
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            }
            JobStatusLine(job: job, showsNext: false)
        }
    }
}

/// 上次没正常跑完才出现；正常的不占地方。
private struct JobStatusLine: View {
    let job: ScheduleReport.ScheduledJob
    var showsNext = true

    var body: some View {
        if let text = Self.problem(job) {
            Text(text).font(.footnote).foregroundStyle(job.lastStatus == "running" ? Palette.blue : Palette.red)
        } else if showsNext {
            Text(Self.next(job)).font(.footnote).monospacedDigit().foregroundStyle(Palette.secondary)
        }
    }

    static func next(_ job: ScheduleReport.ScheduledJob) -> String {
        guard let text = job.nextRunAt, let date = BeijingTime.parseISO(text) else { return "—" }
        return "\(BeijingDay.title(date)) \(BeijingTime.clock(date))"
    }

    static func problem(_ job: ScheduleReport.ScheduledJob) -> String? {
        let detail = job.lastDetail.flatMap { $0.isEmpty ? nil : $0 }
        switch job.lastStatus {
        case "running": return "运行中"
        case "failed": return detail.map { "上次失败：\($0)" } ?? "上次失败"
        case "missed": return detail ?? "上次错过了"
        case "timeout", "timeout_stopping", "timeout_killed": return "上次超时"
        default: return nil
        }
    }
}

// MARK: - iOS 签名

private struct SigningDetailView: View {
    @Environment(AppStore.self) private var store
    @State private var isConfirming = false

    private var resign: ResignStatus? { store.snapshot?.resign }

    private var isLAN: Bool {
        if case .online(.lan, _) = store.connection { return true }
        return false
    }

    private var isRunning: Bool { resign?.status == "running" || store.isRequestingResign }

    var body: some View {
        Form {
            if let resign, let expiry = Self.date(resign.expirationDate) {
                Section {
                    LabeledContent("到期") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(expiry > Date() ? BeijingDay.remaining(until: expiry) : "已过期")
                                .foregroundStyle(expiry > Date() ? Color.primary : Palette.red)
                            Text(Self.stamp(expiry)).font(.footnote).monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    if let signed = Self.date(resign.lastSignedAt) {
                        LabeledContent("上次签名", value: Self.stamp(signed))
                    }
                }
                attempt(resign)
            } else {
                ContentUnavailableView("还没有签名记录", systemImage: "checkmark.seal")
            }
            Section {
                Button {
                    isConfirming = true
                } label: {
                    HStack {
                        Text(resign?.status == "running" ? "正在续签" : "立即续签")
                        Spacer()
                        if isRunning { ProgressView() }
                    }
                }
                .disabled(!store.canWrite || !isLAN || isRunning)
            } footer: {
                if store.canWrite, !isLAN {
                    Text("连上家里的 Wi-Fi 才能续签")
                }
            }
        }
        .navigationTitle("iOS 签名")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("现在续签？", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("续签") { Task { await store.requestResign() } }
        } message: {
            Text("装新版时 App 会退出，几分钟后重新打开。")
        }
    }

    /// 上次没续上才出现：失败给原因，暂时不行给在等什么。
    @ViewBuilder private func attempt(_ resign: ResignStatus) -> some View {
        if resign.status == "failed", let error = resign.lastError, !error.isEmpty {
            Section {
                Text(error).foregroundStyle(Palette.red)
                if let at = Self.date(resign.lastAttemptAt) {
                    LabeledContent("上次尝试", value: Self.stamp(at))
                }
            }
        } else if resign.status == "due", let detail = resign.lastProbeDetail, !detail.isEmpty {
            Section("自动续签") {
                LabeledContent(detail, value: Self.date(resign.lastProbeAt).map(Self.stamp) ?? "")
            }
        }
    }

    private static func date(_ text: String?) -> Date? {
        text.flatMap(BeijingTime.parseISO)
    }

    private static func stamp(_ date: Date) -> String {
        "\(BeijingDay.title(date)) \(BeijingTime.clock(date))"
    }
}
