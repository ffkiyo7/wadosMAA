//
//  AppStore+Actions.swift
//  Wado's MAA (iOS)
//
//  页面的所有读写都从这里走。写操作在连接异常时直接拒绝。
//

import Foundation
import UIKit
import WadosMAAShared

enum StartRunOutcome: Equatable {
    case started
    /// 定时场快到了，需要用户再确认一次才能强开。
    case needsForce(String)
    case failed
}

enum CopilotPreviewOutcome {
    case loaded(CopilotPreview)
    case failed(String)
    case canceled
}

extension AppStore {
    // MARK: - 通用

    @discardableResult
    func write(
        _ path: String, method: HTTPMethod = .post, body: [String: any Sendable]? = [:],
        timeout: TimeInterval = 30, quietCodes: Set<String> = []
    ) async -> RemoteReceipt? {
        guard canWrite, let transport else {
            showToast(AppToast(text: "连接恢复后才能操作"))
            return nil
        }
        do {
            let receipt = try await transport.send(method, path, body: body, timeout: timeout)
            if !receipt.ok, !quietCodes.contains(receipt.code) {
                showToast(AppToast(text: receipt.message.isEmpty ? "没改成，稍后再试" : receipt.message))
            }
            return receipt
        } catch TransportFailure.unauthorized {
            markTokenInvalid()
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            showToast(AppToast(text: "没改成，稍后再试"))
            reconnect()
            return nil
        }
    }

    private func readData(_ path: String, query: [URLQueryItem] = []) async -> Data? {
        guard let transport else { return nil }
        let epoch = dataEpoch
        do {
            let data = try await transport.read(path, query: query)
            return epoch == dataEpoch ? data : nil
        } catch TransportFailure.unauthorized {
            markTokenInvalid()
            return nil
        } catch {
            return nil
        }
    }

    private func writeAndRefresh(_ path: String, body: [String: any Sendable]) async {
        if await write(path, body: body)?.ok == true {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            await refreshSnapshot()
        }
    }

    // MARK: - 今天的计划

    func setStage(phase: String, stage: String) async {
        await writeAndRefresh("/api/v1/plan/stage", body: ["phase": phase, "stage": stage])
    }

    func setAutoStage(phase: String) async {
        await writeAndRefresh("/api/v1/plan/stage", body: ["phase": phase, "auto": true])
    }

    func setSkip(phase: String, skip: Bool) async {
        await writeAndRefresh("/api/v1/plan/skip", body: ["phase": phase, "skip": skip])
    }

    func setFight(phase: String, fight: Bool) async {
        await writeAndRefresh("/api/v1/plan/fight", body: ["phase": phase, "fight": fight])
    }

    // MARK: - 手动开一场

    func refreshChoices() async {
        guard let data = await readData("/api/v1/choices"),
            let value = try? JSONDecoder().decode(RunChoices.self, from: data)
        else { return }
        choices = value
        remember(\.choices, data)
    }

    func startRun(stage: String, switches: [String: Bool], force: Bool) async -> StartRunOutcome {
        var body: [String: any Sendable] = ["stage": stage, "switches": switches]
        if force { body["force"] = true }
        guard let receipt = await write("/api/v1/run/local", body: body, quietCodes: ["session_soon"]) else {
            return .failed
        }
        if receipt.code == "session_soon" { return .needsForce(receipt.message) }
        guard receipt.ok else { return .failed }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await refreshSnapshot()
        showToast(AppToast(text: "已开始", actionTitle: "查看", action: .showRun))
        return .started
    }

    // MARK: - 游戏资源

    func updateResources() async {
        guard !isUpdatingResources else { return }
        isUpdatingResources = true
        defer { isUpdatingResources = false }
        // 服务端受理后在后台更新，进度由 upstream 事件推到提示条。
        await write("/api/v1/upstream/update")
        await refreshSnapshot()
    }

    // MARK: - 历史与战报

    func history(kind: String?, offset: Int, limit: Int = 30) async -> HistoryPage? {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let kind { query.append(URLQueryItem(name: "kind", value: kind)) }
        return await readData("/api/v1/history", query: query).flatMap(HistoryPage.init(data:))
    }

    func runReport(id: String) async -> RunReport? {
        await readData("/api/v1/runs/\(id)/report").flatMap(RunReport.init(data:))
    }

