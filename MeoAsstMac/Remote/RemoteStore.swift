//
//  RemoteStore.swift
//  Wado's MAA
//
//  maa-remote 状态在 GUI 里的镜像（S5，K3）：只读进来显示，改动一律走 `maa_action.py`。
//  `state/maa/` 和 `cron/` 一有变化（Discord 那边点了按钮、cron 跑了一场）就重读，
//  所以两边谁后改就以谁为准。读到比自己认识的更高的 `schema_version` 时只读、不让改（不变量 #58）。
//

import AppKit
import Foundation
import Observation
import UserNotifications

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

// MARK: - 最近一场（last_run.json）

/// `last_run.json` 给人看的说法。判成败只看 `status`，不读 `ok`（DEV_GUIDE §12.3）。
enum LastRunText {
    /// 还没出结果的状态。
    static let ongoing: Set<String> = ["", "running", "dispatched", "pending", "queued"]

    static func isCopilot(_ run: [String: JSONValue]) -> Bool {
        (run["phase"]?.string ?? "").hasPrefix("copilot-")
    }

    static func kind(_ run: [String: JSONValue]) -> String {
        switch run["phase"]?.string {
        case "am": "早场"
        case "pm": "晚场"
        case _ where isCopilot(run): "抄作业"
        default: "手动场"
        }
    }

    /// 日常读 `plan.stage`，抄作业读顶层 `stage`。
    static func stage(_ run: [String: JSONValue]) -> String {
        (isCopilot(run) ? run["stage"]?.string : run["plan"]?.object?["stage"]?.string) ?? ""
    }

    /// 「早场 · TL-7」。
    static func title(_ run: [String: JSONValue]) -> String {
        let stage = stage(run)
        return kind(run) + (stage.isEmpty ? "" : " · \(stage)")
    }

    static func statusWord(_ status: String) -> String {
        switch status {
        case "success": "成功"
        case "failed": "失败"
        case "skipped": "跳过"
        case "running": "进行中"
        default: status
        }
    }
}

/// 一场跑完的战报：App 开着的时候 `status` 变成终态才有，一场只报一次。
struct RunReport: Identifiable, Equatable, Sendable {
    let id: String
    let status: String
    let title: String
    let finishedAt: Date?
    /// 战报里值得一眼看到的几行。
    let lines: [String]
    let summary: String

    var ok: Bool { status == "success" }

    init(key: String, run: [String: JSONValue]) {
        id = key
        status = run["status"]?.string ?? ""
        title = LastRunText.title(run)
        finishedAt = (run["finished_at"] ?? run["started_at"])?.string.flatMap(RunLock.parseISO)
        summary = run["summary"]?.string ?? ""
        let all = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("总体") }
        // 成功看刷理智那行（关卡、次数、掉落）；不成功看出问题的那几行。
        let picked = status == "success"
            ? all.filter { $0.contains("刷理智") }
            : all.filter { $0.contains("❌") || $0.contains("⚠") }
        lines = Array((picked.isEmpty ? all : picked).prefix(3))
    }
}

// MARK: - Store

@MainActor @Observable final class RemoteStore {
    static let shared = RemoteStore()

    static let knownSchemaVersion = 1
    /// 成功回执停留多久。
    static let noticeLifetime: Duration = .seconds(5)
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
    /// 刚才那次操作的回执。用 `post` / `clearNotice` 改，别直接赋值。
    private(set) var notice: (ok: Bool, text: String)?
    private(set) var busy = false

    var upstream: UpstreamStatus? { upstreamStatus }
    private(set) var upstreamStatus: UpstreamStatus?

    /// 有更高版本的状态文件时不许改。
    var readOnly: Bool { schemaProblem != nil }

    /// 每切一次 HERMES_HOME 加一；共用列表（`RunData`）靠它重新加载。
    private(set) var homeGeneration = 0
    /// 刚跑完的那一场；App 在前台时首页上方弹一下，在后台时发系统通知。
    private(set) var runReport: RunReport?
    /// maa-remote 正在跑的那一场到了哪个阶段（跟 `last_run.log`）。
    let progress = RunProgress()

    @ObservationIgnored private var sources: [DispatchSourceFileSystemObject] = []
    /// 正在监听的 HERMES_HOME；还没开始监听时是 nil。
    @ObservationIgnored private var watchedHome: URL?
    @ObservationIgnored private var homeObserver: NSKeyValueObservation?
    @ObservationIgnored private var homeSwitch: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var lockPoll: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var reportTimer: Task<Void, Never>?
    /// 上一次读到的那一场（phase、起止时间、status）；nil 表示这个环境还没读过。
    @ObservationIgnored private var seenRunKey: String?
    /// 这之前就结束的场次不报。切环境时重置。
    @ObservationIgnored private var watchingSince = Date()

    /// 成功的回执几秒后自己消失；失败的留到用户关掉、下一次操作或切页。
    /// 新回执会取消旧的计时，旧定时器不会清掉新回执（都在主线程上，取消先于检查）。
    func post(_ ok: Bool, _ text: String) {
        noticeTimer?.cancel()
        noticeTimer = nil
        notice = (ok, text)
        guard ok else { return }
        noticeTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeTimer?.cancel()
        noticeTimer = nil
        notice = nil
    }

