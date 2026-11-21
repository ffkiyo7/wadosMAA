//
//  RunHistory.swift
//  Wado's MAA
//
//  场次索引：读 `$HERMES_HOME/state/maa/runs/index.jsonl`（DEV_GUIDE §12.3，不变量 #66）。
//  maa-remote 每场结束往里追加一行，GUI 只读不写。数据形状和解析在 `WadosMAAShared`。
//

import Foundation
import WadosMAAShared

extension RunFightResult {
    /// 路径 → (修改时间, 结果)。界面每次重画都会问，文件没变就不重读。
    @MainActor private static var cache: [String: (Date, RunFightResult?)] = [:]

    /// 首页场卡、近况热力格的气泡用；文件不在、读不懂、开始时刻对不上（同名旧场）都当没有。
    @MainActor static func read(_ path: String?, started: Date?) -> RunFightResult? {
        guard let path, !path.isEmpty,
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        let key = path + "|" + (started.map { String($0.timeIntervalSince1970) } ?? "")
        if let hit = cache[key], hit.0 == modified { return hit.1 }
        let result = parse(URL(fileURLWithPath: path), started: started)
        cache[key] = (modified, result)
        return result
    }

    private static func parse(_ url: URL, started: Date?) -> RunFightResult? {
        guard let data = try? Data(contentsOf: url),
            case let .object(file)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            let fight = file["fight"]?.object
        else { return nil }
        if let version = file["schema_version"]?.number, Int(version) > RunHistory.knownSchemaVersion { return nil }
        if let started, let fileStart = file["started_at"]?.string.flatMap(RunLock.parseISO),
            abs(fileStart.timeIntervalSince(started)) > 2
        {
            return nil
        }
        return RunFightResult(done: Int(fight["done"]?.number ?? 0), drops: drops(fight))
    }
}

extension RunHistory {
    static var file: URL { RemoteConfig.stateDirectory.appending(path: "runs/index.jsonl") }

    /// 最新的在前。文件不在、读不了就是空。
    static func read() -> [RunRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return parse(data)
    }
}
