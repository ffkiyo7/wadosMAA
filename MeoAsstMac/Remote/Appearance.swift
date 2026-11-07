//
//  Appearance.swift
//  Wado's MAA
//
//  S4（K9）：Liquid Glass 外壳和窗口背景图。
//
//  - 侧栏、工具栏用 macOS 26 SDK 自带的 Liquid Glass；内容栏和详情栏放在玻璃卡片里，背景图从后面透出来；
//  - 背景图整个窗口一张，从本地选文件，浅色 / 深色各一张，填充方式、遮罩和模糊程度都能调；
//  - 内容区里的控件不改。
//

import SwiftUI
import UniformTypeIdentifiers

enum BackgroundFill: String, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch
    case center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fill: "填满（裁切）"
        case .fit: "完整显示"
        case .stretch: "拉伸"
        case .center: "原尺寸居中"
        }
    }
}

enum AppearanceKeys {
    static let lightImage = "BackgroundImageLight"
    static let darkImage = "BackgroundImageDark"
    static let fill = "BackgroundFill"
    static let dim = "BackgroundDim"
    static let blur = "BackgroundBlur"
    static let glass = "GlassCards"
}

/// 窗口背景：按当前浅色 / 深色挑一张图。
/// 没设图、或者图读不出来时，画系统的窗口底色。`containerBackground(for: .window)` 会顶掉系统底色，
/// 这里要是什么都不画，窗口就是透明的，会直接露出桌面。
struct WindowBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(AppearanceKeys.fill) private var fill = BackgroundFill.fill
    @AppStorage(AppearanceKeys.dim) private var dim = 0.25
    @AppStorage(AppearanceKeys.blur) private var blur = 0.0

    private var path: String {
        let preferred = colorScheme == .dark ? darkPath : lightPath
        return preferred.isEmpty ? (colorScheme == .dark ? lightPath : darkPath) : preferred
    }

    var body: some View {
        GeometryReader { proxy in
            if let image = NSImage(contentsOfFile: path) {
                ZStack {
                    imageView(image, size: proxy.size)
                        .blur(radius: blur, opaque: true)
                    Rectangle()
                        .fill(colorScheme == .dark ? Color.black : Color.white)
                        .opacity(dim)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private func imageView(_ image: NSImage, size: CGSize) -> some View {
        let base = Image(nsImage: image)
        switch fill {
        case .fill:
            base.resizable().aspectRatio(contentMode: .fill).frame(width: size.width, height: size.height)
        case .fit:
            base.resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height)
        case .stretch:
            base.resizable().frame(width: size.width, height: size.height)
        case .center:
            base.frame(width: size.width, height: size.height)
        }
    }

    static var isConfigured: Bool {
        let defaults = UserDefaults.standard
        return !(defaults.string(forKey: AppearanceKeys.lightImage) ?? "").isEmpty
            || !(defaults.string(forKey: AppearanceKeys.darkImage) ?? "").isEmpty
    }
}

/// 有背景图时：列表 / 表单不画自己的底，整栏放进一张玻璃卡片。
struct GlassColumn: ViewModifier {
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(AppearanceKeys.glass) private var glass = true

    private var hasBackground: Bool { !lightPath.isEmpty || !darkPath.isEmpty }

    func body(content: Content) -> some View {
        if hasBackground {
            content
                .scrollContentBackground(.hidden)
                .background(.clear)
                .modifier(OptionalGlass(enabled: glass))
        } else {
            content
        }
    }
}

private struct OptionalGlass: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(.rect(cornerRadius: 16))
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .padding(8)
        } else {
            content
        }
    }
}

extension View {
    func glassColumn() -> some View { modifier(GlassColumn()) }
}

// MARK: - 设置页

struct AppearanceSettingsView: View {
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(AppearanceKeys.fill) private var fill = BackgroundFill.fill
    @AppStorage(AppearanceKeys.dim) private var dim = 0.25
    @AppStorage(AppearanceKeys.blur) private var blur = 0.0
    @AppStorage(AppearanceKeys.glass) private var glass = true

    @State private var showImporter = false
    @State private var pickingDark = false

    var body: some View {
        Form {
            Section("背景图") {
                imageRow(title: "浅色模式", path: $lightPath, dark: false)
                imageRow(title: "深色模式", path: $darkPath, dark: true)
            }
            Section("显示") {
                Picker("填充方式", selection: $fill) {
                    ForEach(BackgroundFill.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("遮罩") {
                    Slider(value: $dim, in: 0...0.85) { Text("遮罩") } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("85%")
                    }
                    .labelsHidden()
                }
                LabeledContent("模糊") {
                    Slider(value: $blur, in: 0...40) { Text("模糊") }.labelsHidden()
                }
                Toggle("内容区用玻璃卡片", isOn: $glass)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            if pickingDark { darkPath = url.path } else { lightPath = url.path }
        }
    }

    private func imageRow(title: String, path: Binding<String>, dark: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue.isEmpty ? "未设置" : (path.wrappedValue as NSString).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("选择…") {
                    pickingDark = dark
                    showImporter = true
                }
                if !path.wrappedValue.isEmpty {
                    Button("清除") { path.wrappedValue = "" }
                }
            }
        }
    }
}

/// maa-remote 在哪（S7 切线上时在这里改）。
struct RemoteSettingsView: View {
    @AppStorage(RemoteConfig.hermesHomeKey) private var hermesHome = ""
    @AppStorage(RemoteConfig.pythonKey) private var python = ""

    var body: some View {
        Form {
            Section {
                TextField("HERMES_HOME", text: $hermesHome, prompt: Text(RemoteConfig.developmentHermesHome))
                TextField("Python", text: $python, prompt: Text(RemoteConfig.python))
            } footer: {
                VStack(alignment: .leading) {
                    Text("现在用的是：\(RemoteConfig.hermesHome.path)")
                    Text("留空 = 开发副本。切到线上（\(RemoteConfig.liveHermesHome)）之前先读 PLAN_MACGUI 的 S7。")
                }
            }
        }
        .formStyle(.grouped)
    }
}
