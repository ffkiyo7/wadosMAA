//
//  CopilotPage.swift
//  Wado's MAA
//
//  自动抄作业（K13），一页三栏：关卡列表｜候选作业（单选，有缺口的标红不可选）｜将要派发 + 确认开打。
//  「确认开打」不绑回车，点了还要过一次确认框。上游的手贴作业在「工具与更多」。
//

import SwiftUI

struct CopilotPage: View {
    @Environment(RunData.self) private var data
    @Environment(RemoteStore.self) private var store
    @Environment(\.wmAccent) private var accent

    @State private var selected: String?
    @State private var preview: CopilotPreview?
    @State private var chosen: Int?
    @State private var dispatchedToken: String?
    @State private var searching = false
    @State private var working = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "自动抄作业", caption: caption) {
                    Button {
                        Task { await data.loadCopilot() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WM.f2)
                    .help("重读关卡列表")
                }
                if let message {
                    NoticeLine(ok: message.ok, text: message.text) { self.message = nil }.padding(.bottom, 14)
                }
                HStack(alignment: .top, spacing: 16) {
                    stageList.frame(width: 200)
                    candidates.frame(maxWidth: .infinity)
                    summary.frame(width: 270)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 40)
        }
        .task {
            if data.copilot == nil { await data.loadCopilot() }
            if let focus = data.copilotFocus {
                data.copilotFocus = nil
                await select(focus)
            }
        }
    }

    /// 没通的排前面，已通的沉到后面。
    private var sortedStages: [CopilotStageRow] {
        let all = data.copilot?.stages ?? []
        return all.filter { $0.status != "cleared" } + all.filter { $0.status == "cleared" }
    }

    private var caption: String? {
        guard let stages = data.copilot else { return nil }
        let todo = data.copilotTodo.count
        return stages.inActivity ? "活动进行中 · \(todo) 关未通" : "\(todo) 关未通"
    }

    // MARK: 关卡

    private var stageList: some View {
        VStack(spacing: 4) {
            if let error = data.copilotError {
                NoticeLine(ok: false, text: error)
            }
            ForEach(sortedStages) { row in
                Button {
                    Task { await select(row.stage) }
                } label: {
                    HStack(spacing: 10) {
                        Swatch(code: row.stage, size: 22, radius: 6)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.stage).fontWeight(.semibold).monospacedDigit()
                            Text(CopilotText.state(row)).font(.system(size: 11)).foregroundStyle(WM.f2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(selected == row.stage ? Color.white.opacity(0.09) : Color.clear))
                    .contentShape(Rectangle())
                    .opacity(row.status == "cleared" || row.nav == false ? 0.55 : 1)
                }
                .buttonStyle(.plain)
                .disabled(row.nav == false || searching)
                .help(CopilotText.detail(row))
            }
        }
    }

    // MARK: 候选

    @ViewBuilder private var candidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(
                title: selected.map { "\($0) 的候选作业" } ?? "候选作业",
                caption: preview.map { "搜到 \($0.total ?? $0.candidates.count) 份" })
            if let preview {
                VStack(spacing: 0) {
                    ForEach(Array(preview.candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { RowDivider() }
                        candidateRow(candidate, best: candidate.id == preview.bestId)
                    }
                    if preview.candidates.isEmpty {
                        Text("没有搜到作业").foregroundStyle(WM.f2)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                }
                .wmCard()
            } else if searching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("搜作业中…").foregroundStyle(WM.f2)
                }
                .help("prts 搜作业要 5～20 秒")
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).wmCard()
            } else {
                Text("左边选一关").foregroundStyle(WM.f2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).wmCard()
            }
        }
    }

    private func candidateRow(_ candidate: CopilotCandidate, best: Bool) -> some View {
        let checked = chosen == candidate.id && candidate.perfect
        let gaps = (candidate.gaps ?? []) + (candidate.softGaps ?? [])
        return Button {
            chosen = candidate.id
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(checked ? accent.color : WM.f3, lineWidth: checked ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .opacity(candidate.perfect ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 1) {
                    Text("#\(candidate.id) \(candidate.title ?? "")" + (best ? " · 推荐" : ""))
                        .fontWeight(.semibold).lineLimit(1)
                        .foregroundStyle(candidate.perfect ? Color.primary : WM.f3)
                    Text(gaps.isEmpty ? detail(candidate) : "不满足：\(gaps.joined(separator: "、"))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(gaps.isEmpty ? WM.f2 : WM.danger)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(score(candidate))
                    .font(.system(size: 17, weight: .bold)).monospacedDigit()
                    .foregroundStyle(candidate.perfect ? Color.primary : WM.f3)
                    .frame(width: 54, alignment: .trailing)
                    .help("好评率")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(checked ? accent.color.opacity(0.09) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!candidate.perfect || dispatchedToken != nil)
        .help(candidate.perfect ? "完全满足练度，可以选" : "有缺口，不能选（不变量 #15 / #18）")
    }

    private func detail(_ candidate: CopilotCandidate) -> String {
        var parts: [String] = []
        if let uploader = candidate.uploader { parts.append(uploader) }
        if let ratio = candidate.ratio { parts.append("满足 \(Int(ratio * 100))%") }
        if let views = candidate.views { parts.append("\(views) 次浏览") }
        return parts.isEmpty ? "练度全部满足" : parts.joined(separator: " · ")
    }

    private func score(_ candidate: CopilotCandidate) -> String {
        guard candidate.perfect, let rating = candidate.ratingRatio else { return "—" }
        return String(Int((rating * 100).rounded()))
    }

    // MARK: 汇总

    private var summary: some View {
        let pick = preview?.candidates.first { $0.id == chosen }
        let blocker = preview?.blocker ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            FieldLabel(text: "将要派发")
            Text(preview?.stage ?? selected ?? "—").font(.system(size: 26, weight: .bold)).tracking(-0.5)
            Text(pick.map { "#\($0.id) \($0.title ?? "")" } ?? "还没选作业")
                .font(.system(size: 11.5)).foregroundStyle(WM.f2).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("理智").foregroundStyle(WM.f3)
                    Text(preview?.sanityCost.map(String.init) ?? "—").gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("方式").foregroundStyle(WM.f3)
                    Text((preview?.modes ?? []).joined(separator: "、").isEmpty ? "—" : (preview?.modes ?? []).joined(separator: "、"))
                }
                GridRow {
                    Text("游戏锁").foregroundStyle(WM.f3)
                    Text(store.lockHolder == nil ? "空闲" : "使用中")
                }
            }
            .font(.system(size: 12)).monospacedDigit()
            .padding(.vertical, 14)
            if !blocker.isEmpty {
                Text("现在不能派发：\(blocker)").font(.system(size: 11.5)).foregroundStyle(WM.game).padding(.bottom, 8)
            }
            if let token = dispatchedToken {
                HStack {
                    Button("刷新进度") { Task { await run(["copilot", "status", token]) } }
                        .buttonStyle(WMButtonStyle()).help("问 maa-remote 这一轮到哪了")
                    Button("取消本轮") { Task { await run(["copilot", "cancel", token]) } }
                        .buttonStyle(WMButtonStyle(kind: .danger)).help("取消这一轮派发")
                }
                .padding(.bottom, 8)
            }
            // 不绑回车：自动选中后按一下回车就会派发，等于跳过了「确认开打」（K13）。
            GameButton(
                title: "确认开打", help: "会连接游戏，先确认再派发。不吃药、不借助战、不忽略练度", big: true, fullWidth: true
            ) {
                GameConfirm(
                    title: "开打 \(preview?.stage ?? "")？",
                    rows: [("作业", pick.map { "#\($0.id) \($0.title ?? "")" } ?? "—"), ("理智", preview?.sanityCost.map(String.init) ?? "—")],
                    ok: "开打"
                ) { Task { await go() } }
            }
            .disabled(working || pick == nil || preview == nil || dispatchedToken != nil || !blocker.isEmpty)
        }
        .padding(16)
        .wmCard()
    }

    // MARK: 动作（同原 AutoCopilotView）

    private func select(_ stage: String) async {
        selected = stage
        searching = true
        defer { searching = false }
        preview = nil
        chosen = nil
        dispatchedToken = nil
        do {
            let receipt = try await RemoteBridge.run(["copilot", "preview", stage], timeout: 120)
            guard selected == stage else { return }
            if !receipt.ok { message = (false, receipt.message) }
            guard receipt.ok else { return }
            let loaded = try receipt.decode(CopilotPreview.self, snakeCase: false)
            preview = loaded
            chosen = loaded.bestId
        } catch {
            message = (false, error.localizedDescription)
        }
    }

    private func go() async {
        guard let preview, let chosen else { return }
        working = true
        defer { working = false }
        do {
            let receipt = try await RemoteBridge.run(["copilot", "go", preview.token, String(chosen)])
            message = (receipt.ok, receipt.message)
            if receipt.ok { dispatchedToken = receipt.dictionary["token"] as? String }
        } catch {
            message = (false, error.localizedDescription)
        }
    }

    private func run(_ args: [String]) async {
        working = true
        defer { working = false }
        do {
            let receipt = try await RemoteBridge.run(args)
            message = (receipt.ok, receipt.message)
        } catch {
            message = (false, error.localizedDescription)
        }
    }
}
