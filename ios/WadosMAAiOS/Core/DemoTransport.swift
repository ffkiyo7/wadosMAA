//
//  DemoTransport.swift
//  Wado's MAA (iOS)
//
//  Debug 构建专用的假后端：不连 Mac mini、不动游戏，用来在模拟器里验收各种状态。
//  Release 构建不包含这个文件的内容。
//

#if DEBUG
import Foundation
import WadosMAAShared

enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
    case idle
    case daily
    case copilot
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
    /// 「停止时已换场」：点停止后，后端已经换成抄作业。
    private var switchedToCopilot = false
    private var showsCopilot: Bool { scenario == .copilot || switchedToCopilot }
    private let startedAt = Date().addingTimeInterval(-11 * 60)

    init(scenario: DemoScenario) {
        self.scenario = scenario
        running = [.daily, .copilot, .runChanged].contains(scenario)
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
        default: throw TransportFailure.badResponse
        }
    }

    func send(
        _ method: HTTPMethod, _ path: String, body: [String: any Sendable]?, timeout: TimeInterval
    ) async throws -> RemoteReceipt {
        try await Task.sleep(for: .milliseconds(350))
        guard path == "/api/v1/run/cancel" else {
            return RemoteReceipt(ok: false, code: "failed", message: "演示数据不支持这个操作", detail: nil, data: nil)
        }
        if scenario == .runChanged {
            switchedToCopilot = true
            return RemoteReceipt(ok: false, code: "run_changed", message: "运行已变化", detail: nil, data: nil)
        }
        running = false
        return RemoteReceipt(ok: true, code: "ok", message: "正在停止", detail: nil, data: nil)
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

    // MARK: - 状态推进

    private func tick() -> [SSEEvent] {
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

    private var lockCleared = false

    private func clearLock() -> [SSEEvent] {
        lockCleared = true
        return [SSEEvent(name: "lock", data: "null")]
    }

    // MARK: - 数据

    private func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = BeijingTime.zone
        return formatter.string(from: date)
    }

    private func snapshotObject() -> [String: Any] {
        var object: [String: Any] = [
            "lock": NSNull(),
            "last_run": lastRunObject(),
            "progress": NSNull(),
            "today_plan": planObject(),
            "schedule": NSNull(),
            "upstream": NSNull(),
            "copilot_auto_paused": false,
            "activity": NSNull(),
            "scheduler": NSNull(),
            "resign": NSNull(),
            "errors": [String: String](),
        ]
        if running {
            let isCopilot = showsCopilot
            object["lock"] = [
                "holder": isCopilot ? "copilot" : "daily",
                "detail": isCopilot ? "TL-EX-7" : "晚",
                "pid": 4242,
                "since": iso(startedAt),
                "run_id": isCopilot ? "demo-copilot" : "demo-daily",
            ] as [String: Any]
            object["progress"] = progressObject()
        }
        return object
    }

    private func lastRunObject() -> [String: Any] {
        [
            "status": "success", "phase": "am", "run_id": "demo-am",
            "started_at": iso(Date().addingTimeInterval(-6 * 3600)),
            "finished_at": iso(Date().addingTimeInterval(-6 * 3600 + 18 * 60)),
            "plan": ["stage": "TL-9"],
        ]
    }

    private func planObject() -> [String: Any] {
        func session(_ phase: String, _ name: String, _ time: String) -> [String: Any] {
            [
                "phase": phase, "name": name, "time": time, "enabled": true, "stage": "TL-9",
                "stage_source": "auto", "skip": false,
                "tasks": ["fight": true, "infrast": true, "recruit": true, "mall": true, "award": true],
                "drops": [["item_id": "30012", "name": "电极单元", "count": 5] as [String: Any]],
                "fallback_stage": "1-7", "choices": [[String: String]](),
            ]
        }
        return [
            "date": "2026-11-22",
            "sessions": [session("am", "早场", "08:00"), session("pm", "晚场", "22:00")],
            "task_names": ["fight": "刷理智", "infrast": "基建", "recruit": "公招", "mall": "商店", "award": "领奖"],
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
            "notes": [["at": iso(startedAt.addingTimeInterval(90)), "text": "重连恢复 1 次"]],
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

    private func stagesObject() -> [String: Any] {
        let rows: [[String: Any]] = (1...10).map { index in
            ["stage": "TL-\(index)", "code": "TL-\(index)", "nav": true, "status": index <= 3 ? "cleared" : "ready"]
        }
        return ["stages": rows, "in_activity": true]
    }
}
#endif
