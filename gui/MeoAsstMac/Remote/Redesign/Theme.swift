//
//  Theme.swift
//  Wado's MAA
//
//  重设计（定稿原型 E）：深色、金色强调色。颜色、卡片、按钮和「会连游戏」的确认框都在这里。
//  会连游戏的操作统一用 ⚡ + 确认框，标记色固定珊瑚色，不随强调色变。
//

import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

enum WM {
    static let win = Color(hex: 0x141417)
    static let side = Color(hex: 0x1a1a1e)
    static let panel = Color(hex: 0x1f1f24)
    static let raise = Color(hex: 0x29292f)
    static let line = Color.white.opacity(0.08)
    static let line2 = Color.white.opacity(0.14)
    static let f2 = Color(hex: 0xebebf5, opacity: 0.62)
    static let f3 = Color(hex: 0xebebf5, opacity: 0.4)
    /// 会连接游戏：固定珊瑚色。
    static let game = Color(hex: 0xff7a59)
    static let ok = Color(hex: 0x5ad37a)
    static let danger = Color(hex: 0xff8a7a)

    static let accentKey = "WMAccent"
    static let logKey = "WMShowLog"
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case gold, cyan, rose, blue, violet

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gold: "暮光金"
        case .cyan: "源石青"
        case .rose: "玫瑰红"
        case .blue: "天青蓝"
        case .violet: "薰衣紫"
        }
    }

    var color: Color {
        switch self {
        case .gold: Color(hex: 0xf5c04a)
        case .cyan: Color(hex: 0x34e0c8)
        case .rose: Color(hex: 0xff4d6d)
        case .blue: Color(hex: 0x5aa9ff)
        case .violet: Color(hex: 0xb49cff)
        }
    }

    /// 强调色底上的字色。
    var ink: Color {
        switch self {
        case .gold: Color(hex: 0x2a1c00)
        case .cyan: Color(hex: 0x04221e)
        case .rose: Color(hex: 0x2a0410)
        case .blue: Color(hex: 0x04182e)
        case .violet: Color(hex: 0x1b0f3a)
        }
    }
}

extension EnvironmentValues {
    @Entry var wmAccent: AccentChoice = .gold
    /// 弹「会连游戏」确认框。
    @Entry var askGame: (GameConfirm) -> Void = { _ in }
}

// MARK: - 关卡色块（只作识别，不当主视觉）

enum StageSwatch {
    static func colors(_ code: String) -> (Color, Color) {
        let upper = code.uppercased()
        if upper.hasPrefix("YW") { return (Color(hex: 0x2fa79a), Color(hex: 0x0b2f3c)) }
        if upper.hasPrefix("TL") { return (Color(hex: 0xe07a3a), Color(hex: 0x5a1f12)) }
        if upper.hasPrefix("CE") { return (Color(hex: 0xd4a833), Color(hex: 0x4a3a0c)) }
        if upper.hasPrefix("LS") { return (Color(hex: 0x4f74e6), Color(hex: 0x162350)) }
        if upper.hasPrefix("CA") || upper.hasPrefix("SK") || upper.hasPrefix("AP") {
            return (Color(hex: 0x3fa7d9), Color(hex: 0x10324a))
        }
        if upper.isEmpty { return (Color(hex: 0x6b6b75), Color(hex: 0x2a2a30)) }
        return (Color(hex: 0x6a5fe0), Color(hex: 0x1c1f3a))
    }
}

struct Swatch: View {
    let code: String
    var size: CGFloat = 18
    var radius: CGFloat = 5

    var body: some View {
        let (a, b) = StageSwatch.colors(code)
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
    }
}

// MARK: - 卡片

struct WMCard: ViewModifier {
    var radius: CGFloat = 14
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(AppearanceKeys.glass) private var glass = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if glass, !(lightPath.isEmpty && darkPath.isEmpty) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(WM.panel, in: shape)
                .overlay(shape.strokeBorder(WM.line, lineWidth: 0.5))
        }
    }
}

extension View {
    func wmCard(radius: CGFloat = 14) -> some View { modifier(WMCard(radius: radius)) }
}

// MARK: - 按钮

struct WMButtonStyle: ButtonStyle {
    enum Kind { case normal, accent, big, danger }
    var kind: Kind = .normal
    @Environment(\.wmAccent) private var accent
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let big = kind == .big
        let filled = kind == .accent || kind == .big
        configuration.label
            .font(.system(size: big ? 14 : 13, weight: .semibold))
            .labelStyle(WMLabelStyle())
            .padding(.horizontal, big ? 20 : 14)
            .frame(height: big ? 38 : 30)
            .foregroundStyle(filled ? accent.ink : kind == .danger ? WM.danger : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: big ? 10 : 8, style: .continuous)
                    .fill(filled ? accent.color : WM.raise)
                    .brightness(configuration.isPressed ? -0.08 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: big ? 10 : 8, style: .continuous)
                    .strokeBorder(filled ? Color.clear : WM.line2, lineWidth: 0.5))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct WMLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// 文字链接样式（强调色）。
