//
//  RemoteReceipt.swift
//  WadosMAAShared
//
//  后端回执 `{"ok", "code", "message", "detail"?, "data"?}`：`code` 给程序判断，
//  `message` 给玩家看，`detail` 是技术细节，只进诊断信息，不上界面。
//

import Foundation

public struct RemoteReceiptDecodeError: LocalizedError, Sendable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? { "Wado's MAA 没有响应，请稍后再试。" }
}

public struct RemoteReceipt: Sendable {
    public let ok: Bool
    /// 稳定的短码（`session_soon`、`busy`…），按它分支，不比对 `message` 的措辞。旧版后端没有，按 ok 补成 `ok` / `failed`。
    public let code: String
    /// 给玩家看的一句话。
    public let message: String
    /// 技术细节（异常、路径）；只记进诊断信息。
    public let detail: String?
    /// `data` 字段的原始 JSON；没有就是 nil。
    public let data: Data?

    public init(ok: Bool, code: String, message: String, detail: String?, data: Data?) {
        self.ok = ok
        self.code = code
        self.message = message
        self.detail = detail
        self.data = data
    }

    /// 解析一行回执 JSON；不是回执就返回 nil。
    public init?(json: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let ok = object["ok"] as? Bool
        else { return nil }
        var payload: Data?
        if let value = object["data"], !(value is NSNull) {
            payload = try? JSONSerialization.data(withJSONObject: value)
        }
        self.init(
            ok: ok,
            code: (object["code"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (ok ? "ok" : "failed"),
            message: object["message"] as? String ?? "",
            detail: (object["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            data: payload)
    }

    /// `snakeCase` 会把**字典的键**也一起改写（`recruit_times` → `recruitTimes`），
    /// 所以含「键是配置名 / 文件名」的字典的形状要传 false，自己写 CodingKeys。
    public func decoded<T: Decodable>(_ type: T.Type, snakeCase: Bool = true) throws -> T {
        guard let data else { throw RemoteReceiptDecodeError(detail: "no data: \(message)") }
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw RemoteReceiptDecodeError(detail: "\(T.self): \(error)")
        }
    }

    /// `data` 当成字典读（配置页这种键不固定的场合）。
    public var dictionary: [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }
}
