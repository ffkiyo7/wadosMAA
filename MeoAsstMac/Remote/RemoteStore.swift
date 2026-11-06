//
//  RemoteStore.swift
//  Wado's MAA
//
//  maa-remote 状态在 GUI 里的镜像（S5，K3）：只读进来显示，改动一律走 `maa_action.py`。
//  `state/maa/` 和 `cron/` 一有变化（Discord 那边点了按钮、cron 跑了一场）就重读，
//  所以两边谁后改就以谁为准。读到比自己认识的更高的 `schema_version` 时只读、不让改（不变量 #58）。
//

import Foundation
import Observation

// MARK: - JSON 值

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    /// 传给 `config set` 的那段 JSON。
    var jsonText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func parse(_ text: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    var bool: Bool? { if case let .bool(value) = self { value } else { nil } }
    var number: Double? { if case let .number(value) = self { value } else { nil } }
    var string: String? { if case let .string(value) = self { value } else { nil } }
    var array: [JSONValue]? { if case let .array(value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case let .object(value) = self { value } else { nil } }

    /// 给人看的一行。
    var displayText: String {
        switch self {
        case .null: return "—"
        case let .bool(value): return value ? "开" : "关"
        case let .number(value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case let .string(value): return value
        case let .array(values): return values.map(\.displayText).joined(separator: "、")
        case .object: return jsonText
        }
    }
}

// MARK: - 数据形状（DEV_GUIDE §12）

struct ConfigField: Decodable, Identifiable, Sendable {
    let key: String
    let group: String
    let label: String
    let kind: String
    let `default`: JSONValue?
    let min: Double?
    let max: Double?
    let help: String?

    var id: String { key }
}

struct ChangeMeta: Decodable, Sendable, Equatable {
    let source: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case source
        case updatedAt = "updated_at"
    }

    init(source: String?, updatedAt: String?) {
        self.source = source
        self.updatedAt = updatedAt
    }

    /// 「由 Wado's MAA 于 11-06 14:03 改」。
    var text: String {
        let who = source == "gui" ? "Wado's MAA" : source == "discord" ? "Discord" : (source ?? "未知")
        guard let updatedAt, let date = RunLock.parseISO(updatedAt) else { return "由 \(who) 改" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RunLock.beijing
        let parts = calendar.dateComponents([.month, .day], from: date)
        return String(format: "由 %@ 于 %02d-%02d %@ 改", who, parts.month ?? 0, parts.day ?? 0,
                      RunLock.beijingClock(date))
    }
}

struct ConfigSnapshot: Decodable, Sendable {
    let groups: [String]
    let fields: [ConfigField]
    let values: [String: JSONValue]
    let meta: [String: ChangeMeta]
}

struct DefaultsSnapshot: Decodable, Sendable {
    let stage: String?
    let tasks: [String: Bool]?
    let source: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case stage, tasks, source
        case updatedAt = "updated_at"
    }

    var meta: ChangeMeta? {
        guard let source, !source.isEmpty else { return nil }
        return ChangeMeta(source: source, updatedAt: updatedAt)
    }
}

struct ScheduleReport: Decodable, Sendable {
    struct CronJob: Decodable, Sendable {
        let id: String
        let expr: String
        let expectedExpr: String
        let enabled: Bool
        let inSync: Bool

        enum CodingKeys: String, CodingKey {
            case id, expr, enabled
            case expectedExpr = "expected_expr"
            case inSync = "in_sync"
        }
    }

    struct Session: Decodable, Sendable {
        let time: String
        let enabled: Bool
        let cron: [String: CronJob]
    }

    let timezone: String
    let jobsPath: String
    let sessions: [String: Session]

    enum CodingKeys: String, CodingKey {
        case timezone, sessions
        case jobsPath = "jobs_path"
    }
}

// MARK: - Store

@MainActor @Observable final class RemoteStore {
    static let shared = RemoteStore()

    static let knownSchemaVersion = 1
    static let checkedFiles = ["config.json", "plan.json", "defaults.json", "last_run.json", "upstream.json"]

    private(set) var config: ConfigSnapshot?
    private(set) var defaults: DefaultsSnapshot?
    private(set) var schedule: ScheduleReport?
    private(set) var scheduleError: String?
    private(set) var lastRun: [String: JSONValue] = [:]
    private(set) var lockHolder: LockHolder?
    private(set) var schemaProblem: String?
    private(set) var loadError: String?
    private(set) var reloadedAt: Date?
    var notice: (ok: Bool, text: String)?
    private(set) var busy = false

    var upstream: UpstreamStatus? { upstreamStatus }
    private(set) var upstreamStatus: UpstreamStatus?

    /// 有更高版本的状态文件时不许改。
    var readOnly: Bool { schemaProblem != nil }

    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    // MARK: 读

    func reload() async {
        checkSchemas()
        lockHolder = RunLock.currentHolder()
        lastRun = Self.readJSON("last_run.json")
        do {
            config = try await RemoteBridge.run(["config", "get"]).decode(ConfigSnapshot.self, snakeCase: false)
            defaults = try await RemoteBridge.run(["defaults", "show"]).decode(DefaultsSnapshot.self, snakeCase: false)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        do {
            let receipt = try await RemoteBridge.run(["schedule", "show"])
            if receipt.ok {
                schedule = try receipt.decode(ScheduleReport.self, snakeCase: false)
                scheduleError = nil
            } else {
                scheduleError = receipt.message
            }
        } catch {
            scheduleError = error.localizedDescription
        }
        upstreamStatus = await RemoteGate.refreshStatus() ?? upstreamStatus
        reloadedAt = Date()
    }

    func refreshUpstream(online: Bool) async {
        busy = true
        defer { busy = false }
        if let status = await RemoteGate.refreshStatus(online: online) {
            upstreamStatus = status
        } else {
            notice = (false, RemoteGate.lastStatusError ?? "查不到上游状态")
        }
    }

    private func checkSchemas() {
        var problems: [String] = []
        for name in Self.checkedFiles {
            let object = Self.readJSON(name)
            if case let .number(version)? = object["schema_version"], Int(version) > Self.knownSchemaVersion {
                problems.append("\(name) 是 v\(Int(version))")
            }
        }
        schemaProblem = problems.isEmpty
            ? nil
            : "\(problems.joined(separator: "、"))，这个 App 只认 v\(Self.knownSchemaVersion)：只能看，不能改。先更新 Wado's MAA。"
    }

    static func readJSON(_ name: String) -> [String: JSONValue] {
        let url = RemoteConfig.stateDirectory.appending(path: name)
        guard let data = try? Data(contentsOf: url),
            case let .object(object)? = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return [:] }
        return object
    }

    // MARK: 写（全部走 maa_action）

    @discardableResult
    func perform(_ args: [String], timeout: TimeInterval = 30) async -> RemoteReceipt? {
        guard !readOnly else {
            notice = (false, schemaProblem ?? "只读")
            return nil
        }
        busy = true
        defer { busy = false }
        do {
            let receipt = try await RemoteBridge.run(args, timeout: timeout)
            notice = (receipt.ok, receipt.message)
            await reload()
            return receipt
        } catch {
            notice = (false, error.localizedDescription)
            return nil
        }
    }

    func setConfig(_ key: String, _ value: JSONValue) async {
        await perform(["config", "set", key, value.jsonText])
    }

    // MARK: 监听

    /// `state/maa/` 和 `cron/` 一变就重读（防抖 0.5 秒）；再加 60 秒一次的兜底轮询。
    func startWatching() {
        guard sources.isEmpty else { return }
        for directory in [RemoteConfig.stateDirectory, RemoteConfig.hermesHome.appending(path: "cron")] {
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.reload()
            }
        }
    }

    func stopWatching() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pollTask?.cancel()
        pollTask = nil
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }
}
