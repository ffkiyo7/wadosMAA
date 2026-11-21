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
                    connectionCard
                    entries
                    #if DEBUG
                    demoCard
                    #endif
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .connectionBanner()
            .navigationTitle("设置")
            .navigationDestination(isPresented: $store.isConnectionDetailPresented) {
                ConnectionDetailView()
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .push: PushDetailView()
                case .resources: ResourceDetailView()
                case .scheduler: SchedulerDetailView()
                case .signing: SigningDetailView()
                case .advanced: AdvancedPlaceholderView()
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
            .font(.system(size: 26, weight: .medium))
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
                Text("\(latency)").font(.system(size: 34, weight: .heavy)).monospacedDigit()
                Text("ms")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
            }
        } else {
            Text("—").font(.system(size: 34, weight: .heavy))
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
        guard let text = store.snapshot?.resign?.expirationDate, let date = BeijingTime.parseISO(text) else {
            return nil
        }
        return BeijingDay.remaining(until: date)
    }

    // MARK: - 演示

    #if DEBUG
    private var demoCard: some View {
        WCard(vertical: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text("演示数据")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                    .padding(.vertical, 6)
                ForEach(DemoScenario.allCases) { scenario in
                    Button {
                        store.startDemo(scenario)
                    } label: {
                        HStack {
                            Text(scenario.title).font(.system(size: 16))
                            Spacer()
                            if store.demoScenario == scenario {
                                Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                if store.demoScenario != nil {
                    Button("退出演示", role: .destructive) { store.stopDemo() }
                        .frame(minHeight: 44)
                }
            }
        }
    }
    #endif
}

private struct EntryRow: View {
    let symbol: String
    let title: String
    var value: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 24)
            Text(title).font(.system(size: 16))
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.system(size: 16))
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
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

// MARK: - 调度器（只读，启停在 Phase 4）

private struct SchedulerDetailView: View {
    @Environment(AppStore.self) private var store

    private static let names: [String: String] = [
        "plan_card_am": "早场计划", "daily_am": "早场日常", "plan_card_pm": "晚场计划", "daily_pm": "晚场日常",
        "activity_watch": "活动监控", "depot": "仓库对表",
    ]
    private static let order = ["plan_card_am", "daily_am", "plan_card_pm", "daily_pm", "activity_watch", "depot"]

    private var jobs: [ScheduleReport.ScheduledJob] {
        let values = store.snapshot?.schedule?.jobs ?? [:]
        let known = Self.order.compactMap { values[$0] }
        let others = values.values.filter { !Self.order.contains($0.id) }.sorted { $0.id < $1.id }
        return known + others
    }

    var body: some View {
        Form {
            if jobs.isEmpty {
                ContentUnavailableView("读不到调度器", systemImage: "clock")
            } else {
                Section {
                    ForEach(jobs, id: \.id) { job in
                        HStack {
                            Text(Self.names[job.id] ?? job.id)
                                .foregroundStyle(job.enabled ? Color.primary : Palette.secondary)
                            Spacer()
                            Text(nextText(job))
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("调度器")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func nextText(_ job: ScheduleReport.ScheduledJob) -> String {
        guard job.enabled else { return "关闭" }
        guard let text = job.nextRunAt, let date = BeijingTime.parseISO(text) else { return "—" }
        return "\(BeijingDay.title(date)) \(BeijingTime.clock(date))"
    }
}

// MARK: - iOS 签名（只读，续签在 Phase 4）

private struct SigningDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            if let resign = store.snapshot?.resign {
                Section {
                    row("到期", resign.expirationDate)
                    row("上次签名", resign.lastSignedAt)
                    row("上次尝试", resign.lastAttemptAt)
                    if let error = resign.lastError, !error.isEmpty {
                        Text(error).foregroundStyle(Palette.red)
                    }
                }
            } else {
                ContentUnavailableView("还没有签名记录", systemImage: "checkmark.seal")
            }
        }
        .navigationTitle("iOS 签名")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func row(_ title: String, _ text: String?) -> some View {
        if let text, let date = BeijingTime.parseISO(text) {
            LabeledContent(title, value: "\(BeijingDay.title(date)) \(BeijingTime.clock(date))")
        }
    }
}

// MARK: - 高级（占位，Phase 4）

private struct AdvancedPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("高级设置", systemImage: "gearshape")
            .navigationTitle("高级")
            .navigationBarTitleDisplayMode(.inline)
    }
}
