//
//  APIModels.swift
//  WadosMAAShared
//
//  HTTP / SSE API 的数据形状（SPEC §5）。快照按字段独立解码：一个字段读不懂只丢这一个，
//  锁、最近一场和进度仍然可用，紧急停止不受影响。
//

import Foundation

public struct HealthStatus: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let service: String
    public let apiVersion: Int
    public let serverTime: String?

    enum CodingKeys: String, CodingKey {
        case ok, service
        case apiVersion = "api_version"
        case serverTime = "server_time"
    }
}

/// `daemon/scheduler.json`：内置调度器的任务状态。
public struct SchedulerStatus: Decodable, Sendable, Equatable {
    public struct Job: Decodable, Sendable, Equatable {
        public let enabled: Bool?
        public let nextRunAt: String?
        public let lastRunAt: String?
        public let lastStatus: String?
        public let lastDetail: String?

        enum CodingKeys: String, CodingKey {
            case enabled
            case nextRunAt = "next_run_at"
            case lastRunAt = "last_run_at"
            case lastStatus = "last_status"
            case lastDetail = "last_detail"
        }
    }

    public let timezone: String?
    public let updatedAt: String?
    public let depotEnabled: Bool?
    public let jobs: [String: Job]

    enum CodingKeys: String, CodingKey {
        case timezone, jobs
        case updatedAt = "updated_at"
        case depotEnabled = "depot_enabled"
    }
}

/// `daemon/resign.json`：iOS 无线续签状态（S4-1）。`status` 为 ok / due / running / failed。
public struct ResignStatus: Decodable, Sendable, Equatable {
    public let status: String?
    public let lastSignedAt: String?
    public let expirationDate: String?
    public let lastAttemptAt: String?
    public let lastError: String?
    /// ok / skipped（暂时不行，下个周期再试）/ failed。
    public let lastResult: String?
    public let lastProbeAt: String?
    /// 自动续签上次没动手的原因，如「手机不在局域网」。
    public let lastProbeDetail: String?

    enum CodingKeys: String, CodingKey {
        case status
        case lastSignedAt = "last_signed_at"
        case expirationDate = "expiration_date"
        case lastAttemptAt = "last_attempt_at"
        case lastError = "last_error"
        case lastResult = "last_result"
        case lastProbeAt = "last_probe_at"
        case lastProbeDetail = "last_probe_detail"
    }

    public init(
        status: String?, lastSignedAt: String?, expirationDate: String?, lastAttemptAt: String? = nil,
        lastError: String? = nil, lastResult: String? = nil, lastProbeAt: String? = nil,
        lastProbeDetail: String? = nil
    ) {
        self.status = status
        self.lastSignedAt = lastSignedAt
        self.expirationDate = expirationDate
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
        self.lastResult = lastResult
        self.lastProbeAt = lastProbeAt
        self.lastProbeDetail = lastProbeDetail
    }
}

/// 快照的 `sanity`：森空岛实测值和按恢复速度估算的当前值。读不到练度快照时整段缺失。
public struct SanityStatus: Decodable, Sendable, Equatable {
    public let current: Int
    public let max: Int
    public let measuredAt: Date?
    public let estimatedNow: Int?

    enum CodingKeys: String, CodingKey {
        case current, max
        case measuredAt = "measured_at"
        case estimatedNow = "estimated_now"
    }

    public init(current: Int, max: Int, measuredAt: Date?, estimatedNow: Int?) {
        self.current = current
        self.max = max
        self.measuredAt = measuredAt
        self.estimatedNow = estimatedNow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        current = Int(try c.decode(Double.self, forKey: .current))
        max = Int(try c.decode(Double.self, forKey: .max))
        measuredAt = (try? c.decodeIfPresent(String.self, forKey: .measuredAt)).flatMap { $0 }
            .flatMap(BeijingTime.parseISO)
        estimatedNow = (try? c.decodeIfPresent(Double.self, forKey: .estimatedNow)).flatMap { $0 }.map { Int($0) }
    }
}

/// 快照的 `notify`：Bark 推送是否配好。
public struct NotifyStatus: Decodable, Sendable, Equatable {
    public let configured: Bool

    public init(configured: Bool) {
        self.configured = configured
    }
}

/// `GET /api/v1/snapshot`。
public struct RemoteSnapshot: Sendable {
    public var lock: LockHolder?
    public var lastRun: [String: JSONValue]?
    public var progress: RunProgressFile?
    public var todayPlan: TodayPlan?
    public var schedule: ScheduleReport?
    public var upstream: UpstreamStatus?
    public var copilotAutoPaused: Bool?
    public var activity: [String: JSONValue]?
    public var scheduler: SchedulerStatus?
    public var resign: ResignStatus?
    /// 旧版后端没有这个键。
    public var sanity: SanityStatus?
    /// 旧版后端没有这个键。
    public var notify: NotifyStatus?
    /// 服务端报告的失败字段，加上本端解不开的字段。
    public var errors: [String: String]

