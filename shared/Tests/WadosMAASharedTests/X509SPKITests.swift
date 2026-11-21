import CryptoKit
import Foundation
import Testing

@testable import WadosMAAShared

@Suite struct X509SPKITests {
    /// OpenSSL 3 生成的一次性 P-256 自签证书（无对应线上用途）。
    private let certificate = "MIIBkTCCATagAwIBAgIUEyML7aJ+dA2xNqWbWslEg4/YI6owCgYIKoZIzj0EAwIwFTETMBEGA1UEAwwKd2Fkb3MtdGVzdDAeFw0yNjExMjExNzU5MTFaFw0zNjExMTgxNzU5MTFaMBUxEzARBgNVBAMMCndhZG9zLXRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQsOSE9ug/0levKR/+NO8TSUUht5dPz20yhe1WqTAHSD/jj4pgggPmu1Q0FfWNNYSeIRS6AbwVl/ygbFeYJzzrho2QwYjAdBgNVHQ4EFgQUbXr8n4lTfhAJ+YW0uQGdKn5+KQwwHwYDVR0jBBgwFoAUbXr8n4lTfhAJ+YW0uQGdKn5+KQwwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMAoGCCqGSM49BAMCA0kAMEYCIQCQNWW7CDuliUzERKHJfzpJqhSGJjsBy/O2YBEhdNP6nAIhAILAdSL6jM4zI5Bjf16pA6zoJb4uyRulfRw8SP5qILbG"
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64`。
    private let expectedPin = "nCZqj6bQNAB9181vhd3wYcCUift+Z7/t7L9LaaOpisQ="

    @Test func matchesOpenSSLFingerprint() throws {
        let der = try #require(Data(base64Encoded: certificate))
        let spki = try #require(X509SPKI.extract(fromCertificate: der))
        #expect(Data(SHA256.hash(data: spki)).base64EncodedString() == expectedPin)
    }

    @Test func rejectsMalformedInput() throws {
        #expect(X509SPKI.extract(fromCertificate: Data()) == nil)
        #expect(X509SPKI.extract(fromCertificate: Data([0x30, 0x82, 0xFF])) == nil)
        let der = try #require(Data(base64Encoded: certificate))
        #expect(X509SPKI.extract(fromCertificate: der.dropLast(10)) == nil)
    }
}
