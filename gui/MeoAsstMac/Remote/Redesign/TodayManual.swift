//
//  TodayManual.swift
//  Wado's MAA
//
//  首页的手动日常，压成一行：「现在跑一场」+ 关卡下拉 + 要做的事（小气泡里 6 个勾）+「开始日常」。
//  开始走 `run local`，和 Discord「现在跑」同一条路；确认框、临近定时场的 `--force` 二次确认照旧。
//  游戏被占用时这一行换成「游戏正在用于…」+「停止」。
//

import SwiftUI
import WadosMAAShared

struct ManualRunRow: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data
    @Environment(\.askGame) private var askGame
    @Environment(\.wmAccent) private var accent

    @State private var stage: String?
    @State private var switches: [String: Bool] = [:]
    @State private var showTasks = false
    @State private var running = false
    @State private var result: (ok: Bool, text: String)?

    /// 活动期间前置的活动关（只留关卡选项里有的）；没有活动是空的。
    private var activityStages: [String] {
        guard let choices = data.choices, let activity = choices.activity else { return [] }
        let known = Set(choices.choices.map(\.stage))
        return activity.stages.filter { known.contains($0) }
    }

    /// 平时是「日常」里设的默认关；活动期间换成活动关：下一场自动定关选中的活动关，没有就第一个活动关。
    private var defaultStage: String {
        let front = activityStages
        guard let first = front.first else { return store.defaults?.stage ?? "" }
        let next = SessionGate.load().upcoming(within: 24 * 60)?.phase
        let sessions = (store.todayPlan?.sessions ?? []).sorted { $0.phase == next && $1.phase != next }
        return sessions.first { $0.stageSource == "auto" && front.contains($0.stage) }?.stage ?? first
    }

    private func defaultOn(_ key: String) -> Bool { store.defaults?.tasks?[key] ?? true }
    private func isOn(_ key: String) -> Bool { switches[key] ?? defaultOn(key) }

    private var currentStage: String { stage ?? defaultStage }

    private var tasksChanged: Bool {
        (data.choices?.switches ?? []).contains { isOn($0) != defaultOn($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // 以锁文件为准（`RemoteStore` 每 2 秒看一眼），`choices.busy` 是加载那一刻的快照，会过期。
                if let holder = store.lockHolder {
                    Image(systemName: "hourglass").font(.system(size: 16)).foregroundStyle(WM.game)
                    Text("游戏正在用于\(holder.text)").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    StopRunButton()
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("现在跑一场").font(.system(size: 16, weight: .semibold))
                        if let blackout = data.choices?.blackout, !blackout.isEmpty {
                            Text(blackout).font(.system(size: 12)).foregroundStyle(WM.game).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let choices = data.choices {
                        stageMenu(choices)
                        tasksButton(choices)
                        if running { ProgressView().controlSize(.small) }
                        GameButton(title: "开始日常", help: "先确认再开始", big: true) { startConfirm(choices) }
                            .disabled(running || store.readOnly)
                    } else if let error = data.choicesError {
                        Text(error).font(.system(size: 12)).foregroundStyle(WM.danger).lineLimit(1)
                        Button("重试") { Task { await data.loadChoices() } }.buttonStyle(WMButtonStyle())
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 12)
            .frame(minHeight: 60)
            .wmCard(radius: 16)
            if let result {
                NoticeLine(ok: result.ok, text: result.text) { self.result = nil }.padding(.horizontal, 4)
            }
        }
        .autoDismiss(result) { result = nil }
    }

    // MARK: 关卡

    /// 活动关在前、上次作战、其它关卡，平铺。
    private func stageMenu(_ choices: RunChoices) -> some View {
        let front = activityStages.compactMap { code in choices.choices.first { $0.stage == code } }
        let last = choices.choices.first { $0.stage.isEmpty }
        let rest = choices.choices.filter { !$0.stage.isEmpty && !activityStages.contains($0.stage) }
        return Menu {
            if !front.isEmpty {
                Section("活动关") { ForEach(front, id: \.self) { stageItem($0) } }
                Divider()
            }
            if let last { stageItem(last) }
            Divider()
            if front.isEmpty {
                ForEach(rest, id: \.self) { stageItem($0) }
            } else {
                Section("其它关卡") { ForEach(rest, id: \.self) { stageItem($0) } }
            }
        } label: {
            HStack(spacing: 8) {
                Swatch(code: currentStage, size: 18, radius: 5)
                Text(currentStage.isEmpty ? "上次作战" : currentStage).font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(WM.f2)
            }
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .frame(height: 36)
            .modifier(RowControl())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(choices.choices.first { $0.stage == currentStage }.map { "\($0.label)：\($0.description)" } ?? "换关")
    }

    @ViewBuilder private func stageItem(_ choice: RunChoices.Choice) -> some View {
        let title = choice.stage.isEmpty ? "上次作战" : choice.label
        Button {
            stage = choice.stage
        } label: {
            if choice.stage == currentStage {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    // MARK: 要做的事

    private func tasksButton(_ choices: RunChoices) -> some View {
        let count = choices.switches.filter(isOn).count
        return Button {
            showTasks.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(tasksChanged ? "\(count) 项" : "全部 \(count) 项").font(.system(size: 14)).monospacedDigit()
                if tasksChanged {
                    Circle().fill(accent.color).frame(width: 7, height: 7).help("和默认不同，只对这次生效")
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(WM.f2)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .frame(height: 36)
            .modifier(RowControl(lit: showTasks))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("这次要做的事")
        .popover(isPresented: $showTasks, arrowEdge: .bottom) {
            tasksBubble(choices)
        }
    }

    private func tasksBubble(_ choices: RunChoices) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(choices.switches, id: \.self) { key in
                    taskTile(key, name: choices.taskNames[key] ?? key)
                }
            }
            Button("恢复默认") { switches = [:] }
                .buttonStyle(WMLinkStyle())
                .font(.system(size: 13))
                .disabled(!tasksChanged)
                .padding(.horizontal, 4)
        }
        .padding(12)
        .frame(width: 300)
        // 气泡压在下面的卡片上：底子要够厚，后面的字和高亮色不能透上来。
        .background(WM.panel.opacity(0.9))
    }

    private func taskTile(_ key: String, name: String) -> some View {
        let on = isOn(key)
        return Button {
            switches[key] = !on
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(on ? accent.color : Color.clear)
                    RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : Color(hex: 0xebebf5, opacity: 0.55), lineWidth: 1.5)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(accent.ink)
                    }
                }
                .frame(width: 17, height: 17)
                Text(name).font(.system(size: 14)).foregroundStyle(on ? Color.primary : WM.f2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "这次做「\(name)」，点一下跳过" : "这次跳过「\(name)」，点一下加回")
    }

    // MARK: 开始

    /// 快到的那一场（和 maa-remote 的「早晚场优先」同一个算法）。
    private var blackoutSlot: SessionGate.Slot? {
        let gate = SessionGate.load()
        return gate.upcoming(within: gate.blackoutMinutes)
    }

    /// 「开始日常」的确认框。早场 / 晚场就要开始了（本地算出来的，或者 maa-remote 刚挡下来的）时，
    /// 同一个确认框带上警告，确认键换成「仍然开始」，确认后带 `--force`（只解除这一条，游戏被占用时照样开不了）。
    private func startConfirm(_ choices: RunChoices, soon: Bool = false) -> GameConfirm {
        let names = choices.switches.filter(isOn).map { choices.taskNames[$0] ?? $0 }
        let rows = [
            ("关卡", currentStage.isEmpty ? "上次作战关卡" : currentStage),
            ("要做的事", names.isEmpty ? "无" : names.joined(separator: "、")),
            ("规矩", "不碎石、不借助战，只吃快过期的理智药"),
        ]
        let slot = blackoutSlot
        guard soon || slot != nil else {
            return GameConfirm(title: "开始手动日常？", rows: rows, ok: "开始") { Task { await start(force: false) } }
        }
        let name = slot?.phase == "pm" ? "晚场" : "早场"
        return GameConfirm(
            title: slot.map { "\($0.label) 就要开始了" } ?? "日常就要开始了",
            rows: rows,
            warning: "现在开始，\(name)可能会因为游戏被占用而跳过。",
            ok: "仍然开始"
        ) { Task { await start(force: true) } }
    }

    private func start(force: Bool) async {
        guard let choices = data.choices else { return }
        result = nil
        running = true
        defer { running = false }
        var payloadDict: [String: Bool] = [:]
        for key in choices.switches { payloadDict[key] = isOn(key) }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var args = ["run", "local", currentStage, payload]
        if force { args.append("--force") }
        do {
            let receipt = try await RemoteBridge.run(args)
            result = (receipt.ok, receipt.message)
            // 确认时还没到、开始时刚好到了：再问一次，还是同一个确认框。
            if !receipt.ok, !force, receipt.code == "session_soon" || receipt.dictionary["blocked"] as? String == "blackout" {
                result = nil
                askGame(startConfirm(choices, soon: true))
            }
        } catch {
            result = (false, error.localizedDescription)
        }
        await data.loadChoices()
    }
}

/// 手动一行里的下拉按钮底：浅色半透明圆角块，打开时亮一点。
private struct RowControl: ViewModifier {
    var lit = false

    func body(content: Content) -> some View {
        content
            .background(Color.white.opacity(lit ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
    }
}