    func runLog(id: String) async -> RunLogTail? {
        guard let data = await readData("/api/v1/runs/\(id)/log", query: [URLQueryItem(name: "tail", value: "200")])
        else { return nil }
        return try? JSONDecoder().decode(RunLogTail.self, from: data)
    }

    func runScreenshot(id: String, thumbnail: Bool) async -> UIImage? {
        let query = thumbnail ? [URLQueryItem(name: "thumb", value: "1")] : []
        return await readData("/api/v1/runs/\(id)/screenshot", query: query).flatMap(UIImage.init(data:))
    }

    // MARK: - 抄作业

    var copilotAutoEnabled: Bool {
        !(snapshot?.copilotAutoPaused ?? false)
    }

    func setCopilotAuto(_ enabled: Bool) async {
        await writeAndRefresh("/api/v1/copilot/auto", body: ["enabled": enabled])
    }

    func markCopilot(stage: String, cleared: Bool) async {
        var body: [String: any Sendable] = ["stage": stage, "cleared": cleared]
        if cleared { body["mode"] = "all" }
        await writeAndRefresh("/api/v1/copilot/mark", body: body)
    }

    func previewCopilot(stage: String, requestID: String) async -> CopilotPreviewOutcome {
        guard canWrite, let transport else { return .failed("连接恢复后才能搜作业") }
        do {
            let receipt = try await transport.send(
                .post, "/api/v1/copilot/preview", body: ["stage": stage, "request_id": requestID], timeout: 70)
            if receipt.code == "preview_canceled" { return .canceled }
            guard receipt.ok else {
                return .failed(receipt.message.isEmpty ? "没搜到作业，稍后再试" : receipt.message)
            }
            guard let preview = try? receipt.decoded(CopilotPreview.self, snakeCase: false) else {
                return .failed("没读懂搜索结果")
            }
            return .loaded(preview)
        } catch TransportFailure.unauthorized {
            markTokenInvalid()
            return .failed("Token 失效")
        } catch is CancellationError {
            return .canceled
        } catch {
            return Task.isCancelled ? .canceled : .failed("没搜到作业，稍后再试")
        }
    }

    /// 取消进行中的搜索或清理预览临时文件；失败不打扰用户，服务端有 TTL 兜底。
    func cancelPreview(requestID: String) async {
        guard let transport else { return }
        _ = try? await transport.send(.delete, "/api/v1/copilot/preview/\(requestID)", body: nil, timeout: 10)
    }

    func goCopilot(token: String, candidateID: Int) async -> Bool {
        guard let receipt = await write(
            "/api/v1/copilot/go", body: ["token": token, "candidate_id": candidateID], timeout: 30),
            receipt.ok
        else { return false }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        await refreshSnapshot()
        return true
    }

    // MARK: - 配置

    func loadSettings() async {
        if let data = await readData("/api/v1/config"),
            let value = try? JSONDecoder().decode(ConfigSnapshot.self, from: data)
        {
            settings = value
            remember(\.config, data)
        }
        if let data = await readData("/api/v1/defaults"),
            let value = try? JSONDecoder().decode(DefaultsSnapshot.self, from: data)
        {
            dailyDefaults = value
            remember(\.defaults, data)
        }
    }

    func configField(_ key: String) -> ConfigField? {
        settings?.fields.first { $0.key == key }
    }

    func configValue(_ key: String) -> JSONValue? {
        configOverrides[key] ?? settings?.values[key] ?? configField(key)?.default
    }

    func configInt(_ key: String, fallback: Int) -> Int {
        configValue(key)?.number.map { Int($0) } ?? fallback
    }

    func configBool(_ key: String) -> Bool {
        configValue(key)?.bool ?? false
    }

    func configList(_ key: String) -> [String] {
        configValue(key)?.array?.compactMap(\.string) ?? []
    }

    func configRange(_ key: String, fallback: ClosedRange<Int>) -> ClosedRange<Int> {
        guard let field = configField(key), let low = field.min, let high = field.max, low <= high else {
            return fallback
        }
        return Int(low)...Int(high)
    }