    // MARK: 读

    func reload() async {
        checkSchemas()
        lockHolder = RunLock.currentHolder()
        lastRun = Self.readJSON("last_run.json")
        progress.update(run: lastRun)
        noticeFinishedRun()
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

    // MARK: 战报

    /// 状态从「还在跑」变成终态（或中间漏看了，直接读到一场新的终态）就报一次。
    /// 打开 App、切环境后读到的第一份只记下来，不报。
    private func noticeFinishedRun() {
        let status = lastRun["status"]?.string ?? ""
        let key = (["phase", "started_at", "finished_at"].map { lastRun[$0]?.string ?? "" } + [status])
            .joined(separator: "|")
        let previous = seenRunKey
        seenRunKey = key
        guard let previous, previous != key, !LastRunText.ongoing.contains(status) else { return }
        let report = RunReport(key: key, run: lastRun)
        guard let finished = report.finishedAt, finished >= watchingSince else { return }
        if NSApplication.shared.isActive {
            showReport(report)
        } else {
            Task { await RunNotifier.post(report) }
        }
    }

    private func showReport(_ report: RunReport) {
        reportTimer?.cancel()
        reportTimer = nil
        runReport = report
        // 成功的半分钟后自己收起；没成功的留到用户关掉。
        guard report.ok else { return }
        reportTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.runReport = nil
        }
    }

    func dismissReport() {
        reportTimer?.cancel()
        reportTimer = nil
        runReport = nil
    }

    func refreshUpstream(online: Bool) async {
        busy = true
        defer { busy = false }
        if let status = await RemoteGate.refreshStatus(online: online) {
            upstreamStatus = status
        } else {
            post(false, RemoteGate.lastStatusError ?? "查不到上游状态")
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
            post(false, schemaProblem ?? "只读")
            return nil
        }
        clearNotice()
        busy = true
        defer { busy = false }
        do {
            let receipt = try await RemoteBridge.run(args, timeout: timeout)
            post(receipt.ok, receipt.message)
            await reload()
            return receipt
        } catch {
            post(false, error.localizedDescription)
            return nil
        }
    }

    func setConfig(_ key: String, _ value: JSONValue) async {
        await perform(["config", "set", key, value.jsonText])
    }

    // MARK: 监听

    /// `state/maa/` 和 `cron/` 一变就重读（防抖 0.5 秒）；再加 60 秒一次的兜底轮询。
    /// 设置里切了 HERMES_HOME 就换到新目录去监听（见 `switchHome`）。
    func startWatching() {
        observeHome()
        guard sources.isEmpty, pollTask == nil else { return }
        let home = RemoteConfig.hermesHome
        watchedHome = home
        for directory in [RemoteConfig.stateDirectory, home.appending(path: "cron")] {
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
        // 放锁只是清空 `run.lock` 再 flock 解锁，目录不会变，所以单独每 2 秒看一眼锁。
        lockPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.checkLock()
            }
        }
    }

    func stopWatching() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pollTask?.cancel()
        pollTask = nil
        lockPoll?.cancel()
        lockPoll = nil
        pendingReload?.cancel()
        pendingReload = nil
        watchedHome = nil
        progress.stop()
    }

    /// 盯着 `RemoteHermesHome`：设置页改的、`defaults write` 改的都能收到。
    private func observeHome() {
        guard homeObserver == nil else { return }
        homeObserver = UserDefaults.standard.observe(\.RemoteHermesHome) { [weak self] _, _ in
            Task { @MainActor in self?.homeMaybeChanged() }
        }
    }

    /// 设置页的输入框每敲一个字都会写一次，停手 0.8 秒后再换。
    private func homeMaybeChanged() {
        guard let watchedHome else { return }
        homeSwitch?.cancel()
        guard RemoteConfig.hermesHome.path != watchedHome.path else { return }
        homeSwitch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.switchHome()
        }
    }

    /// 换环境：丢掉旧环境读到的东西，换目录监听，重读。
    private func switchHome() async {
        stopWatching()
        clearNotice()
        config = nil
        defaults = nil
        schedule = nil
        scheduleError = nil
        lastRun = [:]
        lockHolder = nil
        loadError = nil
        dismissReport()
        seenRunKey = nil
        watchingSince = Date()
        homeGeneration += 1
        startWatching()
        await reload()
    }

    /// 锁换了人（或放开了）就整个重读一遍：最近一场多半也跟着变了。
    private func checkLock() {
        let holder = RunLock.currentHolder()
        guard holder != lockHolder else { return }
        lockHolder = holder
        scheduleReload()
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

/// App 在后台时的战报：系统通知。第一次要发时才请求授权。
enum RunNotifier {
    static func post(_ report: RunReport) async {
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = "\(report.title) \(LastRunText.statusWord(report.status))"
        content.body = report.lines.joined(separator: "\n")
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: report.id, content: content, trigger: nil))
    }
}

extension UserDefaults {
    /// KVO 用：名字必须和 `RemoteConfig.hermesHomeKey` 一字不差（大小写也算）。
    @objc dynamic var RemoteHermesHome: String? { string(forKey: RemoteConfig.hermesHomeKey) }
}
