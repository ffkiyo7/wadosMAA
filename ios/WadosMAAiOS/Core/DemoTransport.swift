//
//  DemoTransport.swift
//  Wado's MAA (iOS)
//
//  Debug 构建专用的假后端：不连 Mac mini、不动游戏，用来在模拟器里验收各种状态。
//  字段形状对照 `feat/decouple-p3-backend`（maa_api.py / maa_copilot_worker.py / maa_plan_card.py）。
//  Release 构建不包含这个文件的内容。
//

#if DEBUG
import Foundation
import UIKit
import WadosMAAShared

enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
    case idle
    case daily
    case copilot
    case skipped
    case closed
    case failed
    case sessionSoon = "session-soon"
    case resourceBlocked = "resource-blocked"
    case resourceStale = "resource-stale"
    case resourceRunning = "resource-running"
    case noActivity = "no-activity"
    case missingFields = "missing-fields"
    case loading
    case offline
    case token
    case certificate
    case tunnel
    case runChanged = "run-changed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "空闲"
        case .daily: "日常运行中"
        case .copilot: "抄作业运行中"
        case .skipped: "晚场已跳过"
        case .closed: "晚场已关闭"
        case .failed: "晚场没打完"
        case .sessionSoon: "定时场前强开"
        case .resourceBlocked: "资源必须更新"
        case .resourceStale: "资源有更新"
        case .resourceRunning: "资源更新中"
        case .noActivity: "没有活动"
        case .missingFields: "旧后端（缺新字段）"
        case .loading: "加载中"
        case .offline: "离线"
        case .token: "Token 失效"
        case .certificate: "证书不匹配"
        case .tunnel: "隧道不通"
        case .runChanged: "停止时已换场"
        }
    }
}