    public init() {
        errors = [:]
    }

    public init?(data: Data) {
        guard case let .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.init()
        for (key, value) in root["errors"]?.object ?? [:] {
            errors[key] = value.string ?? value.displayText
        }
        lock = field(root, "lock", LockHolder.self)
        lastRun = root["last_run"]?.object
        progress = root["progress"]?.object.map(RunProgressFile.init(file:))
        todayPlan = field(root, "today_plan", TodayPlan.self)
        schedule = field(root, "schedule", ScheduleReport.self)
        upstream = field(root, "upstream", UpstreamStatus.self, snakeCase: true)
        copilotAutoPaused = root["copilot_auto_paused"]?.bool
        activity = root["activity"]?.object
        scheduler = field(root, "scheduler", SchedulerStatus.self)
        resign = field(root, "resign", ResignStatus.self)
        sanity = field(root, "sanity", SanityStatus.self)
        notify = field(root, "notify", NotifyStatus.self)
    }

    /// 应用一条 SSE 事件；不认识的事件返回 false。
    @discardableResult
    public mutating func apply(_ event: SSEEvent) -> Bool {
        guard case let .some(value) = try? JSONDecoder().decode(JSONValue.self, from: Data(event.data.utf8)) else {
            return false
        }
        let root: [String: JSONValue] = [event.name: value]
        switch event.name {
        case "lock": lock = field(root, "lock", LockHolder.self)
        case "last_run": lastRun = value.object
        case "progress": progress = value.object.map(RunProgressFile.init(file:))
        case "today_plan": todayPlan = field(root, "today_plan", TodayPlan.self)
        case "schedule": schedule = field(root, "schedule", ScheduleReport.self)
        case "upstream": upstream = field(root, "upstream", UpstreamStatus.self, snakeCase: true)
        case "resign": resign = field(root, "resign", ResignStatus.self)
        default: return false
        }
        return true
    }

    private mutating func field<T: Decodable>(
        _ root: [String: JSONValue], _ key: String, _ type: T.Type, snakeCase: Bool = false
    ) -> T? {
        guard let value = root[key], value != .null else { return nil }
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            errors[key] = "\(T.self): \(error)"
            return nil
        }
    }
}

/// `GET /api/v1/history`。
public struct HistoryPage: Sendable, Equatable {
    public let items: [RunRecord]
    public let total: Int
    public let hasMore: Bool

    public init?(data: Data) {
        guard case let .object(root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        items = (root["items"]?.array ?? []).compactMap { $0.object.flatMap(RunRecord.init(row:)) }
        total = Int(root["total"]?.number ?? Double(items.count))
        hasMore = root["has_more"]?.bool ?? false
    }
}

/// `GET /api/v1/runs/<id>/log?tail=200`。
public struct RunLogTail: Decodable, Sendable, Equatable {
    public let lines: [String]
    public let truncated: Bool
}

/// 配对二维码里的 JSON（`init_daemon.py`）。`spki_sha256` 是 SPKI DER 的 SHA-256 Base64。
public struct PairingPayload: Codable, Sendable, Equatable {
    public let lanURL: URL
    public let remoteURL: URL
    public let spkiSHA256: String
    public let fullToken: String?

    enum CodingKeys: String, CodingKey {
        case lanURL = "lan_url"
        case remoteURL = "remote_url"
        case spkiSHA256 = "spki_sha256"
        case fullToken = "full_token"
    }

    public init(lanURL: URL, remoteURL: URL, spkiSHA256: String, fullToken: String?) {
        self.lanURL = lanURL
        self.remoteURL = remoteURL
        self.spkiSHA256 = spkiSHA256
        self.fullToken = fullToken
    }

    /// 只接受 https 地址和 32 字节的 Base64 指纹。
    public init?(text: String) {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
            let value = try? JSONDecoder().decode(Self.self, from: data),
            value.lanURL.scheme == "https", value.remoteURL.scheme == "https",
            Data(base64Encoded: value.spkiSHA256)?.count == 32
        else { return nil }
        self = value
    }
}

// MARK: - SSE

public struct SSEEvent: Sendable, Equatable {
    public let name: String
    public let data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}

/// 按行喂 `text/event-stream`，空行结束一个事件。注释行（心跳）只算连接还活着。
public struct SSEParser: Sendable {
    private var name = ""
    private var data: [String] = []

    public init() {}

    public mutating func feed(line raw: String) -> SSEEvent? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer {
                name = ""
                data = []
            }
            guard !data.isEmpty else { return nil }
            return SSEEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