struct WMLinkStyle: ButtonStyle {
    @Environment(\.wmAccent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(accent.color)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - 会连游戏的确认

struct GameConfirm: Identifiable {
    let id = UUID()
    let title: String
    var rows: [(String, String)] = []
    let ok: String
    let action: () -> Void
}

/// 带 ⚡ 的按钮：点了先弹确认框，确认后才执行。
struct GameButton: View {
    let title: String
    let help: String
    var big = false
    var fullWidth = false
    let confirm: () -> GameConfirm

    @Environment(\.askGame) private var askGame

    var body: some View {
        Button {
            askGame(confirm())
        } label: {
            Label(title, systemImage: "bolt.fill")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(WMButtonStyle(kind: big ? .big : .accent))
        .help(help)
    }
}

/// 确认框本体。确认键不绑回车（「确认开打」等不能被回车误触）；Esc 取消。
struct GameConfirmSheet: View {
    let confirm: GameConfirm
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").foregroundStyle(WM.game)
                        .help("会连接游戏")
                    Text(confirm.title).font(.system(size: 16, weight: .bold))
                }
                if !confirm.rows.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(confirm.rows.indices, id: \.self) { index in
                            GridRow {
                                Text(confirm.rows[index].0).foregroundStyle(WM.f3)
                                Text(confirm.rows[index].1).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.system(size: 12.5))
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("取消", action: close)
                        .buttonStyle(WMButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button(confirm.ok) {
                        close()
                        confirm.action()
                    }
                    .buttonStyle(WMButtonStyle(kind: .accent))
                }
                .padding(.top, 4)
            }
            .padding(20)
            .frame(width: 360)
            .background(Color(hex: 0x232328), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(WM.line2, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.6), radius: 35, y: 15)
        }
    }
}

// MARK: - 页面零件

struct PageHeader<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 28, weight: .bold)).tracking(-0.5)
            if let caption { Text(caption).font(.system(size: 13)).foregroundStyle(WM.f2) }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.bottom, 18)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption) { EmptyView() }
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .bold))
            if let caption { Text(caption).font(.system(size: 11.5)).foregroundStyle(WM.f2) }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.bottom, 10)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String, caption: String? = nil) {
        self.init(title: title, caption: caption) { EmptyView() }
    }
}

/// 小标签（「关卡」「环节」）。
struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(WM.f3)
    }
}

/// 表单组：组名 + 一张卡片，行之间细分隔线。
struct FormGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title, !title.isEmpty {
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(WM.f3)
                    .padding(.leading, 14)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews.indices, id: \.self) { index in
                        if index > 0 { Rectangle().fill(WM.line).frame(height: 1) }
                        subviews[index]
                    }
                }
            }
            .wmCard()
        }
        .padding(.top, 20)
    }
}

struct FormRow<Control: View>: View {
    let title: String
    var sub: String?
    var help: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let sub, !sub.isEmpty {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(help ?? "")
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
    }
}

/// − 数值 + 单位。
struct WMStepper: View {
    @Binding var value: Double
    var step: Double = 1
    var range: ClosedRange<Double> = 0...1_000_000
    var unit: String = ""
    let label: String

    var body: some View {
        HStack(spacing: 0) {
            Button("−") { value = max(range.lowerBound, (value - step).rounded6) }
                .help("\(label)减少")
            Text(format(value))
                .fontWeight(.semibold).monospacedDigit()
                .frame(minWidth: 44)
                .overlay(alignment: .leading) { Rectangle().fill(WM.line).frame(width: 1) }
                .overlay(alignment: .trailing) { Rectangle().fill(WM.line).frame(width: 1) }
            Button("+") { value = min(range.upperBound, (value + step).rounded6) }
                .help("\(label)增加")
            if !unit.isEmpty {
                Text(unit).font(.system(size: 12)).foregroundStyle(WM.f2).frame(minWidth: 34)
            }
        }
        .buttonStyle(StepperKeyStyle())
        .frame(height: 28)
        .background(WM.raise, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WM.line2, lineWidth: 0.5))
    }

    private func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.2g", v)
    }
}

private struct StepperKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15))
            .foregroundStyle(configuration.isPressed ? Color.primary : WM.f2)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

private extension Double {
    var rounded6: Double { (self * 1_000_000).rounded() / 1_000_000 }
}

/// 列表卡里一行和下一行之间的分隔线。
struct RowDivider: View {
    var body: some View { Rectangle().fill(WM.line).frame(height: 1) }
}

/// 回执提示条（成功灰、失败红），可关。
struct NoticeLine: View {
    let ok: Bool
    let text: String
    var close: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle" : "xmark.octagon")
                .help(ok ? "成功" : "失败")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭提示")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(ok ? WM.f2 : WM.danger)
    }
}

extension View {
    /// 页面自己的回执：成功的几秒后清掉，失败的留着。
    /// 换了新回执时 `.task(id:)` 会先取消旧的计时，旧计时不会清掉新回执。
    func autoDismiss(_ receipt: (ok: Bool, text: String)?, clear: @escaping () -> Void) -> some View {
        task(id: receipt.map { "\($0.ok)\u{1}\($0.text)" }) {
            guard receipt?.ok == true else { return }
            try? await Task.sleep(for: RemoteStore.noticeLifetime)
            guard !Task.isCancelled else { return }
            clear()
        }
    }
}

/// 北京时间的日期工具。
enum Beijing {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = RunLock.beijing
        return calendar
    }

    static func todayCaption(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = RunLock.beijing
        formatter.dateFormat = "M 月 d 日 EEEE"
        return formatter.string(from: date)
    }

    static func monthDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(parts.month ?? 0) 月 \(parts.day ?? 0) 日"
    }

    static func until(_ date: Date, from now: Date = .now) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后" }
        return "\(minutes) 分钟后"
    }

    /// 今天（北京时间）的 HH:mm。
    static func today(at hhmm: String, now: Date = .now) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
    }
}
