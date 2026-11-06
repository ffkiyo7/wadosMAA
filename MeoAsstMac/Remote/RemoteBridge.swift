//
//  RemoteBridge.swift
//  Wado's MAA
//
//  调 `maa_action.py`：GUI 对 maa-remote 的一切改动都只走这一个入口（DEV_GUIDE §12.1）。
//  stdout 是一行回执 `{"ok", "message", "data"?}`。
//

import Foundation

struct RemoteReceipt: Sendable {
    let ok: Bool
    let message: String
    /// `data` 字段的原始 JSON；没有就是 nil。
    let data: Data?

    /// `snakeCase` 会把**字典的键**也一起改写（`recruit_times` → `recruitTimes`），
    /// 所以含「键是配置名 / 文件名」的字典的形状要传 false，自己写 CodingKeys。
    func decode<T: Decodable>(_ type: T.Type, snakeCase: Bool = true) throws -> T {
        guard let data else { throw RemoteBridgeError.badReceipt("回执里没有 data") }
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        return try decoder.decode(T.self, from: data)
    }

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

    var errorDescription: String? {
        switch self {
        case let .notDeployed(path):
            return "找不到 maa-remote 的脚本：\(path)"
        case let .launchFailed(detail):
            return "起不来 maa_action.py：\(detail)"
        case let .timedOut(args):
            return "maa_action.py \(args.joined(separator: " ")) 超时"
        case let .badReceipt(detail):
            return "maa_action.py 的回执读不懂：\(detail)"
        }
    }
}

enum RemoteBridge {
    /// 跑一条命令。`timeout` 默认 30 秒；`copilot preview`、`upstream status --online` 要给长一点。
    static func run(_ args: [String], timeout: TimeInterval = 30) async throws -> RemoteReceipt {
        let script = RemoteConfig.actionScript.path
        guard FileManager.default.fileExists(atPath: script) else {
            throw RemoteBridgeError.notDeployed(script)
        }
        let python = RemoteConfig.python
        let env = RemoteConfig.environment()
        let cwd = RemoteConfig.hermesHome
        return try await Task.detached(priority: .userInitiated) {
            try runBlocking(python: python, script: script, args: args, env: env, cwd: cwd, timeout: timeout)
        }.value
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
            throw RemoteBridgeError.badReceipt(tail.isEmpty ? "退出码 \(status)" : tail)
        }
        var data: Data?
        if let payload = object["data"], !(payload is NSNull) {
            data = try? JSONSerialization.data(withJSONObject: payload)
        }
        return RemoteReceipt(ok: ok, message: object["message"] as? String ?? "", data: data)
    }
}
