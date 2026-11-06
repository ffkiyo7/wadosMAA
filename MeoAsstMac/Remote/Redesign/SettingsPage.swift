//
//  SettingsPage.swift
//  Wado's MAA
//
//  设置：外观（强调色、背景图、玻璃卡片）、maa-remote（环境、HERMES_HOME、Python）、连接与游戏、帮助与日志文件。
//  原来的连接 / 游戏 / 系统设置页原样放进弹出页里用；⌘, 的设置窗口也还在。
//

import SwiftUI

struct SettingsPage: View {
    @AppStorage(WM.accentKey) private var accent = AccentChoice.gold
    @AppStorage(AppearanceKeys.glass) private var glass = true
    @AppStorage(AppearanceKeys.lightImage) private var lightPath = ""
    @AppStorage(AppearanceKeys.darkImage) private var darkPath = ""
    @AppStorage(RemoteConfig.hermesHomeKey) private var hermesHome = ""
    @AppStorage(RemoteConfig.pythonKey) private var python = ""

    @State private var sheet: SettingsSheet?
    @State private var askLive = false

    enum SettingsSheet: String, Identifiable {
        case background, connection, game, system
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "设置")
                VStack(alignment: .leading, spacing: 0) {
                    FormGroup(title: "外观") {
                        FormRow(title: "强调色") {
                            HStack(spacing: 10) {
                                ForEach(AccentChoice.allCases) { choice in
                                    Button { accent = choice } label: {
                                        Circle().fill(choice.color).frame(width: 26, height: 26)
                                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                                            .padding(3)
                                            .overlay(Circle().strokeBorder(accent == choice ? Color.primary : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                    .help(choice.name)
                                }
                            }
                        }
                        FormRow(title: "背景图", sub: backgroundText, help: "浅色、深色各一张；只设一张时共用") {
                            Button("选择…") { sheet = .background }.buttonStyle(WMButtonStyle())
                                .help("选背景图，调填充、遮罩和模糊")
                        }
                        FormRow(title: "玻璃卡片", help: "有背景图时，卡片用 Liquid Glass") {
                            Toggle("玻璃卡片", isOn: $glass).toggleStyle(.switch).labelsHidden()
                                .help("有背景图时，卡片用 Liquid Glass")
                        }
                    }
                    FormGroup(title: "maa-remote") {
                        FormRow(title: "环境", help: "开发 = 开发副本，不改线上、不发 Discord") {
                            Picker("环境", selection: envBinding) {
                                Text("开发").tag(false)
                                Text("线上").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .help("切到线上之前先读 PLAN_MACGUI 的 S7")
                        }
                        FormRow(title: "HERMES_HOME", sub: RemoteConfig.hermesHome.path) {
                            TextField("HERMES_HOME", text: $hermesHome, prompt: Text("留空 = 开发副本"))
                                .labelsHidden().frame(width: 220)
                                .help("留空 = \(RemoteConfig.developmentHermesHome)")
                        }
                        FormRow(title: "Python", sub: RemoteConfig.python) {
                            TextField("Python", text: $python, prompt: Text("自动"))
                                .labelsHidden().frame(width: 220)
                                .help("留空时自动找 Homebrew 的 python3，再退回 /usr/bin/python3")
                        }
                    }
                    FormGroup(title: "连接与游戏") {
                        FormRow(title: "连接设置", help: "MaaTools 地址、触控方式") {
                            Button("打开…") { sheet = .connection }.buttonStyle(WMButtonStyle()).help("MaaTools 地址、触控方式")
                        }
                        FormRow(title: "游戏设置", help: "客户端、启动游戏") {
                            Button("打开…") { sheet = .game }.buttonStyle(WMButtonStyle()).help("客户端、启动游戏")
                        }
                        FormRow(title: "系统选项", help: "防休眠、通知等") {
                            Button("打开…") { sheet = .system }.buttonStyle(WMButtonStyle()).help("防休眠、通知等")
                        }
                    }
                    FormGroup {
                        FormRow(title: "帮助与公告") {
                            Link(destination: URL(string: "https://docs.maa.plus/zh-cn/mac.html")!) {
                                Text("打开…")
                            }
                            .buttonStyle(WMButtonStyle())
                            .help("docs.maa.plus 的 Mac 版说明")
                        }
                        FormRow(title: "日志文件") {
                            Button("在 Finder 中显示") { OpenLogFileView.revealLogInFinder() }
                                .buttonStyle(WMButtonStyle()).help("asst.log 所在的文件夹")
                        }
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .sheet(item: $sheet) { which in
            VStack(spacing: 0) {
                switch which {
                case .background: AppearanceSettingsView()
                case .connection: ConnectionSettingsView()
                case .game: GameSettingsView()
                case .system: SystemSettingsView()
                }
                HStack {
                    Spacer()
                    Button("完成") { sheet = nil }.buttonStyle(WMButtonStyle(kind: .accent))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
            .frame(minWidth: 480, minHeight: 360)
        }
        .alert("切到线上？", isPresented: $askLive) {
            Button("切到线上", role: .destructive) { hermesHome = RemoteConfig.liveHermesHome }
            Button("取消", role: .cancel) {}
        } message: {
            Text("之后的改动会写进 \(RemoteConfig.liveHermesHome)，并同步到 Discord。")
        }
    }

    private var backgroundText: String {
        let names = [lightPath, darkPath].filter { !$0.isEmpty }.map { ($0 as NSString).lastPathComponent }
        return names.isEmpty ? "未设置" : names.joined(separator: "、")
    }

    private var envBinding: Binding<Bool> {
        Binding(
            get: { RemoteConfig.isLiveHome },
            set: { live in
                if live { askLive = true } else { hermesHome = "" }
            })
    }
}
