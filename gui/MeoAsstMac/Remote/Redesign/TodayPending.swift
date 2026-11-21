//
//  TodayPending.swift
//  Wado's MAA
//
//  首页「待处理」：没有区块标题，一件事一行，没事整块不出现。
//  - 还有关没抄：「N 关待抄」+ 关卡小胶囊（点胶囊进抄作业页对应关，点整行进抄作业页）；
//  - 游戏资源不正常（有新版本、今天还没更新、状态不对、正在更新、查不到）：一句话 +「现在更新」。
//    今天已更新、没有新版本时不出现；版本号在设置页。
//

import SwiftUI
import WadosMAAShared

struct TodayPending: View {
    let go: (WMPage) -> Void

    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data

    var body: some View {
        let todo = data.copilotTodo
        let upstream = UpstreamLine(store: store)
        if !todo.isEmpty || upstream != nil {
            VStack(spacing: 0) {
                if !todo.isEmpty {
                    copilotRow(todo)
                }
                if let upstream {
                    if !todo.isEmpty {
                        RowDivider().padding(.leading, 58)
                    }
                    UpstreamRow(line: upstream)
                }
            }
            .wmCard(radius: 16)
        }
    }

    private func copilotRow(_ todo: [CopilotStageRow]) -> some View {
        HStack(spacing: 12) {
            PendingIcon(systemImage: "doc.on.doc", color: nil)
            Text("\(todo.count) 关待抄").font(.system(size: 15, weight: .semibold)).padding(.trailing, 6)
                .fixedSize()
            // 放不下就少放几个，不换行。候选写死成几个固定的视图：ViewThatFits 里放 ForEach 会因 ID 重复崩溃。
            ViewThatFits(in: .horizontal) {
                chips(todo, count: todo.count)
                chips(todo, count: min(todo.count, 4))
                chips(todo, count: min(todo.count, 2))
                chips(todo, count: 1)
                Color.clear.frame(width: 0, height: 0)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(WM.f2)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 56)
        .contentShape(Rectangle())
        .onTapGesture { go(.copilot) }
        .help("打开「自动抄作业」")
    }

    private func chips(_ todo: [CopilotStageRow], count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(todo.prefix(count)) { row in stageChip(row) }
        }
    }

    private func stageChip(_ row: CopilotStageRow) -> some View {
        Button {
            data.copilotFocus = row.stage
            go(.copilot)
        } label: {
            HStack(spacing: 6) {
                Swatch(code: row.stage, size: 14, radius: 4)
                Text(row.stage).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .frame(height: 28)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("打开 \(row.stage) 的候选作业")
    }
}

/// 行首 30×30 的小图标块。`color` 为 nil 时用强调色。
private struct PendingIcon: View {
    let systemImage: String
    let color: Color?
    @Environment(\.wmAccent) private var accent

    var body: some View {
        let tint = color ?? accent.color
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 游戏资源那一行要说什么；正常（今天已更新、没有新版本）时是 nil。
private struct UpstreamLine {
    enum Kind { case update, running, blocked, unknown }

    let kind: Kind
    let text: String
    let help: String

    @MainActor init?(store: RemoteStore) {
        guard let status = store.upstream else {
            // 刚打开还没读完不算；读过了还是没有，才说查不到。
            guard store.reloadedAt != nil else { return nil }
            self.init(kind: .unknown, text: "查不到游戏资源的状态", help: "稍后会再查；一直这样就在设置 › 高级里复制诊断信息")
            return
        }
        let version = "版本 \(status.versions.maaCore ?? "未知")"
        if status.running {
            self.init(kind: .running, text: "正在更新游戏资源", help: "大约 3 分钟，期间不能开始日常")
        } else if status.verdict == "blocked" {
            self.init(
                kind: .blocked, text: "游戏资源状态不对，暂时不能开始日常",
                help: "请稍后再看，或在设置 › 高级里复制诊断信息。\n\(version)")
        } else if status.online?.maaResourceOutdated == true {
            self.init(kind: .update, text: "游戏资源有新版本", help: version)
        } else if !status.fresh {
            self.init(kind: .update, text: "游戏资源今天还没更新", help: version)
        } else {
            return nil
        }
    }

    private init(kind: Kind, text: String, help: String) {
        self.kind = kind
        self.text = text
        self.help = help
    }
}

private struct UpstreamRow: View {
    let line: UpstreamLine

    @Environment(RemoteStore.self) private var store
    @Environment(\.askGame) private var askGame

    var body: some View {
        HStack(spacing: 12) {
            PendingIcon(
                systemImage: line.kind == .blocked || line.kind == .unknown ? "exclamationmark.triangle" : "arrow.down.circle",
                color: WM.game)
            Text(line.text).font(.system(size: 15, weight: .semibold))
            if line.kind == .running { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
            if line.kind == .update {
                Button {
                    askGame(confirm)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.fill").imageScale(.small).foregroundStyle(WM.game)
                        Text("现在更新")
                    }
                }
                .buttonStyle(WMButtonStyle())
                .disabled(!(store.upstream?.updateBlocked ?? "x").isEmpty || store.busy || store.readOnly)
                .help(updateHelp)
            }
        }
        .help(line.help)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 56)
    }

    private var confirm: GameConfirm {
        GameConfirm(title: "更新游戏资源？", rows: [("用时", "大约 3 分钟，期间不能开始日常")], ok: "更新") {
            Task {
                await store.perform(["upstream", "update"])
                _ = await RemoteGate.waitForUpdate()
                await store.reload()
            }
        }
    }

    private var updateHelp: String {
        if let blocked = store.upstream?.updateBlocked, !blocked.isEmpty { return "现在不能更新：\(blocked)" }
        return "先确认再更新"
    }
}
