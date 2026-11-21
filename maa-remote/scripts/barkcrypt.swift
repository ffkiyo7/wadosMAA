// barkcrypt — 使用 macOS CryptoKit.AES.GCM 为 Bark 推送做端到端加密（零第三方 Python 依赖）。
//
// 协议（全部经 stdin JSON 传入，绝不经 argv 暴露敏感参数）：
//   加密（默认 action="encrypt"）：
//     stdin:  {"plaintext": "<JSON string>", "key": "<16或32位ASCII>", "iv": "<12位ASCII>"}
//     stdout: {"ciphertext": "<Base64(sealedBox.ciphertext + sealedBox.tag)>"}
//   解密（action="decrypt"，用于单测交叉校验）：
//     stdin:  {"action": "decrypt", "ciphertext": "<Base64>", "key": "<16或32位ASCII>", "iv": "<12位ASCII>"}
//     stdout: {"plaintext": "<UTF-8 string>"}
//
// 关键约束（严格对齐 Bark Algorithm.swift）：
//   1. Key 与 IV 直接取原始 UTF-8 字节（AES-128-GCM 16B / AES-256-GCM 32B，Nonce 12B）；
//   2. 严禁使用 sealedBox.combined（后者把 12 字节 nonce 拼在最前会导致 Bark 解密失败）；
//      显式输出 Base64(sealedBox.ciphertext + sealedBox.tag)。

import CryptoKit
import Foundation

struct Request: Decodable {
    let action: String?
    let plaintext: String?
    let ciphertext: String?
    let key: String
    let iv: String
}

struct EncryptResponse: Encodable {
    let ciphertext: String
}

struct DecryptResponse: Encodable {
    let plaintext: String
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let inputData = FileHandle.standardInput.readDataToEndOfFile()
guard !inputData.isEmpty else {
    fail("empty stdin")
}

let req: Request
do {
    req = try JSONDecoder().decode(Request.self, from: inputData)
} catch {
    fail("invalid json input: \(error.localizedDescription)")
}

let keyData = Data(req.key.utf8)
guard keyData.count == 16 || keyData.count == 32 else {
    fail("key must be 16 or 32 UTF-8 bytes, got \(keyData.count)")
}

let ivData = Data(req.iv.utf8)
guard ivData.count == 12 else {
    fail("iv must be 12 UTF-8 bytes, got \(ivData.count)")
}

let symmetricKey = SymmetricKey(data: keyData)
let nonce: AES.GCM.Nonce
do {
    nonce = try AES.GCM.Nonce(data: ivData)
} catch {
    fail("invalid nonce: \(error.localizedDescription)")
}

let action = req.action ?? "encrypt"
let encoder = JSONEncoder()

switch action {
case "encrypt":
    guard let plaintext = req.plaintext else {
        fail("missing plaintext")
    }
    do {
        let sealedBox = try AES.GCM.seal(Data(plaintext.utf8), using: symmetricKey, nonce: nonce)
        // 严禁使用 sealedBox.combined：Bark 要求 Base64(ciphertext + tag)，不含前导 nonce。
        var combinedPayload = Data()
        combinedPayload.reserveCapacity(sealedBox.ciphertext.count + sealedBox.tag.count)
        combinedPayload.append(sealedBox.ciphertext)
        combinedPayload.append(sealedBox.tag)
        let response = EncryptResponse(ciphertext: combinedPayload.base64EncodedString())
        let out = try encoder.encode(response)
        FileHandle.standardOutput.write(out)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("encrypt failed: \(error.localizedDescription)")
    }
case "decrypt":
    guard let b64 = req.ciphertext, let raw = Data(base64Encoded: b64) else {
        fail("invalid base64 ciphertext")
    }
    guard raw.count >= 16 else {
        fail("ciphertext too short")
    }
    let splitIndex = raw.count - 16
    let ct = raw.prefix(splitIndex)
    let tag = raw.suffix(16)
    do {
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        let opened = try AES.GCM.open(box, using: symmetricKey)
        guard let text = String(data: opened, encoding: .utf8) else {
            fail("decrypted payload is not valid UTF-8")
        }
        let response = DecryptResponse(plaintext: text)
        let out = try encoder.encode(response)
        FileHandle.standardOutput.write(out)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
        fail("decrypt failed: \(error.localizedDescription)")
    }
default:
    fail("unsupported action: \(action)")
}
