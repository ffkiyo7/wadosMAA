//
//  ConnectionConfig.swift
//  Wado's MAA (iOS)
//
//  连接配置：地址和指纹不是秘密，放 UserDefaults；Token 和 CF Access 凭据只进 Keychain。
//

import Foundation
import Security
import WadosMAAShared

struct ConnectionConfig: Codable, Equatable, Sendable {
    var lanURL: URL
    var remoteURL: URL
    /// SPKI SHA-256 的 Base64：主指纹。
    var primaryPin: String
    /// 轮换证书时的备用指纹；没有就空着。
    var backupPin: String

    var pins: Set<String> {
        Set([primaryPin, backupPin].filter { !$0.isEmpty })
    }

    private static let defaultsKey = "connection.config.v1"

    static func load() -> ConnectionConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        LastDataCache.removeStored()
    }

    static func isPin(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }

    /// 按快照的 `tls` 更新指纹；不用改返回 nil。
    /// - 服务端换上了备指纹那张：提升为主指纹；
    /// - 服务端预生成了下一张、本地还没记：记成备指纹。
    func adopting(_ tls: TLSStatus) -> ConnectionConfig? {
        let served = tls.spkiSHA256.flatMap { Self.isPin($0) ? $0 : nil }
        let staged = tls.nextSPKISHA256.flatMap { Self.isPin($0) ? $0 : nil }
        var next = self
        if let served, served == backupPin, served != primaryPin {
            next.primaryPin = served
            next.backupPin = staged.flatMap { $0 == served ? nil : $0 } ?? ""
        } else if let staged, staged != primaryPin, staged != backupPin {
            next.backupPin = staged
        }
        return next == self ? nil : next
    }
}

struct ConnectionCredentials: Equatable, Sendable {
    var token: String
    var cfAccessClientId: String
    var cfAccessClientSecret: String

    var hasCloudflareAccess: Bool {
        !cfAccessClientId.isEmpty && !cfAccessClientSecret.isEmpty
    }

    static func load() -> ConnectionCredentials? {
        guard let token = KeychainStore.read(.token), !token.isEmpty else { return nil }
        return ConnectionCredentials(
            token: token,
            cfAccessClientId: KeychainStore.read(.cfAccessClientId) ?? "",
            cfAccessClientSecret: KeychainStore.read(.cfAccessClientSecret) ?? "")
    }

    @discardableResult
    func save() -> Bool {
        KeychainStore.write(token, for: .token)
            && KeychainStore.write(cfAccessClientId, for: .cfAccessClientId)
            && KeychainStore.write(cfAccessClientSecret, for: .cfAccessClientSecret)
    }

    static func clear() {
        KeychainStore.Key.allCases.forEach(KeychainStore.delete)
    }
}

enum KeychainStore {
    enum Key: String, CaseIterable {
        case token = "full-token"
        case cfAccessClientId = "cf-access-client-id"
        case cfAccessClientSecret = "cf-access-client-secret"
    }

    private static let service = "io.github.ffkiyo7.WadosMAAiOS.connection"

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    static func read(_ key: Key) -> String? {
        var request = query(key)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 空字符串等于删除。
    @discardableResult
    static func write(_ value: String, for key: Key) -> Bool {
        guard !value.isEmpty else {
            delete(key)
            return true
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = query(key)
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: Key) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

extension PairingPayload {
    var config: ConnectionConfig {
        ConnectionConfig(lanURL: lanURL, remoteURL: remoteURL, primaryPin: spkiSHA256, backupPin: "")
    }
}
