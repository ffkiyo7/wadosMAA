//
//  AppStore.swift
//  Wado's MAA (iOS)
//
//  全局状态：连接、快照、SSE、运行中的那一场和导航。页面只读它，写操作都经过它。
//

import Foundation
import Network
import Observation
import SwiftUI
import UIKit
import WadosMAAShared

enum AppTab: Hashable {
    case today, copilot, daily, settings
}

enum ConnectionState: Equatable {
    case connecting
    case online(TransportRoute, latency: Int)
    case offline
    case tokenInvalid
    case certificateMismatch
    case tunnelDown

    var isOnline: Bool {
        if case .online = self { true } else { false }
    }
}

struct AppToast: Identifiable, Equatable {
    enum Action: Equatable {
        case showRun
        case undoConfig(key: String, value: JSONValue)
        case undoDefaultStage(String)
        case undoDefaultTask(String, Bool)
    }

    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: Action?
}

/// 打开某一场的详情。
struct RunRoute: Identifiable, Hashable {
    let id: String
}

struct RunChangedNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor @Observable final class AppStore {
    // 导航
    var selectedTab: AppTab = .today
    var isRunSheetPresented = false
    var isStopConfirmationPresented = false
    var isPairingPresented = false
    var isConnectionDetailPresented = false
    var runChangedNotice: RunChangedNotice?
    var isStartRunPresented = false
    var runDetailRoute: RunRoute?

    // 连接
    private(set) var config: ConnectionConfig?
    private(set) var connection: ConnectionState = .connecting
    /// 局域网指纹没对上、已经走了远程。
    private(set) var lanPinMismatch = false
    private(set) var isTestingConnection = false

    // 数据
    private(set) var snapshot: RemoteSnapshot?
    private(set) var copilotStages: CopilotStages?
    private(set) var lastUpdatedAt: Date?
    private(set) var isStopping = false
    private(set) var toast: AppToast?
    var recentRuns: [RunRecord] = []
    var choices: RunChoices?
    var settings: ConfigSnapshot?
    var dailyDefaults: DefaultsSnapshot?
    /// 已改、还没等到回执的值：控件先显示它，失败再退回。
    var configOverrides: [String: JSONValue] = [:]
    var defaultTaskOverrides: [String: Bool] = [:]
    var isUpdatingResources = false
    var isSendingTestPush = false

    #if DEBUG
    private(set) var demoScenario: DemoScenario?
    #endif

    @ObservationIgnored private(set) var transport: (any BackendTransport)?
    @ObservationIgnored var configTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var configOriginals: [String: JSONValue] = [:]
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPathDescription: String?
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var pendingRunLink: DeepLink?

    var needsPairing: Bool {
        config == nil
    }

    var activeRun: ActiveRun? {
        guard let lock = snapshot?.lock else { return nil }
        return ActiveRun(lock: lock, progress: snapshot?.progress)
    }

    /// 连不上时页面照常显示旧数据，但所有写操作都禁用。
    var canWrite: Bool {
        connection.isOnline
    }

    /// 抄作业角标：当期还没通的关。
    var copilotRemaining: Int {
        guard let stages = copilotStages, stages.inActivity else { return 0 }
        return stages.stages.filter { $0.status != "cleared" }.count
    }

    var hasData: Bool {
        snapshot != nil
    }

    // MARK: - 启动与生命周期

