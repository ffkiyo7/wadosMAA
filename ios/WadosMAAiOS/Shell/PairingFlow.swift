//
//  PairingFlow.swift
//  Wado's MAA (iOS)
//
//  配对（E11）：扫码或手工填写 → 测试连接 → 保存。Token 只进 Keychain。
//

import SwiftUI
import VisionKit
import WadosMAAShared

struct PairingDraft: Equatable {
    var lan = ""
    var primaryPin = ""
    var backupPin = ""
    var remote = ""
    var token = ""
    var cfAccessClientId = ""
    var cfAccessClientSecret = ""

    init() {}

    init(payload: PairingPayload) {
        lan = payload.lanURL.absoluteString
        remote = payload.remoteURL.absoluteString
        primaryPin = payload.spkiSHA256
        token = payload.fullToken ?? ""
    }

    init(config: ConnectionConfig, credentials: ConnectionCredentials?) {
        lan = config.lanURL.absoluteString
        remote = config.remoteURL.absoluteString
        primaryPin = config.primaryPin
        backupPin = config.backupPin
        token = credentials?.token ?? ""
        cfAccessClientId = credentials?.cfAccessClientId ?? ""
        cfAccessClientSecret = credentials?.cfAccessClientSecret ?? ""
    }

    /// 扫到同一台 Mac 时保留码里没有的项；地址或指纹变了就不带，避免把旧凭据发给别的机器。
    func merging(_ payload: PairingPayload, saved: ConnectionConfig?) -> PairingDraft {
        var next = PairingDraft(payload: payload)
        guard let saved, Self.httpsURL(payload.lanURL.absoluteString) == saved.lanURL,
            Self.httpsURL(payload.remoteURL.absoluteString) == saved.remoteURL,
            saved.pins.contains(payload.spkiSHA256)
        else { return next }
        if next.token.isEmpty { next.token = token }
        next.backupPin = backupPin
        next.cfAccessClientId = cfAccessClientId
        next.cfAccessClientSecret = cfAccessClientSecret
        return next
    }

    var config: ConnectionConfig? {
        guard let lanURL = Self.httpsURL(lan), let remoteURL = Self.httpsURL(remote) else { return nil }
        let primary = primaryPin.trimmingCharacters(in: .whitespacesAndNewlines)
        let backup = backupPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPin(primary), backup.isEmpty || Self.isPin(backup) else { return nil }
        return ConnectionConfig(lanURL: lanURL, remoteURL: remoteURL, primaryPin: primary, backupPin: backup)
    }

    var credentials: ConnectionCredentials? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = cfAccessClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfAccessClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // CF Access 的两项要么都填，要么都空。
        guard !token.isEmpty, id.isEmpty == secret.isEmpty else { return nil }
        return ConnectionCredentials(token: token, cfAccessClientId: id, cfAccessClientSecret: secret)
    }

    var isValid: Bool {
        config != nil && credentials != nil
    }

    private static func isPin(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }

    private static func httpsURL(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host()?.isEmpty == false,
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }
}

struct PairingFlow: View {
    private enum Route: Hashable {
        case scan, manual, result
    }

