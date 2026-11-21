//
//  HTTPTransport.swift
//  Wado's MAA (iOS)
//
//  双轨 HTTPS：先探局域网（800ms，SPKI 指纹固定），不通再走 Cloudflare 隧道（系统 CA）。
//  指纹校验发生在 TLS 握手阶段，先于任何 HTTP Header，所以伪造的局域网主机拿不到 Token。
//

import CryptoKit
import Foundation
import Security
import Synchronization
import WadosMAAShared

enum TransportRoute: Equatable, Sendable {
    case lan, remote
}

struct ProbeResult: Equatable, Sendable {
    let route: TransportRoute
    let latencyMilliseconds: Int
    /// 局域网这次指纹没对上（已自动走远程）。
    let lanPinMismatch: Bool
}

enum TransportFailure: Error, Equatable, Sendable {
    case offline
    case unauthorized
    case certificateMismatch
    case tunnelDown
    case badResponse
}

enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", delete = "DELETE"
}

protocol BackendTransport: Sendable {
    func probe() async throws -> ProbeResult
    func read(_ path: String, query: [URLQueryItem]) async throws -> Data
    func send(_ method: HTTPMethod, _ path: String, body: [String: any Sendable]?, timeout: TimeInterval) async throws
        -> RemoteReceipt
    func events() async throws -> AsyncThrowingStream<SSEEvent, Error>
}

/// 只对局域网主机做指纹固定；远程走系统默认校验。一律拒绝跳转，防止 Token 被带到别的主机。
private final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let lanHost: String
    private let pins: Set<String>
    private let mismatch = Mutex(false)

    init(lanHost: String, pins: Set<String>) {
        self.lanHost = lanHost
        self.pins = pins
    }

    func resetMismatch() {
        mismatch.withLock { $0 = false }
    }

    var sawMismatch: Bool {
        mismatch.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            challenge.protectionSpace.host == lanHost
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust, Self.leafPin(trust).map(pins.contains) == true else {
            mismatch.withLock { $0 = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func leafPin(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
            let spki = X509SPKI.extract(fromCertificate: SecCertificateCopyData(leaf) as Data)
        else { return nil }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }
}

actor HTTPTransport: BackendTransport {
    private let config: ConnectionConfig
    private let credentials: ConnectionCredentials
    private let delegate: PinningDelegate
    private let session: URLSession
    private var route: TransportRoute?

    private static let lanProbeTimeout: TimeInterval = 0.8
    private static let remoteProbeTimeout: TimeInterval = 6
    /// 服务端 25 秒一次心跳；这么久没有任何字节就当断了。
    private static let eventIdleTimeout: TimeInterval = 70

    init(config: ConnectionConfig, credentials: ConnectionCredentials) {
        self.config = config
        self.credentials = credentials
        let delegate = PinningDelegate(lanHost: config.lanURL.host() ?? "", pins: config.pins)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func probe() async throws -> ProbeResult {
        delegate.resetMismatch()
        if let latency = await health(config.lanURL, timeout: Self.lanProbeTimeout, route: .lan).latency {
            route = .lan
            return ProbeResult(route: .lan, latencyMilliseconds: latency, lanPinMismatch: false)
        }
        let lanPinMismatch = delegate.sawMismatch
        let remote = await health(config.remoteURL, timeout: Self.remoteProbeTimeout, route: .remote)
        if let latency = remote.latency {
            route = .remote
            return ProbeResult(route: .remote, latencyMilliseconds: latency, lanPinMismatch: lanPinMismatch)
        }
        route = nil
        if lanPinMismatch { throw TransportFailure.certificateMismatch }
        throw remote.reachedEdge ? TransportFailure.tunnelDown : TransportFailure.offline
    }

    func read(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let (data, response) = try await perform(try request(.get, path, query: query, timeout: 15))
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw TransportFailure.unauthorized
        case 500...: throw failureForServerError()
        default: throw TransportFailure.badResponse
        }
    }

    func send(
        _ method: HTTPMethod, _ path: String, body: [String: any Sendable]?, timeout: TimeInterval = 30
    ) async throws -> RemoteReceipt {
        var request = try request(method, path, query: [], timeout: timeout)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await perform(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw TransportFailure.unauthorized }
        if let receipt = RemoteReceipt(json: data) { return receipt }
        if response.statusCode >= 500 { throw failureForServerError() }
        throw TransportFailure.badResponse
    }

    func events() async throws -> AsyncThrowingStream<SSEEvent, Error> {
        var request = try request(.get, "/api/v1/events", query: [], timeout: Self.eventIdleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw TransportFailure.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw TransportFailure.unauthorized }
        guard http.statusCode == 200 else {
            throw http.statusCode >= 500 ? failureForServerError() : TransportFailure.badResponse
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                var line: [UInt8] = []
                do {
                    // `bytes.lines` 会吞掉空行，而空行正是 SSE 的事件分隔符，所以按字节切。
                    for try await byte in bytes {
                        guard byte == 0x0A else {
                            line.append(byte)
                            continue
                        }
                        if let event = parser.feed(line: String(decoding: line, as: UTF8.self)) {
                            continuation.yield(event)
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 内部

    private func health(_ base: URL, timeout: TimeInterval, route: TransportRoute) async -> (
        latency: Int?, reachedEdge: Bool
    ) {
        var request = URLRequest(url: base.appending(path: "healthz"), timeoutInterval: timeout)
        applyAccessHeaders(&request, route: route)
        let clock = ContinuousClock()
        let started = clock.now
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse
        else { return (nil, false) }
        guard http.statusCode == 200,
            let status = try? JSONDecoder().decode(HealthStatus.self, from: data),
            status.ok, status.service == "wados-maa"
        else { return (nil, true) }
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        return (max(milliseconds, 1), true)
    }

    private func request(
        _ method: HTTPMethod, _ path: String, query: [URLQueryItem], timeout: TimeInterval
    ) throws -> URLRequest {
        guard let route else { throw TransportFailure.offline }
        let base = route == .lan ? config.lanURL : config.remoteURL
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        applyAccessHeaders(&request, route: route)
        return request
    }

    /// CF Access 凭据只发给远程。
    private func applyAccessHeaders(_ request: inout URLRequest, route: TransportRoute) {
        guard route == .remote, credentials.hasCloudflareAccess else { return }
        request.setValue(credentials.cfAccessClientId, forHTTPHeaderField: "CF-Access-Client-Id")
        request.setValue(credentials.cfAccessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransportFailure.badResponse }
            return (data, http)
        } catch {
            throw mapped(error)
        }
    }

    private func failureForServerError() -> TransportFailure {
        route == .remote ? .tunnelDown : .badResponse
    }

    private func mapped(_ error: Error) -> Error {
        if error is TransportFailure || error is CancellationError { return error }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            if delegate.sawMismatch {
                route = nil
                return TransportFailure.certificateMismatch
            }
            return CancellationError()
        }
        route = nil
        return TransportFailure.offline
    }
}
