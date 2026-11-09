//
//  RemoteBridge.swift
//  Wado's MAA
//
//  调 `maa_action.py`：GUI 对 maa-remote 的一切改动都只走这一个入口（DEV_GUIDE §12.1）。
//  stdout 是一行回执 `{"ok", "code", "message", "detail"?, "data"?}`：`code` 给程序判断，
//  `message` 给玩家看，`detail` 是技术细节，只进诊断信息，不上界面。
//

import AppKit
import Foundation

struct RemoteReceipt: Sendable {
    let ok: Bool
    /// 稳定的短码（`session_soon`、`busy`…），按它分支，不比对 `message` 的措辞。旧版后端没有，按 ok 补成 `ok` / `failed`。
    let code: String
    /// 给玩家看的一句话。
    let message: String
    /// 技术细节（异常、路径）；只记进诊断信息。
    let detail: String?
    /// `data` 字段的原始 JSON；没有就是 nil。
    let data: Data?

    /// `snakeCase` 会把**字典的键**也一起改写（`recruit_times` → `recruitTimes`），
    /// 所以含「键是配置名 / 文件名」的字典的形状要传 false，自己写 CodingKeys。
    /// 读不懂时抛 `RemoteBridgeError.badReceipt`：界面上只说一句人话，细节进诊断信息。
    func decode<T: Decodable>(_ type: T.Type, snakeCase: Bool = true) throws -> T {
        guard let data else { throw RemoteBridgeError.recorded(.badReceipt("no data: \(message)")) }
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RemoteBridgeError.recorded(.badReceipt("\(T.self): \(error)"))
        }
    }

    // copy-guard: developer
    /// 记进诊断信息的一行：命令、结果码、给人看的话和技术细节。
    func diagnostic(_ args: [String]) -> String {
        var line = "\(args.joined(separator: " ")) → \(ok ? "ok" : "failed") [\(code)] \(message)"
        if let detail { line += " | detail: \(detail)" }
        return line
    }
    // copy-guard: end

    /// `data` 当成字典读（配置页这种键不固定的场合）。
    var dictionary: [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

enum RemoteBridgeError: LocalizedError {
    case notDeployed(String)
    case launchFailed(String)
    case timedOut([String])
    case badReceipt(String)

    /// 界面上的一句人话；技术细节在 `diagnostic`，用「复制诊断信息」拿。
    var errorDescription: String? {
        switch self {
        case .notDeployed: return "Wado's MAA 还没装好，暂时用不了。"
        case .launchFailed: return "Wado's MAA 启动不了，请稍后再试。"
        case .timedOut: return "Wado's MAA 太久没有响应，请稍后再试。"
        case .badReceipt: return "Wado's MAA 没有响应，请稍后再试。"
        }
    }

    // copy-guard: developer
    var diagnostic: String {
        switch self {
        case let .notDeployed(path): return "maa_action.py not found: \(path)"
        case let .launchFailed(detail): return "cannot launch maa_action.py: \(detail)"
        case let .timedOut(args): return "maa_action.py \(args.joined(separator: " ")) timed out"
        case let .badReceipt(detail): return "unreadable maa_action.py receipt: \(detail)"
        }
    }
    // copy-guard: end

    /// 记进诊断信息再抛出去。
    static func recorded(_ error: RemoteBridgeError) -> RemoteBridgeError {
        let text = error.diagnostic
        Task { @MainActor in Diagnostics.record(text) }
        return error
    }
}

enum RemoteBridge {
    /// 跑一条命令。`timeout` 默认 30 秒；`copilot preview`、`upstream status --online` 要给长一点。
    static func run(_ args: [String], timeout: TimeInterval = 30) async throws -> RemoteReceipt {
        let script = RemoteConfig.actionScript.path
        guard FileManager.default.fileExists(atPath: script) else {
            throw RemoteBridgeError.recorded(.notDeployed(script))
        }
        let python = RemoteConfig.python
        let env = RemoteConfig.environment()
        let cwd = RemoteConfig.hermesHome
        do {
            let receipt = try await Task.detached(priority: .userInitiated) {
                try runBlocking(python: python, script: script, args: args, env: env, cwd: cwd, timeout: timeout)
            }.value
            // 只记失败的：`schedule show`、`upstream status` 每次重读都带 detail，记进去会把真报错挤掉。
            if !receipt.ok {
                await Diagnostics.record(receipt.diagnostic(args))
            }
            return receipt
        } catch let error as RemoteBridgeError {
            await Diagnostics.record(error.diagnostic)
            throw error
        }
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
        var stderr = Data()
        var timedOut = false
    }

    private static func runBlocking(
        python: String, script: String, args: [String], env: [String: String], cwd: URL, timeout: TimeInterval
    ) throws -> RemoteReceipt {
        let box = Box()
        let process = box.process
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script] + args
        process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw RemoteBridgeError.launchFailed(error.localizedDescription)
        }
        let killer = DispatchWorkItem {
            if box.process.isRunning {
                box.timedOut = true
                box.process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // stdout / stderr 都要边跑边读，否则输出过 64 KB 时管道写满，子进程卡死。
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            box.stderr = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()
        if box.timedOut {
            throw RemoteBridgeError.timedOut(args)
        }
        return try parse(stdout: stdout, stderr: box.stderr, status: process.terminationStatus)
    }

    static func parse(stdout: Data, stderr: Data, status: Int32) throws -> RemoteReceipt {
        let text = String(decoding: stdout, as: UTF8.self)
        let line = text.split(separator: "\n").last { $0.hasPrefix("{") }
        guard let line,
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let ok = object["ok"] as? Bool
        else {
            let tail = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            throw RemoteBridgeError.badReceipt(tail.isEmpty ? "exit \(status)" : tail)
        }
        var data: Data?
        if let payload = object["data"], !(payload is NSNull) {
            data = try? JSONSerialization.data(withJSONObject: payload)
        }
        let code = (object["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (ok ? "ok" : "failed")
        let detail = (object["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return RemoteReceipt(ok: ok, code: code, message: object["message"] as? String ?? "", detail: detail, data: data)
    }
}

/// 「复制诊断信息」：最近几条技术细节（后台报错、读不懂的结果），界面上不显示，排障时贴出来用。
@MainActor enum Diagnostics {
    private static var entries: [String] = []
    static let limit = 40

    static func record(_ text: String) {
        let stamp = Date().formatted(date: .numeric, time: .standard)
        entries.append("\(stamp) \(text)")
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    // copy-guard: developer
    static var report: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let head = [
            "Wado's MAA \(version)",
            "HERMES_HOME: \(RemoteConfig.hermesHome.path)",
            "python: \(RemoteConfig.python)",
        ]
        return (head + ["", "recent:"] + (entries.isEmpty ? ["(none)"] : entries)).joined(separator: "\n")
    }
    // copy-guard: end

    static func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