    var isSheet = false
    /// 从连接详情进入：直接编辑当前配置。
    var opensEditor = false

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var draft = PairingDraft()
    @State private var isTesting = false
    @State private var testResult: Result<ProbeResult, TransportFailure>?
    @State private var saveFailed = false
    @State private var didPrefill = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if opensEditor { manualPage } else { landing }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .scan: scanPage
                case .manual: manualPage
                case .result: resultPage
                }
            }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
            }
        }
        .alert("没能保存到钥匙串", isPresented: $saveFailed) {
            Button("好", role: .cancel) {}
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        if let saved = store.pairedConfig {
            draft = PairingDraft(config: saved, credentials: ConnectionCredentials.load())
        }
    }

    // MARK: - 首屏

    private var landing: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "macmini")
                .scaledFont(size: 72, weight: .light)
                .foregroundStyle(Palette.accent)
                .padding(.bottom, 12)
            Text("连接 Mac mini")
                .scaledFont(size: 30, weight: .heavy)
            Spacer()
            Button {
                let canScan = DataScannerViewController.isSupported && DataScannerViewController.isAvailable
                path.append(canScan ? .scan : .manual)
            } label: {
                Label("扫码配对", systemImage: "qrcode.viewfinder")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Palette.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            Button {
                path.append(.manual)
            } label: {
                Text("手工填写")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    // MARK: - 扫码

    private var scanPage: some View {
        QRScanner { text in
            guard let payload = PairingPayload(text: text) else { return false }
            draft = draft.merging(payload, saved: store.pairedConfig)
            if draft.isValid {
                path = [.result]
                Task { await runTest() }
            } else {
                path = [.manual]
            }
            return true
        }
        .ignoresSafeArea()
        .navigationTitle("扫码配对")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 手工

    private var manualPage: some View {
        Form {
            Section("局域网") {
                field("地址", text: $draft.lan, keyboard: .URL)
                field("主证书指纹", text: $draft.primaryPin)
                field("备证书指纹", text: $draft.backupPin)
            }
            Section("远程") {
                field("域名", text: $draft.remote, keyboard: .URL)
            }
            Section("鉴权") {
                SecureField("Token", text: $draft.token)
                field("CF Access Client ID", text: $draft.cfAccessClientId)
                SecureField("CF Access Client Secret", text: $draft.cfAccessClientSecret)
            }
            Section {
                Button("测试连接") {
                    path.append(.result)
                    Task { await runTest() }
                }
                .disabled(!draft.isValid)
                Button("保存") { save() }
                    .fontWeight(.semibold)
                    .disabled(!draft.isValid)
            }
        }
        .navigationTitle(opensEditor ? "编辑连接" : "手工填写")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType = .asciiCapable) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }

    // MARK: - 结果

    private var resultPage: some View {
        VStack(spacing: 14) {
            Spacer()
            switch (isTesting, testResult) {
            case (true, _), (false, nil):
                ProgressView().controlSize(.large)
            case let (false, .success(probe)?):
                Image(systemName: "checkmark.circle.fill")
                    .scaledFont(size: 64)
                    .foregroundStyle(Palette.green)
                Text("已连接")
                    .scaledFont(size: 30, weight: .heavy)
                Text("\(probe.route == .lan ? "局域网" : "远程") · \(probe.latencyMilliseconds) ms")
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(Palette.secondary)
            case let (false, .failure(failure)?):
                Image(systemName: "xmark.circle.fill")
                    .scaledFont(size: 64)
                    .foregroundStyle(Palette.red)
                Text(Self.message(failure))
                    .scaledFont(size: 24, weight: .heavy)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            if case .success? = testResult, !isTesting {
                Button { save() } label: {
                    Text("开始使用")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Palette.accent, in: .capsule)
                }
                .buttonStyle(.plain)
            } else if case .failure? = testResult, !isTesting {
                Button("再试一次") { Task { await runTest() } }
                    .font(.headline)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func message(_ failure: TransportFailure) -> String {
        switch failure {
        case .offline: "连不上 Mac mini"
        case .unauthorized: "Token 不对"
        case .certificateMismatch: "证书指纹不匹配"
        case .tunnelDown: "隧道不通"
        case .badResponse: "服务返回异常"
        }
    }

    // MARK: - 动作

    private func runTest() async {
        guard let config = draft.config, let credentials = draft.credentials, !isTesting else { return }
        isTesting = true
        testResult = nil
        testResult = await AppStore.test(config: config, credentials: credentials)
        isTesting = false
    }

    private func save() {
        guard let config = draft.config, let credentials = draft.credentials else { return }
        guard store.completePairing(config: config, credentials: credentials) else {
            saveFailed = true
            return
        }
        store.isPairingPresented = false
        if isSheet { dismiss() }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    /// 返回 true 表示这个码有效，停止扫描。
    let onText: (String) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onText = onText
        if !controller.isScanning, !context.coordinator.finished {
            try? controller.startScanning()
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onText: (String) -> Bool
        var finished = false

        init(onText: @escaping (String) -> Bool) {
            self.onText = onText
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !finished else { return }
            for case let .barcode(code) in addedItems {
                guard let text = code.payloadStringValue, onText(text) else { continue }
                finished = true
                dataScanner.stopScanning()
                return
            }
        }
    }
}
