//
//  LastDataCache.swift
//  Wado's MAA (iOS)
//
//  最后一份成功读到的接口原文，断连冷启动时先显示。只存业务数据，不存 Token 等凭据；
//  放 Application Support 并排除备份。版本或配对对不上、文件损坏都当没有缓存。
//

import CryptoKit
import Foundation

struct LastDataCache {
    struct Payload: Codable {
        var version = LastDataCache.version
        var owner = ""
        var savedAt = Date.distantPast
        var snapshot: Data?
        var copilotStages: Data?
        var choices: Data?
        var history: Data?
        var config: Data?
        var defaults: Data?
    }

    static let version = 1
    private static let fileName = "last-data.json"

    private let owner: String
    private let url: URL?

    init(config: ConnectionConfig) {
        owner = Self.owner(of: config)
        url = Self.fileURL(Self.fileName)
    }

    #if DEBUG
    /// 演示模式用独立文件，碰不到真实缓存。
    private init(owner: String, fileName: String) {
        self.owner = owner
        url = Self.fileURL(fileName)
    }

    static let demo = LastDataCache(owner: "demo", fileName: "demo-last-data.json")
    #endif

    func load() -> Payload? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.version == Self.version, payload.owner == owner, payload.snapshot != nil
        else {
            remove()
            return nil
        }
        return payload
    }

    func save(_ payload: Payload) {
        guard let url else { return }
        var stamped = payload
        stamped.version = Self.version
        stamped.owner = owner
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            // 原子写会换掉文件，排除备份的标记每次都要重设。
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        } catch {
            // 缓存写不进去不影响主流程。
        }
    }

    func remove() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 删真实缓存，不管当前是不是演示模式。
    static func removeStored() {
        guard let url = fileURL(fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func fileURL(_ name: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "LastData", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    }

    private static func owner(of config: ConnectionConfig) -> String {
        let text = [config.lanURL.absoluteString, config.remoteURL.absoluteString, config.primaryPin, config.backupPin]
            .joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