    /// 控件先变，网络后到；步进器连按时用 `debounce` 只发最后一次。
    func changeConfig(_ key: String, to value: JSONValue, toast: String? = nil, debounce: Duration? = nil) {
        guard canWrite else {
            showToast(AppToast(text: "连接恢复后才能操作"))
            return
        }
        let original = configOriginals[key] ?? configValue(key)
        configOriginals[key] = original
        configOverrides[key] = value
        configTasks[key]?.cancel()
        configTasks[key] = Task { [weak self] in
            if let debounce {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            await self?.commitConfig(key, value, original: original, toast: toast)
        }
    }

    private func commitConfig(_ key: String, _ value: JSONValue, original: JSONValue?, toast: String?) async {
        let receipt = await write("/api/v1/config", body: ["key": key, "value": Self.sendable(value)])
        guard !Task.isCancelled else { return }
        configOriginals[key] = nil
        if receipt?.ok == true {
            await loadSettings()
            if let toast, let original, original != value {
                showToast(
                    AppToast(text: toast, actionTitle: "撤销", action: .undoConfig(key: key, value: original)),
                    lifetime: .seconds(6))
            }
        }
        if configOverrides[key] == value { configOverrides[key] = nil }
    }

    private static func sendable(_ value: JSONValue) -> any Sendable {
        switch value {
        case let .bool(item): item
        case let .number(item): item.rounded() == item ? Int(item) : item
        case let .string(item): item
        case let .array(items): items.compactMap(\.string)
        case .object, .null: ""
        }
    }

    func defaultTask(_ task: String) -> Bool {
        defaultTaskOverrides[task] ?? dailyDefaults?.tasks?[task] ?? true
    }

    func setDefaultStage(_ stage: String, undoable: Bool = true) async {
        let previous = dailyDefaults?.stage ?? ""
        guard await write("/api/v1/defaults", body: ["stage": stage])?.ok == true else { return }
        await loadSettings()
        await refreshSnapshot()
        if undoable, previous != stage {
            showToast(
                AppToast(
                    text: "默认关卡改为 \(stage.isEmpty ? "上次的关" : stage)", actionTitle: "撤销",
                    action: .undoDefaultStage(previous)),
                lifetime: .seconds(6))
        }
    }

    func setDefaultTask(_ task: String, enabled: Bool, undoable: Bool = true) async {
        let previous = defaultTask(task)
        defaultTaskOverrides[task] = enabled
        let ok = await write("/api/v1/defaults", body: ["task": task, "enabled": enabled])?.ok == true
        if ok {
            await loadSettings()
            await refreshSnapshot()
        }
        defaultTaskOverrides[task] = nil
        if ok, undoable, previous != enabled {
            let name = DailyTaskName.title(task)
            showToast(
                AppToast(
                    text: "\(name)已\(enabled ? "打开" : "关闭")", actionTitle: "撤销",
                    action: .undoDefaultTask(task, previous)),
                lifetime: .seconds(6))
        }
    }

    // MARK: - 时间表

    func setSessionTime(phase: String, time: String) async {
        await writeAndRefresh("/api/v1/schedule", body: ["phase": phase, "time": time])
    }

    func setSessionEnabled(phase: String, enabled: Bool) async {
        await writeAndRefresh("/api/v1/schedule", body: ["phase": phase, "enabled": enabled])
    }

    // MARK: - 推送

    func sendTestPush() async {
        guard !isSendingTestPush else { return }
        isSendingTestPush = true
        defer { isSendingTestPush = false }
        if let receipt = await write("/api/v1/notify/test"), receipt.ok {
            showToast(AppToast(text: receipt.message.isEmpty ? "已发送" : receipt.message))
        }
    }
}

enum DailyTaskName {
    static func title(_ task: String) -> String {
        switch task {
        case "fight": "刷理智"
        case "annihilation": "剿灭"
        case "infrast": "基建"
        case "recruit": "公招"
        case "mall": "信用商店"
        case "award": "领奖"
        default: task
        }
    }

    static func symbol(_ task: String) -> String {
        switch task {
        case "fight": DailyStep.fight.symbol
        case "annihilation": DailyStep.annihilation.symbol
        case "infrast": DailyStep.infrast.symbol
        case "recruit": DailyStep.recruit.symbol
        case "mall": DailyStep.mall.symbol
        default: DailyStep.award.symbol
        }
    }
}
