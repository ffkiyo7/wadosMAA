//
//  ConnectionBanner.swift
//  Wado's MAA (iOS)
//
//  连接异常（E16）：继续显示旧数据，写操作由 `AppStore.canWrite` 禁用。
//

import SwiftUI
import WadosMAAShared

extension View {
    /// 断连时内容整体变暗，横幅和连接入口不套这个。
    func dimmedWhenDisconnected() -> some View {
        modifier(DisconnectedDim())
    }
}

private struct DisconnectedDim: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.opacity(store.isDisconnected ? 0.5 : 1)
    }
}

/// 放在每个 Tab 滚动内容的最顶部，随内容滚走。
struct ConnectionBanner: View {
    @Environment(AppStore.self) private var store

    private struct Content {
        let symbol: String
        let title: String
        let action: String
        let run: @MainActor (AppStore) -> Void
    }

    private var content: Content? {
        let retry: @MainActor (AppStore) -> Void = { $0.reconnect() }
        let detail: @MainActor (AppStore) -> Void = {
            $0.selectedTab = .settings
            $0.isConnectionDetailPresented = true
        }
        switch store.connection {
        case .offline:
            return Content(symbol: "wifi.slash", title: "Mac mini 离线", action: "重试", run: retry)
        case .tokenInvalid:
            return Content(symbol: "key.slash", title: "Token 失效", action: "重新配对") {
                $0.isPairingPresented = true
            }
        case .certificateMismatch:
            return Content(symbol: "lock.trianglebadge.exclamationmark", title: "证书不匹配", action: "查看", run: detail)
        case .tunnelDown:
            return Content(symbol: "icloud.slash", title: "隧道不通", action: "重试", run: retry)
        case .online:
            guard store.lanPinMismatch else { return nil }
            return Content(symbol: "lock.trianglebadge.exclamationmark", title: "局域网证书不匹配", action: "查看", run: detail)
        case .connecting:
            return nil
        }
    }

    /// 不是今天的数据要带上日期，否则会被当成今天的。
    private func dataTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = BeijingTime.zone
        let clock = BeijingTime.clock(date)
        guard !calendar.isDate(date, inSameDayAs: Date()) else { return clock }
        let day = calendar.dateComponents([.month, .day], from: date)
        return "\(day.month ?? 0)月\(day.day ?? 0)日 \(clock)"
    }

    var body: some View {
        if let content {
            HStack(spacing: 12) {
                Image(systemName: content.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.red)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                    if !store.connection.isOnline, let updated = store.lastUpdatedAt {
                        Text("\(dataTime(updated)) 的数据")
                            .font(.caption)
                            .foregroundStyle(Palette.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button(content.action) { content.run(store) }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.glass)
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(minHeight: 56)
            .background(Palette.card, in: .rect(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}
