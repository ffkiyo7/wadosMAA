//
//  X509SPKI.swift
//  WadosMAAShared
//
//  从 X.509 证书 DER 里原样取出 SubjectPublicKeyInfo，供 SPKI 指纹固定使用。
//  只走 DER 外层结构，不解释算法，所以 EC / RSA 都通用。
//

import Foundation

public enum X509SPKI {
    private struct Element {
        let tag: UInt8
        let start: Int
        let contentStart: Int
        let end: Int
    }

    public static func extract(fromCertificate der: Data) -> Data? {
        let bytes = [UInt8](der)
        guard let certificate = element(bytes, at: 0), certificate.tag == 0x30, certificate.end == bytes.count,
            let tbs = element(bytes, at: certificate.contentStart), tbs.tag == 0x30, tbs.end <= certificate.end
        else { return nil }
        var offset = tbs.contentStart
        if let version = element(bytes, at: offset), version.tag == 0xA0 {
            offset = version.end
        }
        // serialNumber、signature、issuer、validity、subject
        for _ in 0..<5 {
            guard let field = element(bytes, at: offset), field.end <= tbs.end else { return nil }
            offset = field.end
        }
        guard let spki = element(bytes, at: offset), spki.tag == 0x30, spki.end <= tbs.end else { return nil }
        return Data(bytes[spki.start..<spki.end])
    }

    private static func element(_ bytes: [UInt8], at start: Int) -> Element? {
        guard start >= 0, start + 2 <= bytes.count else { return nil }
        let tag = bytes[start]
        // 只支持单字节 tag；X.509 外层结构都是。
        guard tag & 0x1F != 0x1F else { return nil }
        var cursor = start + 1
        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        let end = cursor + length
        guard end <= bytes.count else { return nil }
        return Element(tag: tag, start: start, contentStart: cursor, end: end)
    }
}