    func start() {
        guard transport == nil, connectionTask == nil else { return }
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["WADOS_DEMO"], let scenario = DemoScenario(rawValue: name) {
            startDemo(scenario)
            return
        }
        #endif
        guard let config = ConnectionConfig.load(), let credentials = ConnectionCredentials.load() else { return }
        self.config = config
        transport = HTTPTransport(config: config, credentials: credentials)
        startPathMonitor()
        reconnect()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            guard !isForeground else { return }
            isForeground = true
            reconnect()
        case .background:
            isForeground = false
            connectionTask?.cancel()
            connectionTask = nil
        default:
            break
        }
    }

    func reconnect() {
        guard isForeground, let transport else { return }
        connectionTask?.cancel()
        if !connection.isOnline { connection = .connecting }
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(transport)
        }
    }

    private func connectionLoop(_ transport: any BackendTransport) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let probe = try await transport.probe()
                try Task.checkCancellation()
                lanPinMismatch = probe.lanPinMismatch
                connection = .online(probe.route, latency: probe.latencyMilliseconds)
                // SSE 只推变化：每次（重新）连上都先拉一次全量。
                try await reloadAll(transport)
                failures = 0
                let stream = try await transport.events()
                for try await event in stream {
                    try Task.checkCancellation()
                    apply(event, transport: transport)
                }
            } catch is CancellationError {
                return
            } catch let failure as TransportFailure {
                guard !Task.isCancelled else { return }
                switch failure {
                case .unauthorized:
                    connection = .tokenInvalid
                    return  // 重试没用，等重新配对。
                case .certificateMismatch: connection = .certificateMismatch
                case .tunnelDown: connection = .tunnelDown
                case .offline, .badResponse: connection = .offline
                }
            } catch {
                guard !Task.isCancelled else { return }
                // SSE 流断开：回到探测，判断要不要切轨。
                connection = .connecting
            }
            failures += 1
            let delay = min(30.0, pow(2.0, Double(min(failures, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func reloadAll(_ transport: any BackendTransport) async throws {
        let data = try await transport.read("/api/v1/snapshot", query: [])
        guard let fresh = RemoteSnapshot(data: data) else { throw TransportFailure.badResponse }
        snapshot = fresh
        lastUpdatedAt = Date()
        if let link = pendingRunLink {
            pendingRunLink = nil
            route(link)
        }
        await reloadCopilotStages(transport)
        await reloadSupplementary(transport)
    }

    /// 手动选项和最近场次读不到不影响主流程。
    private func reloadSupplementary(_ transport: any BackendTransport) async {
        if let data = try? await transport.read("/api/v1/choices", query: []),
            let value = try? JSONDecoder().decode(RunChoices.self, from: data)
        {
            choices = value
        }
        let query = [URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "offset", value: "0")]
        if let data = try? await transport.read("/api/v1/history", query: query), let page = HistoryPage(data: data) {
            recentRuns = page.items
        }
    }

    /// 写操作之后、或一场结束时重读：SSE 不推理智、时间表和历史。
    func refreshSnapshot() async {
        guard let transport else { return }
        if let data = try? await transport.read("/api/v1/snapshot", query: []),
            let fresh = RemoteSnapshot(data: data)
        {
            snapshot = fresh
            lastUpdatedAt = Date()
        }
        await reloadCopilotStages(transport)
        await reloadSupplementary(transport)
    }

    func markTokenInvalid() {
        connection = .tokenInvalid
    }

    /// 角标读不到不影响主流程。
    private func reloadCopilotStages(_ transport: any BackendTransport) async {
        guard let data = try? await transport.read("/api/v1/copilot/stages", query: []),
            let stages = try? JSONDecoder().decode(CopilotStages.self, from: data)
        else { return }
        copilotStages = stages
    }

    private func apply(_ event: SSEEvent, transport: any BackendTransport) {
        guard var current = snapshot else { return }
        guard current.apply(event) else { return }
        snapshot = current
        lastUpdatedAt = Date()
        switch event.name {
        case "last_run":
            Task { [weak self] in await self?.refreshSnapshot() }
        case "lock":
            Task { [weak self] in await self?.reloadSupplementary(transport) }
        default:
            break
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let description = "\(path.status)|\(path.availableInterfaces.map(\.name).joined(separator: ","))"
            Task { @MainActor [weak self] in
                self?.pathChanged(description)
            }
        }
        monitor.start(queue: DispatchQueue(label: "wados.path"))
        pathMonitor = monitor
    }

    private func pathChanged(_ description: String) {
        defer { lastPathDescription = description }
        guard let last = lastPathDescription, last != description else { return }
        reconnect()
    }

    // MARK: - 配对

    func completePairing(config: ConnectionConfig, credentials: ConnectionCredentials) -> Bool {
        guard credentials.save() else { return false }
        config.save()
        #if DEBUG
        demoScenario = nil
        #endif
        self.config = config
        clearData()
        connectionTask?.cancel()
        connectionTask = nil
        transport = HTTPTransport(config: config, credentials: credentials)
        connection = .connecting
        startPathMonitor()
        reconnect()
        return true
    }

    /// 配对前试连：只探测，不保存。
    nonisolated static func test(config: ConnectionConfig, credentials: ConnectionCredentials) async -> Result<
        ProbeResult, TransportFailure
    > {
        let candidate = HTTPTransport(config: config, credentials: credentials)
        do {
            let probe = try await candidate.probe()
            _ = try await candidate.read("/api/v1/snapshot", query: [])
            return .success(probe)
        } catch let failure as TransportFailure {
            return .failure(failure)
        } catch {
            return .failure(.offline)
        }
    }

    /// 设置页的「测试」：重新走一遍双轨探测。
    func testConnection() async {
        guard let transport, !isTestingConnection else { return }
        isTestingConnection = true
        defer { isTestingConnection = false }
        let wasOnline = connection.isOnline
        do {
            let probe = try await transport.probe()
            lanPinMismatch = probe.lanPinMismatch
            connection = .online(probe.route, latency: probe.latencyMilliseconds)
        } catch let failure as TransportFailure {
            switch failure {
            case .unauthorized: connection = .tokenInvalid
            case .certificateMismatch: connection = .certificateMismatch
            case .tunnelDown: connection = .tunnelDown
            case .offline, .badResponse: connection = .offline
            }
        } catch {
            connection = .offline
        }
        // 连接循环可能已因失败退出，恢复后重新接上 SSE。
        if connection.isOnline, !wasOnline { reconnect() }
    }

    // MARK: - 停止

    func requestStop() {
        guard activeRun?.canStop == true else { return }
        isStopConfirmationPresented = true
    }

    /// 带 `run_id` 停：服务端发现已经换了一场就回 `run_changed`，绝不误停。
    func confirmStop() async {
        guard !isStopping, let run = activeRun, let runID = run.runID, let transport else { return }
        guard canWrite else {
            showToast(AppToast(text: "连接恢复后才能停止"))
            return
        }
        isStopping = true
        defer { isStopping = false }
        do {
            let receipt = try await transport.send(.post, "/api/v1/run/cancel", body: ["run_id": runID], timeout: 30)
            if receipt.code == "run_changed" {
                try? await reloadAll(transport)
                let current = activeRun?.title
                let message = current.map { "\(run.title)已结束，现在跑的是\($0)" } ?? "\(run.title)已结束"
                runChangedNotice = RunChangedNotice(message: message)
            } else if receipt.ok {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isRunSheetPresented = false
                showToast(AppToast(text: receipt.message.isEmpty ? "正在停止" : receipt.message))
            } else {
                showToast(AppToast(text: receipt.message.isEmpty ? "没能停下，稍后再试" : receipt.message))
            }
        } catch TransportFailure.unauthorized {
            connection = .tokenInvalid
        } catch {
            showToast(AppToast(text: "没能停下，稍后再试"))
            reconnect()
        }
    }

    // MARK: - 提示

    func showToast(_ toast: AppToast, lifetime: Duration = .seconds(4)) {
        toastTask?.cancel()
        self.toast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    func perform(_ action: AppToast.Action) {
        dismissToast()
        switch action {
        case .showRun: showRun()
        case let .undoConfig(key, value): changeConfig(key, to: value)
        case let .undoDefaultStage(stage): Task { await setDefaultStage(stage, undoable: false) }
        case let .undoDefaultTask(task, enabled): Task { await setDefaultTask(task, enabled: enabled, undoable: false) }
        }
    }

    private func clearData() {
        snapshot = nil
        copilotStages = nil
        lastUpdatedAt = nil
        recentRuns = []
        choices = nil
        settings = nil
        dailyDefaults = nil
        configOverrides = [:]
        defaultTaskOverrides = [:]
        configTasks.values.forEach { $0.cancel() }
        configTasks = [:]
        configOriginals = [:]
        runDetailRoute = nil
    }

    func showRun() {
        if activeRun != nil {
            isRunSheetPresented = true
        } else {
            selectedTab = .today
        }
    }

    // MARK: - Deep Link

    func open(_ url: URL) {
        guard let link = DeepLink(url: url) else { return }
        // 冷启动点推送时快照还没到，等第一份数据再判断这一场是否还在跑。
        if snapshot == nil {
            switch link {
            case .latestRun, .run:
                pendingRunLink = link
                return
            default:
                break
            }
        }
        route(link)
    }

    private func route(_ link: DeepLink) {
        switch link {
        case .latestRun:
            if activeRun == nil, let id = snapshot?.lastRun?["run_id"]?.string {
                selectedTab = .today
                runDetailRoute = RunRoute(id: id)
            } else {
                showRun()
            }
        case let .run(id):
            if activeRun?.runID == id {
                isRunSheetPresented = true
            } else {
                isRunSheetPresented = false
                selectedTab = .today
                runDetailRoute = RunRoute(id: id)
            }
        case .today:
            isRunSheetPresented = false
            selectedTab = .today
        case .copilot:
            isRunSheetPresented = false
            selectedTab = .copilot
        case .settings, .resign:
            isRunSheetPresented = false
            selectedTab = .settings
        #if DEBUG
        case let .demo(name):
            if let scenario = DemoScenario(rawValue: name) { startDemo(scenario) }
        #endif
        }
    }

    // MARK: - 演示数据（只在 Debug 构建里有）

    #if DEBUG
    func startDemo(_ scenario: DemoScenario) {
        connectionTask?.cancel()
        connectionTask = nil
        demoScenario = scenario
        isRunSheetPresented = false
        isPairingPresented = false
        dismissToast()
        clearData()
        lanPinMismatch = false
        config = DemoTransport.config
        connection = .connecting
        let transport = DemoTransport(scenario: scenario)
        self.transport = transport
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(transport)
        }
    }

    func stopDemo() {
        connectionTask?.cancel()
        connectionTask = nil
        demoScenario = nil
        transport = nil
        clearData()
        config = nil
        connection = .connecting
        dismissToast()
        start()
    }
    #endif
}
