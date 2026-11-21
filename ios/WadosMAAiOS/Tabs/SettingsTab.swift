//
//  SettingsTab.swift
//  Wado's MAA (iOS)
//
//  外壳阶段：连接卡片、连接详情（E30）和 Debug 演示场景。其他设置在 F5。
//

import SwiftUI
import WadosMAAShared

struct SettingsTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            List {
                Section {
                    Button {
                        store.isConnectionDetailPresented = true
                    } label: {
                        HStack {
                            Image(systemName: "macmini")
                                .foregroundStyle(Palette.accent)
                                .frame(width: 28)
                            Text("Mac mini")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Text(store.connection.summary)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                #if DEBUG
                Section("演示数据") {
                    ForEach(DemoScenario.allCases) { scenario in
                        Button {
                            store.startDemo(scenario)
                        } label: {
                            HStack {
                                Text(scenario.title).foregroundStyle(Color.primary)
                                Spacer()
                                if store.demoScenario == scenario {
                                    Image(systemName: "checkmark").foregroundStyle(Palette.accent)
                                }
                            }
                        }
                    }
                    if store.demoScenario != nil {
                        Button("退出演示", role: .destructive) { store.stopDemo() }
                    }
                }
                #endif
            }
            .connectionBanner()
            .navigationTitle("设置")
            .navigationDestination(isPresented: $store.isConnectionDetailPresented) {
                ConnectionDetailView()
            }
        }
    }
}

extension ConnectionState {
    var summary: String {
        switch self {
        case .connecting: "连接中"
        case let .online(route, latency): "\(route == .lan ? "局域网" : "远程") · \(latency) ms"
        case .offline: "离线"
        case .tokenInvalid: "Token 失效"
        case .certificateMismatch: "证书不匹配"
        case .tunnelDown: "隧道不通"
        }
    }
}

private struct ConnectionDetailView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("局域网") {
                LabeledContent("地址", value: store.config?.lanURL.absoluteString ?? "")
                LabeledContent("主指纹", value: mask(store.config?.primaryPin))
                if let backup = store.config?.backupPin, !backup.isEmpty {
                    LabeledContent("备指纹", value: mask(backup))
                }
            }
            Section("远程") {
                LabeledContent("域名", value: store.config?.remoteURL.host() ?? "")
            }
            Section("鉴权") {
                LabeledContent("Token", value: "••••••••")
            }
            Section {
                Button {
                    Task { await store.testConnection() }
                } label: {
                    HStack {
                        Text("测试连接")
                        Spacer()
                        if store.isTestingConnection {
                            ProgressView()
                        } else {
                            Text(store.connection.summary)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
                .disabled(store.isTestingConnection)
                Button("重新配对") {
                    store.isPairingPresented = true
                }
            }
        }
        .navigationTitle("连接")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mask(_ pin: String?) -> String {
        guard let pin, pin.count > 8 else { return "" }
        return "\(pin.prefix(4))…\(pin.suffix(4))"
    }
}