actor DemoTransport: BackendTransport {
    nonisolated static let config = ConnectionConfig(
        lanURL: URL(string: "https://192.168.50.2:18170")!,
        remoteURL: URL(string: "https://maa.example.com")!,
        primaryPin: Data(repeating: 7, count: 32).base64EncodedString(),
        backupPin: "")

    private let scenario: DemoScenario
    private var running: Bool
    private var step = 3
    private var copilotDone = 1
    private var hasConnectedOnce = false
    /// 正在跑的是抄作业（场景本身，或「停止时已换场」/ 预览开打之后）。
    private var showsCopilot: Bool
    private var isManualRun = false
    private var lockCleared = false
    private var startedAt = Date().addingTimeInterval(-11 * 60)

    // 可改的演示状态
    private var pmStage = "TL-9"
    private var pmSource = "auto"
    private var pmSkip: Bool
    private var pmEnabled: Bool
    private var amEnabled = true
    private var pmFight = true
    private var amTime = "08:00"
    private var pmTime = "22:00"
    private var copilotPaused = false
    private var verdict: String
    private var resourceUpdating: Bool
    private var resourceFinishesAt: Date?
    private var defaultStage = "TL-9"
    private var defaultTasks = ["fight": true, "infrast": true, "recruit": true, "mall": true, "award": true]
    private var defaultsMeta = ("ios", "")
    private var values: [String: Any] = [
        "medicine_expire_days": 3, "recruit_times": 4, "annihilation_sanity": 25, "report_drops": true,
        "award_orundum": true, "award_mining": true, "award_specialaccess": false,
        "mall_buy_first": ["招聘许可", "龙门币", "赤金", "碳素组"], "mall_blacklist": ["家具零件", "加急许可"],
        "mall_reserve_max_credit": true, "mall_only_buy_discount": false, "manual_run_blackout_minutes": 30,
        "copilot_blackout_minutes": 25, "auto_copilot_min_lead_minutes": 40, "activity_search_retry_minutes": 30,
        "auto_copilot_max_attempts_per_day": 2,
    ]
    private var configMeta: [String: [String: String]] = [:]
    private var stageRows: [[String: Any]]

    private var hasNewFields: Bool { scenario != .missingFields }

    init(scenario: DemoScenario) {
        self.scenario = scenario
        running = [.daily, .copilot, .runChanged].contains(scenario)
        showsCopilot = scenario == .copilot
        pmSkip = scenario == .skipped
        pmEnabled = scenario != .closed
        switch scenario {
        case .resourceBlocked: verdict = "blocked"
        case .resourceStale: verdict = "stale"
        case .resourceRunning: verdict = "running"
        default: verdict = "ok"
        }
        resourceUpdating = scenario == .resourceRunning
        lockCleared = !running
        stageRows = Self.makeStageRows(includeCategory: scenario != .missingFields)
        let now = Self.isoString(Date().addingTimeInterval(-25 * 60))
        defaultsMeta = ("ios", now)
        configMeta = ["medicine_expire_days": ["source": "ios", "updated_at": now]]
    }

    func probe() async throws -> ProbeResult {
        // 连接异常的场景先给一份数据，横幅才有「xx:xx 的数据」可显示。
        if !hasConnectedOnce, [.offline, .token, .certificate, .tunnel].contains(scenario) {
            hasConnectedOnce = true
            return ProbeResult(route: .lan, latencyMilliseconds: 12, lanPinMismatch: false)
        }
        switch scenario {
        case .offline: throw TransportFailure.offline
        case .certificate: throw TransportFailure.certificateMismatch
        case .tunnel: throw TransportFailure.tunnelDown
        case .token: throw TransportFailure.unauthorized
        case .loading:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        default:
            return ProbeResult(route: .lan, latencyMilliseconds: 12, lanPinMismatch: false)
        }
    }

    func read(_ path: String, query: [URLQueryItem]) async throws -> Data {
        switch path {
        case "/api/v1/snapshot": return try encode(snapshotObject())
        case "/api/v1/copilot/stages": return try encode(stagesObject())
        case "/api/v1/choices": return try encode(choicesObject())
        case "/api/v1/config": return try encode(configObject())
        case "/api/v1/defaults": return try encode(defaultsObject())
        case "/api/v1/history": return try encode(historyObject(query))
        default: break
        }
        if path.hasPrefix("/api/v1/runs/") {
            let parts = path.dropFirst("/api/v1/runs/".count).split(separator: "/").map(String.init)
            guard parts.count == 2 else { throw TransportFailure.badResponse }
            switch parts[1] {
            case "report": return try encode(reportObject(id: parts[0]))
            case "log": return try encode(["lines": Self.logLines, "truncated": true])
            case "screenshot": return await Self.screenshotData()
            default: break
            }
        }
        throw TransportFailure.badResponse
    }

    func send(
        _ method: HTTPMethod, _ path: String, body: [String: any Sendable]?, timeout: TimeInterval
    ) async throws -> RemoteReceipt {
        if path == "/api/v1/copilot/preview" {
            try await Task.sleep(for: .milliseconds(1400))
            return previewReceipt(stage: body?["stage"] as? String ?? "TL-10")
        }
        try await Task.sleep(for: .milliseconds(350))
        if method == .delete {
            return ok("preview_canceled", "已取消")
        }
        switch path {
        case "/api/v1/run/cancel": return cancelRun()
        case "/api/v1/run/local": return startLocal(body)
        case "/api/v1/plan/stage":
            if body?["auto"] as? Bool == true {
                pmStage = "TL-9"
                pmSource = "auto"
            } else if let stage = body?["stage"] as? String {
                pmStage = stage
                pmSource = "discord"
            }
            return ok("stage_set", "已换关")
        case "/api/v1/plan/skip":
            pmSkip = body?["skip"] as? Bool ?? pmSkip
            return ok("skip_set", pmSkip ? "已跳过" : "已恢复")
        case "/api/v1/plan/fight":
            pmFight = body?["fight"] as? Bool ?? pmFight
            return ok("fight_set", "已保存")
        case "/api/v1/copilot/auto":
            copilotPaused = !(body?["enabled"] as? Bool ?? !copilotPaused)
            return ok("auto_set", copilotPaused ? "自动抄作业已暂停" : "自动抄作业已打开")
        case "/api/v1/copilot/mark": return markStage(body)
        case "/api/v1/copilot/go": return startCopilot()
        case "/api/v1/schedule": return setSchedule(body)
        case "/api/v1/defaults": return setDefaults(body)
        case "/api/v1/config": return setConfig(body)
        case "/api/v1/upstream/update":
            resourceUpdating = true
            resourceFinishesAt = Date().addingTimeInterval(6)
            return ok("update_started", "开始更新游戏资源")
        case "/api/v1/notify/test":
            return hasNewFields
                ? ok("notify_sent", "测试推送已发送")
                : RemoteReceipt(ok: false, code: "notify_failed", message: "Bark 没配置", detail: nil, data: nil)
        default:
            return RemoteReceipt(ok: false, code: "failed", message: "演示数据不支持这个操作", detail: nil, data: nil)
        }
    }

    func events() async throws -> AsyncThrowingStream<SSEEvent, Error> {
        if [.offline, .token, .certificate, .tunnel].contains(scenario) {
            // 给完第一份数据马上断开，进入对应的异常状态。
            throw TransportFailure.offline
        }
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, let self else { break }
                    for event in await self.tick() { continuation.yield(event) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 写操作

    private func ok(_ code: String, _ message: String) -> RemoteReceipt {
        RemoteReceipt(ok: true, code: code, message: message, detail: nil, data: nil)
    }

    private func cancelRun() -> RemoteReceipt {
        if scenario == .runChanged, !showsCopilot {
            showsCopilot = true
            return RemoteReceipt(ok: false, code: "run_changed", message: "运行已变化", detail: nil, data: nil)
        }
        running = false
        return ok("cancelled", "正在停止")
    }

    private func startLocal(_ body: [String: any Sendable]?) -> RemoteReceipt {
        if running {
            return RemoteReceipt(ok: false, code: "busy", message: "游戏正被占用", detail: nil, data: nil)
        }
        if scenario == .sessionSoon, body?["force"] as? Bool != true {
            return RemoteReceipt(
                ok: false, code: "session_soon", message: "晚场 12 分钟后开跑", detail: nil, data: nil)
        }
        beginRun(copilot: false, manual: true)
        return ok("run_started", "已开始")
    }

    private func startCopilot() -> RemoteReceipt {
        if running {
            return RemoteReceipt(ok: false, code: "busy", message: "游戏正被占用", detail: nil, data: nil)
        }
        beginRun(copilot: true, manual: false)
        return ok("copilot_started", "已开打")
    }

    private func beginRun(copilot: Bool, manual: Bool) {
        running = true
        showsCopilot = copilot
        isManualRun = manual
        lockCleared = false
        startedAt = Date()
        step = 0
        copilotDone = 0
    }

    private func markStage(_ body: [String: any Sendable]?) -> RemoteReceipt {
        guard let stage = body?["stage"] as? String, let cleared = body?["cleared"] as? Bool,
            let index = stageRows.firstIndex(where: { $0["stage"] as? String == stage })
        else { return RemoteReceipt(ok: false, code: "bad_args", message: "参数不对", detail: nil, data: nil) }
        stageRows[index]["status"] = cleared ? "cleared" : "todo"
        stageRows[index]["status_text"] = cleared ? "✅ 已通" : "🕐 待抄"
        stageRows[index]["ledger_cleared"] = cleared
        return ok("marked", cleared ? "已记为通关" : "已撤销")
    }

    private func setSchedule(_ body: [String: any Sendable]?) -> RemoteReceipt {
        guard let phase = body?["phase"] as? String else {
            return RemoteReceipt(ok: false, code: "bad_args", message: "参数不对", detail: nil, data: nil)
        }
        if let time = body?["time"] as? String {
            if phase == "am" { amTime = time } else { pmTime = time }
        }
        if let enabled = body?["enabled"] as? Bool {
            if phase == "am" { amEnabled = enabled } else { pmEnabled = enabled }
        }
        return ok("schedule_saved", "已保存")
    }

    private func setDefaults(_ body: [String: any Sendable]?) -> RemoteReceipt {
        if let stage = body?["stage"] as? String { defaultStage = stage }
        if let task = body?["task"] as? String, let enabled = body?["enabled"] as? Bool {
            defaultTasks[task] = enabled
        }
        defaultsMeta = ("ios", Self.isoString(Date()))
        return ok("defaults_saved", "已保存")
    }

    private func setConfig(_ body: [String: any Sendable]?) -> RemoteReceipt {
        guard let key = body?["key"] as? String, let value = body?["value"] else {
            return RemoteReceipt(ok: false, code: "bad_args", message: "参数不对", detail: nil, data: nil)
        }
        if let list = value as? [String] {
            values[key] = list
        } else if let list = value as? [any Sendable] {
            values[key] = list.compactMap { $0 as? String }
        } else {
            values[key] = value
        }
        configMeta[key] = ["source": "ios", "updated_at": Self.isoString(Date())]
        return ok("config_saved", "已保存")
    }

    // MARK: - 状态推进

    private func tick() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if let finish = resourceFinishesAt, finish <= Date() {
            resourceFinishesAt = nil
            resourceUpdating = false
            verdict = "ok"
            if let data = try? encode(upstreamObject()) {
                events.append(SSEEvent(name: "upstream", data: String(decoding: data, as: UTF8.self)))
            }
        }
        return events + runEvents()
    }

    private func runEvents() -> [SSEEvent] {
        guard running else {
            return lockCleared ? [] : clearLock()
        }
        if showsCopilot {
            copilotDone = copilotDone >= 2 ? 0 : copilotDone + 1
        } else {
            step = step >= 6 ? 2 : step + 1
        }
        guard let data = try? encode(progressObject()) else { return [] }
        return [SSEEvent(name: "progress", data: String(decoding: data, as: UTF8.self))]
    }

    private func clearLock() -> [SSEEvent] {
        lockCleared = true
        var events = [SSEEvent(name: "lock", data: "null")]
        if let data = try? encode(lastRunObject()) {
            events.append(SSEEvent(name: "last_run", data: String(decoding: data, as: UTF8.self)))
        }
        return events
    }

    // MARK: - 数据

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func iso(_ date: Date) -> String {
        Self.isoString(date)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = BeijingTime.zone
        return formatter.string(from: date)
    }

    private var today: String { BeijingDay.key(Date()) }

    private func todayAt(_ time: String) -> Date {
        BeijingDay.date(day: today, time: time) ?? Date()
    }

    private func snapshotObject() -> [String: Any] {
        var object: [String: Any] = [
            "lock": NSNull(),
            "last_run": lastRunObject(),
            "progress": finishedProgress(),
            "today_plan": planObject(),
            "schedule": scheduleObject(),
            "upstream": upstreamObject(),
            "copilot_auto_paused": copilotPaused,
            "activity": NSNull(),
            "scheduler": NSNull(),
            "resign": [
                "status": "ok",
                "last_signed_at": iso(Date().addingTimeInterval(-2 * 86400)),
                "expiration_date": iso(Date().addingTimeInterval(5 * 86400)),
                "last_attempt_at": iso(Date().addingTimeInterval(-2 * 86400)),
            ] as [String: Any],
            "errors": [String: String](),
        ]
        if hasNewFields {
            object["sanity"] = [
                "current": 11, "max": 208,
                "measured_at": iso(todayAt("08:18")),
                "estimated_now": min(11 + max(Int(Date().timeIntervalSince(todayAt("08:18")) / 360), 0), 208),
            ] as [String: Any]
            object["notify"] = ["configured": true]
        }
        if running {
            let holder = showsCopilot ? "copilot" : "daily"
            let detail = showsCopilot ? "TL-EX-7" : isManualRun ? "手动" : "晚"
            object["lock"] = [
                "holder": holder, "detail": detail, "pid": 4242, "since": iso(startedAt),
                "run_id": showsCopilot ? "demo-copilot" : "demo-daily",
            ] as [String: Any]
            object["progress"] = progressObject()
        }
        return object
    }

    private var failedPM: Bool { scenario == .failed }

    private func lastRunObject() -> [String: Any] {
        if failedPM {
            return [
                "status": "failed", "phase": "pm", "run_id": "demo-pm-failed",
                "started_at": iso(todayAt("22:00")),
                "finished_at": iso(todayAt("22:09")),
                "plan": ["stage": "TL-9"],
                "failure": "task_failed",
            ]
        }
        return [
            "status": "success", "phase": "am", "run_id": "demo-am",
            "started_at": iso(todayAt("08:00")),
            "finished_at": iso(todayAt("08:18")),
            "plan": ["stage": "TL-9"],
        ]
    }

    /// 空闲时快照带最近一场的进度文件（`_read_active_progress`）。
    private func finishedProgress() -> Any {
        if failedPM { return finishedDaily(runID: "demo-pm-failed", start: todayAt("22:00"), failedAt: 2) }
        return finishedDaily(runID: "demo-am", start: todayAt("08:00"), failedAt: nil)
    }

    private func finishedDaily(runID: String, start: Date, failedAt: Int?) -> [String: Any] {
        let keys = ["startup", "annihilation", "fight", "infrast", "recruit", "mall", "award"]
        let labels = ["启动游戏", "剿灭", "刷理智", "基建", "公招", "商店", "领奖"]
        let minutes = [2, 3, 5, 2, 2, 2, 2]
        var cursor = start
        var steps: [[String: Any]] = []
        for index in keys.indices {
            var item: [String: Any] = ["key": keys[index], "label": labels[index]]
            if let failedAt, index > failedAt {
                item["state"] = "pending"
            } else {
                item["state"] = index == failedAt ? "failed" : "done"
                item["started_at"] = iso(cursor)
                cursor = cursor.addingTimeInterval(Double(minutes[index]) * 60)
                item["finished_at"] = iso(cursor)
            }
            steps.append(item)
        }
        return [
            "kind": "daily", "run_id": runID, "status": failedAt == nil ? "success" : "failed",
            "started_at": iso(start), "updated_at": iso(cursor), "current": NSNull(), "steps": steps,
            "fight": [
                "done": 5, "estimate": 5, "ap_cost": 21,
                "sanity": ["current": 11, "max": 208],
                "drops": [["name": "电极单元", "count": 5] as [String: Any]],
            ] as [String: Any],
            "notes": failedAt == nil ? [["at": iso(start.addingTimeInterval(90)), "text": "游戏画面丢了，已把游戏窗口摆回来"]] : [],
            "eta": NSNull(),
        ]
    }

    private func choiceObjects() -> [[String: String]] {
        [
            ["label": "TL-9", "stage": "TL-9", "description": "电极单元"],
            ["label": "TL-8", "stage": "TL-8", "description": "固源岩组"],
            ["label": "TL-7", "stage": "TL-7", "description": "研磨石"],
            ["label": "TL-6", "stage": "TL-6", "description": "糖组"],
            ["label": "1-7", "stage": "1-7", "description": "固源岩"],
            ["label": "CE-6", "stage": "CE-6", "description": "龙门币"],
            ["label": "CE-5", "stage": "CE-5", "description": "龙门币"],
            ["label": "CE-4", "stage": "CE-4", "description": "龙门币"],
            ["label": "LS-6", "stage": "LS-6", "description": "作战记录"],
        ]
    }

    private func planObject() -> [String: Any] {
        func session(
            _ phase: String, _ name: String, _ time: String, stage: String, source: String, skip: Bool,
            enabled: Bool, fight: Bool
        ) -> [String: Any] {
            [
                "phase": phase, "name": name, "time": time, "enabled": enabled, "stage": stage,
                "stage_source": source, "skip": skip,
                "tasks": ["fight": fight, "infrast": true, "recruit": true, "mall": true, "award": true],
                "drops": [["item_id": "30012", "name": "电极单元", "count": 5] as [String: Any]],
                "fallback_stage": "1-7", "choices": choiceObjects(),
            ]
        }
        return [
            "date": today,
            "sessions": [
                session("am", "早场", amTime, stage: "TL-9", source: "auto", skip: false, enabled: amEnabled, fight: true),
                session("pm", "晚场", pmTime, stage: pmStage, source: pmSource, skip: pmSkip, enabled: pmEnabled, fight: pmFight),
            ],
            "task_names": ["fight": "刷理智", "infrast": "基建", "recruit": "公招", "mall": "商店", "award": "领奖"],
        ]
    }

    private func scheduleObject() -> [String: Any] {
        func job(_ id: String, _ time: String, enabled: Bool) -> [String: Any] {
            [
                "id": id, "enabled": enabled, "next_run_at": iso(todayAt(time)), "last_run_at": NSNull(),
                "last_status": "ok", "last_detail": NSNull(),
            ]
        }
        func session(_ time: String, _ enabled: Bool) -> [String: Any] {
            ["time": time, "enabled": enabled, "plan_card_time": time, "daily_time": time, "cron": [String: Any]()]
        }
        return [
            "backend": "daemon", "timezone": "Asia/Shanghai", "depot_enabled": false,
            "scheduler_path": "scheduler.json", "jobs_path": "scheduler.json",
            "sessions": ["am": session(amTime, amEnabled), "pm": session(pmTime, pmEnabled)],
            "jobs": [
                "plan_card_am": job("plan_card_am", "07:50", enabled: amEnabled),
                "daily_am": job("daily_am", amTime, enabled: amEnabled),
                "plan_card_pm": job("plan_card_pm", "21:50", enabled: pmEnabled),
                "daily_pm": job("daily_pm", pmTime, enabled: pmEnabled),
                "activity_watch": job("activity_watch", "23:45", enabled: true),
                "depot": job("depot", "04:30", enabled: false),
            ],
        ]
    }

    private func upstreamObject() -> [String: Any] {
        [
            "verdict": verdict, "block_reason": verdict == "blocked" ? "MaaCore 版本和资源不一致" : NSNull(),
            "running": resourceUpdating, "fresh": verdict == "ok",
            "last_success_at": iso(todayAt("04:12")), "game_day_start": iso(todayAt("04:00")),
            "update_blocked": NSNull(),
            "versions": [
                "maa_cli": "0.7.5", "maa_core": "6.20.0", "maa_core_recorded": "6.20.0",
                "resource_last_updated": iso(todayAt("04:12")), "maa_resource_head": "9f3c21ab7d",
            ] as [String: Any],
            "pinned": ["ok": true], "consistent": ["ok": verdict != "blocked"],
            "lock": ["held": false],
        ]
    }

    private func progressObject() -> [String: Any] {
        showsCopilot ? copilotProgress() : dailyProgress()
    }

    private func dailyProgress() -> [String: Any] {
        let keys = ["startup", "annihilation", "fight", "infrast", "recruit", "mall", "award"]
        let labels = ["启动游戏", "剿灭", "刷理智", "基建", "公招", "商店", "领奖"]
        let minutes = [2, 3, 4, 2, 2, 2, 3]
        var cursor = startedAt
        var steps: [[String: Any]] = []
        for index in keys.indices {
            let state = index < step ? "done" : index == step ? "running" : "pending"
            var item: [String: Any] = ["key": keys[index], "label": labels[index], "state": state]
            if index <= step { item["started_at"] = iso(cursor) }
            cursor = cursor.addingTimeInterval(Double(minutes[index]) * 60)
            if index < step { item["finished_at"] = iso(cursor) }
            steps.append(item)
        }
        return [
            "kind": "daily", "run_id": "demo-daily", "status": "running", "started_at": iso(startedAt),
            "updated_at": iso(Date()), "current": keys[step], "steps": steps,
            "fight": [
                "done": 5, "estimate": 5, "ap_cost": 21,
                "sanity": ["current": 11, "max": 208],
                "drops": [["name": "电极单元", "count": 5] as [String: Any]],
            ] as [String: Any],
            "notes": [["at": iso(startedAt.addingTimeInterval(90)), "text": "游戏画面丢了，已把游戏窗口摆回来"]],
            "eta": iso(startedAt.addingTimeInterval(18 * 60)),
        ]
    }

    private func copilotProgress() -> [String: Any] {
        let stages = ["TL-10", "TL-EX-7", "TL-S-3"]
        var steps: [[String: Any]] = []
        for (index, stage) in stages.enumerated() {
            var item: [String: Any] = [
                "key": "\(stage):normal", "label": stage,
                "state": index < copilotDone ? "done" : index == copilotDone ? "running" : "pending",
            ]
            if index <= copilotDone { item["started_at"] = iso(startedAt) }
            if index < copilotDone { item["finished_at"] = iso(startedAt.addingTimeInterval(240)) }
            steps.append(item)
        }
        return [
            "kind": "copilot", "run_id": "demo-copilot", "status": "running", "started_at": iso(startedAt),
            "updated_at": iso(Date()), "current": "\(stages[copilotDone]):normal", "steps": steps,
            "copilot": [
                "done": copilotDone, "total": stages.count, "current_stage": stages[copilotDone],
                "current_mode": "normal", "elapsed_seconds": 540,
            ] as [String: Any],
            "notes": [[String: String]](), "eta": NSNull(),
        ]
    }

    // MARK: 抄作业

    /// 普通 9/12、EX 6/8、S 2/4：未通 7 关覆盖全部状态。
    private static func makeStageRows(includeCategory: Bool) -> [[String: Any]] {
        func row(_ stage: String, _ category: String, _ status: String, _ text: String, ledger: Bool = false) -> [String: Any] {
            var item: [String: Any] = [
                "stage": stage, "code": stage, "nav": status != "no_nav",
                "reason": status == "no_nav" ? text : "", "status": status, "status_text": text,
                "ledger_cleared": ledger, "materials": [String](),
            ]
            if includeCategory { item["category"] = category }
            return item
        }
        var rows: [[String: Any]] = (1...9).map { row("TL-\($0)", "normal", "cleared", "✅ 已通", ledger: $0 >= 7) }
        rows.append(row("TL-10", "normal", "scheduled", "⏳ 排程 22:40"))
        rows.append(row("TL-11", "normal", "gap", "🚫 练度不满足（缺：银灰 精二）"))
        rows.append(row("TL-12", "normal", "no_nav", "⛔ 上游无导航"))
        rows += (1...6).map { row("TL-EX-\($0)", "ex", "cleared", "✅ 已通", ledger: $0 == 6) }
        rows.append(row("TL-EX-7", "ex", "scheduled", "⏳ 排程 23:10"))
        rows.append(row("TL-EX-8", "ex", "raid_pending", "🔁 普通已通、突袭待补"))
        rows += (1...2).map { row("TL-S-\($0)", "s", "cleared", "✅ 已通") }
        rows.append(row("TL-S-3", "s", "scheduled", "⏳ 排程 23:40"))
        rows.append(row("TL-S-4", "s", "gap", "🚫 练度不满足（缺：能天使 模组）"))
        return rows
    }

    private func stagesObject() -> [String: Any] {
        if scenario == .noActivity {
            return [
                "stages": [["stage": "1-7", "code": "1-7", "nav": true, "status": "todo", "status_text": "🕐 待抄"]],
                "in_activity": false,
            ]
        }
        return ["stages": stageRows, "in_activity": true]
    }

    private func choicesObject() -> [String: Any] {
        var object: [String: Any] = [
            "choices": choiceObjects(),
            "switches": ["fight", "infrast", "recruit", "mall", "award", "annihilation"],
            "task_names": [
                "fight": "刷理智", "infrast": "基建", "recruit": "公招", "mall": "商店", "award": "领奖",
                "annihilation": "剿灭",
            ],
            "busy": running ? "晚场日常（22:00 开始）" : "",
            "blackout": scenario == .sessionSoon ? "晚场 12 分钟后开跑" : "",
            "activity": NSNull(),
        ]
        if scenario != .noActivity {
            object["activity"] = [
                "name": "时间啊，向前！",
                "start_at": iso(Date().addingTimeInterval(-9 * 86400)),
                "end_at": iso(Date().addingTimeInterval(6 * 3600 + 120)),
                "stages": ["TL-9", "TL-8", "TL-7"],
            ] as [String: Any]
        }
        return object
    }

    private func previewReceipt(stage: String) -> RemoteReceipt {
        func candidate(
            _ id: Int, _ title: String, views: Int, rating: Double, ratio: Double = 1, gaps: [String] = []
        ) -> [String: Any] {
            [
                "id": id, "title": title, "uploader": "演示", "ratio": ratio, "gaps": gaps,
                "soft_gaps": [String](), "views": views, "rating_ratio": rating, "perfect": gaps.isEmpty,
            ]
        }
        let noPerfect = stage == "TL-11" || stage == "TL-S-4"
        let candidates: [[String: Any]] = noPerfect
            ? [
                candidate(4, "单核速通", views: 2100, rating: 0.88, ratio: 0.75, gaps: ["银灰 精二", "能天使 模组"]),
                candidate(3, "双奶站场", views: 3600, rating: 0.91, ratio: 0.83, gaps: ["塞雷娅 专三"]),
            ]
            : [
                candidate(1, "四人低配稳过", views: 12400, rating: 0.97),
                candidate(2, "全程挂机", views: 8100, rating: 0.94),
                candidate(3, "双奶站场", views: 3600, rating: 0.91),
                candidate(4, "单核速通", views: 2100, rating: 0.88, ratio: 0.75, gaps: ["银灰 精二", "能天使 模组"]),
            ]
        let object: [String: Any] = [
            "token": "demo\(stage.replacingOccurrences(of: "-", with: ""))",
            "stage": stage, "modes": ["normal", "raid"], "sanity_cost": 21,
            "best_id": noPerfect ? NSNull() : 1 as Any, "blocker": NSNull(),
            "expires_at": iso(Date().addingTimeInterval(600)),
            "total": candidates.count, "candidates": candidates, "request_id": "demo",
        ]
        let data = try? JSONSerialization.data(withJSONObject: object)
        return RemoteReceipt(ok: true, code: "previewed", message: "", detail: nil, data: data)
    }

    // MARK: 配置

    private func configObject() -> [String: Any] {
        func field(_ key: String, _ label: String, _ kind: String, _ low: Int? = nil, _ high: Int? = nil) -> [String: Any] {
            var item: [String: Any] = [
                "key": key, "group": "日常", "label": label, "kind": kind, "default": values[key] ?? NSNull(),
            ]
            if let low { item["min"] = low }
            if let high { item["max"] = high }
            return item
        }
        return [
            "schema_version": 1,
            "groups": ["日常", "抄作业"],
            "fields": [
                field("medicine_expire_days", "只吃几天内过期的理智药（天）", "int", 0, 7),
                field("recruit_times", "公招次数", "int", 0, 4),
                field("annihilation_sanity", "为每日剿灭预留的理智", "int", 0, 135),
                field("manual_run_blackout_minutes", "早晚场前多久不能开始手动日常（分钟）", "int", 0, 180),
                field("report_drops", "匿名上报掉落", "bool"),
                field("award_orundum", "领幸运墙合成玉", "bool"),
                field("award_mining", "领限时开采许可合成玉", "bool"),
                field("award_specialaccess", "领月卡奖励", "bool"),
                field("mall_buy_first", "信用商店优先买", "str_list"),
                field("mall_blacklist", "信用商店不买", "str_list"),
                field("mall_reserve_max_credit", "信用点低于 300 停止购买", "bool"),
                field("mall_only_buy_discount", "只买打折物品", "bool"),
                field("copilot_blackout_minutes", "早晚场前多久不开打抄作业（分钟）", "int", 0, 180),
                field("auto_copilot_min_lead_minutes", "离早晚场不到多久就不再开新的一关（分钟）", "int", 0, 240),
                field("activity_search_retry_minutes", "练度不够 / 没作业时多久再找（分钟）", "int", 5, 1440),
                field("auto_copilot_max_attempts_per_day", "同一关每天最多自动尝试几次", "int", 0, 20),
            ],
            "values": values,
            "meta": configMeta,
        ]
    }

    private func defaultsObject() -> [String: Any] {
        ["stage": defaultStage, "tasks": defaultTasks, "source": defaultsMeta.0, "updated_at": defaultsMeta.1]
    }

    // MARK: 历史与战报

    private func historyRows() -> [[String: Any]] {
        func daily(
            _ id: String, _ phase: String, _ start: Date, minutes: Int, status: String = "success",
            failure: String? = nil, skip: String? = nil
        ) -> [String: Any] {
            [
                "id": id, "kind": "daily", "phase": phase, "stage": status == "skipped" ? "" : "TL-9",
                "started_at": iso(start), "finished_at": iso(start.addingTimeInterval(Double(minutes) * 60)),
                "duration_seconds": minutes * 60, "status": status, "failure": failure ?? NSNull(),
                "skip_reason": skip ?? NSNull(), "report": "\(id)-report.json", "progress": "\(id).progress.json",
                "log": "\(id).log",
            ]
        }
        func copilot(
            _ id: String, _ stage: String, _ start: Date, minutes: Int, status: String, won: Int, total: Int
        ) -> [String: Any] {
            [
                "id": id, "kind": "copilot", "phase": "copilot-\(id)", "stage": stage,
                "started_at": iso(start), "finished_at": iso(start.addingTimeInterval(Double(minutes) * 60)),
                "duration_seconds": minutes * 60, "status": status,
                "failure": status == "failed" ? "stage_failed" : NSNull(), "skip_reason": NSNull(),
                "won": won, "total": total, "report": "\(id)-report.json", "progress": "\(id).progress.json",
                "log": "\(id).log",
            ]
        }
        let dayOffset: (Int, String) -> Date = { days, time in
            self.todayAt(time).addingTimeInterval(Double(days) * -86400)
        }
        var rows: [[String: Any]] = []
        if failedPM {
            rows.append(daily("demo-pm-failed", "pm", todayAt("22:00"), minutes: 9, status: "failed", failure: "task_failed"))
        }
        rows += [
            daily("demo-am", "am", todayAt("08:00"), minutes: 18),
            copilot("demo-copilot-today", "TL-10", todayAt("07:12"), minutes: 29, status: "success", won: 3, total: 3),
            daily("demo-pm-1", "pm", dayOffset(1, "22:00"), minutes: 20),
            daily("demo-am-1", "am", dayOffset(1, "08:00"), minutes: 17),
            copilot("demo-copilot-1", "TL-EX-6", dayOffset(1, "03:40"), minutes: 12, status: "failed", won: 0, total: 1),
            daily("demo-pm-3", "pm", dayOffset(3, "22:00"), minutes: 0, status: "skipped", skip: "plan"),
            daily("demo-am-3", "am", dayOffset(3, "08:00"), minutes: 19),
        ]
        for index in 4...24 {
            rows.append(daily("demo-pm-\(index)", "pm", dayOffset(index, "22:00"), minutes: 18))
            rows.append(daily("demo-am-\(index)", "am", dayOffset(index, "08:00"), minutes: 19))
        }
        return rows
    }

    private func historyObject(_ query: [URLQueryItem]) -> [String: Any] {
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        let limit = Int(value("limit") ?? "") ?? 50
        let offset = Int(value("offset") ?? "") ?? 0
        var rows = historyRows()
        // 旧版后端不支持 kind，这里也不过滤，验证前端不崩。
        if hasNewFields, let kind = value("kind") {
            rows = rows.filter { $0["kind"] as? String == kind }
        }
        let page = Array(rows.dropFirst(offset).prefix(limit))
        return ["items": page, "total": rows.count, "has_more": offset + page.count < rows.count]
    }

    private func reportObject(id: String) -> [String: Any] {
        if id.hasPrefix("demo-copilot") {
            let failed = id == "demo-copilot-1"
            let start = failed ? todayAt("03:40").addingTimeInterval(-86400) : todayAt("07:12")
            func result(_ stage: String, _ from: Int, _ to: Int, outcome: String = "won") -> [String: Any] {
                var item: [String: Any] = ["stage": stage, "mode": "normal", "outcome": outcome, "detail": ""]
                if hasNewFields {
                    item["started_at"] = iso(start.addingTimeInterval(Double(from) * 60))
                    item["finished_at"] = iso(start.addingTimeInterval(Double(to) * 60))
                }
                return item
            }
            let results = failed
                ? [result("TL-EX-6", 0, 12, outcome: "failed")]
                : [result("TL-10", 0, 11), result("TL-EX-7", 11, 21), result("TL-S-3", 21, 29)]
            return [
                "schema_version": 1, "kind": "copilot", "run_id": id, "phase": "copilot-\(id)",
                "status": failed ? "failed" : "success", "ok": !failed, "won": failed ? 0 : 3,
                "total": results.count, "duration_seconds": failed ? 720 : 1740, "results": results,
                "failure": failed ? "stage_failed" : NSNull(),
                "stop_reason": failed ? "这一关没打过" : NSNull(), "cleanup_errors": [String](),
                "screenshot": "\(id).png", "embeds": [[String: Any]](),
            ]
        }
        return [
            "embeds": [[
                "title": "✅ MAA 日常·早完成",
                "fields": [
                    ["name": "关卡", "value": "TL-9", "inline": true],
                    ["name": "总耗时", "value": "18 分", "inline": true],
                    ["name": "📋 执行结果", "value": "刷理智 5 次，基建换班 3 间，公招 4 次，买入 3 件", "inline": false],
                    ["name": "备注", "value": "游戏画面丢了，已把游戏窗口摆回来", "inline": false],
                ] as [[String: Any]],
            ] as [String: Any]],
        ]
    }

    private static let logLines: [String] = {
        var lines = [
            "21:42:01 任务开始 fight", "21:42:06 连接 MaaTools", "21:42:09 进入终端", "21:43:12 TL-9 开始 1/5",
            "21:45:40 掉落 电极单元 ×1", "21:45:41 TL-9 开始 2/5", "21:48:06 掉落 电极单元 ×1",
            "21:48:07 TL-9 开始 3/5", "21:50:33 掉落 电极单元 ×1", "21:50:34 TL-9 开始 4/5", "21:52:58 连接中断",
            "21:53:04 恢复 重连 1 次", "21:53:12 TL-9 继续 4/5", "21:55:22 掉落 电极单元 ×1",
            "21:55:23 TL-9 开始 5/5", "21:57:49 掉落 电极单元 ×1", "21:57:50 理智不足，结束",
            "21:57:55 任务完成 fight", "21:57:56 任务开始 infrast", "21:58:44 换班 3 间",
            "21:59:31 任务完成 infrast", "21:59:32 任务开始 recruit", "22:00:10 公招 4 次",
            "22:00:11 任务完成 recruit", "22:00:12 任务开始 mall", "22:00:40 买入 3 件", "22:00:41 任务完成 mall",
            "22:00:42 任务开始 award", "22:00:59 任务完成 award", "22:01:00 全部完成",
        ]
        lines.reserveCapacity(30)
        return lines
    }()

    /// 一张斜纹占位图，用来验收缩放。
    @MainActor private static func screenshotData() -> Data {
        let size = CGSize(width: 1280, height: 720)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.16, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.24, alpha: 1).setStroke()
            let path = UIBezierPath()
            path.lineWidth = 18
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 54
            }
            path.stroke()
            let text = "演示截图" as NSString
            text.draw(
                at: CGPoint(x: 520, y: 320),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 56), .foregroundColor: UIColor.white])
        }
        return image.jpegData(compressionQuality: 0.7) ?? Data()
    }
}
#endif
