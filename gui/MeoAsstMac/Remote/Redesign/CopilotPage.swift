//
//  CopilotPage.swift
//  Wado's MAA
//
//  自动抄作业（K13），一页三栏：关卡列表｜候选作业（单选，练度不够的标红不可选）｜准备开打 + 开打。
//  「开打」不绑回车，点了还要过一次确认框。
//  开打后的进度看顶部状态条和日志（`RunProgress`），这里不再手动刷新。
//

import SwiftUI
import WadosMAAShared

struct CopilotPage: View {
    @Environment(RemoteStore.self) private var store
    @Environment(RunData.self) private var data
    @Environment(\.wmAccent) private var accent

    @State private var selected: String?
    @State private var preview: CopilotPreview?
    @State private var chosen: Int?
    @State private var dispatchedToken: String?
    @State private var searching = false
    /// 正在搜的那次；换关、点「我打过了」、离开页面都会取消它（连带结束 `copilot preview` 子进程）。
    @State private var searchTask: Task<Void, Never>?
    /// 每次开搜加一，回来的结果对不上就丢掉。
    @State private var searchID = 0
    @State private var working = false
    @State private var message: (ok: Bool, text: String)?
    @State private var showRules = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "自动抄作业", caption: caption) {
                    Button("规则") { showRules.toggle() }
                        .buttonStyle(WMButtonStyle())
                        .popover(isPresented: $showRules, arrowEdge: .bottom) { CopilotRules().environment(store) }
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
        .autoDismiss(message) { message = nil }
        .task {
            if data.copilot == nil { await data.loadCopilot() }
            if let focus = data.copilotFocus {
                data.copilotFocus = nil
                search(focus)
            }
        }
        .onDisappear { stopSearch() }
    }

    /// 没通的排前面，已通的沉到后面。
    private var sortedStages: [CopilotStageRow] {
        let all = data.copilot?.stages ?? []
        return all.filter { $0.status != "cleared" } + all.filter { $0.status == "cleared" }
    }

    /// 未通的关数边栏角标已经有了，这里只说活动。
    private var caption: String? {
        let parts = [
            data.copilot?.inActivity == true ? "活动进行中" : nil,
            store.copilotAutoPaused ? "自动已暂停" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: 关卡

    private var stageList: some View {
        VStack(spacing: 4) {
            if let error = data.copilotError {
                NoticeLine(ok: false, text: error)
            }
            ForEach(sortedStages) { row in
                Button {
                    search(row.stage)
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
                .disabled(row.nav == false)
                .help(CopilotText.detail(row))
            }
        }
    }

    // MARK: 候选

    @ViewBuilder private var candidates: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(
                title: selected.map { "\($0) 的候选作业" } ?? "候选作业",
                caption: preview.flatMap { p in p.total.flatMap { $0 > p.candidates.count ? "共 \($0) 份" : nil } })
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
                .help("从作业站找作业要 5～20 秒")
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).wmCard()
            } else {
                Text(selectedRow?.status == "cleared" ? "这一关已经通了" : "左边选一关").foregroundStyle(WM.f2)
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
                    Text(gaps.isEmpty ? detail(candidate) : "练度不够：\(gaps.joined(separator: "、"))")
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
        .help(candidate.perfect ? "练度够，可以选" : "练度不够，不能选")
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
            FieldLabel(text: "准备开打")
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
            }
            .font(.system(size: 12)).monospacedDigit()
            .padding(.vertical, 14)
            if !blocker.isEmpty {
                Text("现在不能开打：\(blocker)").font(.system(size: 11.5)).foregroundStyle(WM.game).padding(.bottom, 8)
            }
            if let token = dispatchedToken {
                Button("取消这次抄作业") { Task { await run(["copilot", "cancel", token]) } }
                    .buttonStyle(WMButtonStyle(kind: .danger))
                    .padding(.bottom, 8)
            }
            // 不绑回车：自动选中后按一下回车就会派发，等于跳过了「确认开打」（K13）。
            GameButton(title: "开打", help: "先确认再开打", big: true, fullWidth: true) {
                GameConfirm(
                    title: "开打 \(preview?.stage ?? "")？",
                    rows: [
                        ("作业", pick.map { "#\($0.id) \($0.title ?? "")" } ?? "—"),
                        ("理智", preview?.sanityCost.map(String.init) ?? "—"),
                        ("规矩", "不吃理智药、不借助战，练度不够不打"),
                    ],
                    ok: "开打"
                ) { Task { await go() } }
            }
            .disabled(working || pick == nil || preview == nil || dispatchedToken != nil || !blocker.isEmpty)
            if let row = selectedRow {
                HStack(spacing: 8) {
                    if row.status != "cleared" {
                        Button("我打过了") { Task { await mark(row.stage, cleared: true) } }
                            .help("记为普通和突袭都已通关，自动抄作业不再排这一关")
                    }
                    if row.ledgerCleared == true {
                        Button("撤销通关记录") { Task { await mark(row.stage, cleared: false) } }
                            .help("清掉这一关的通关记录，自动抄作业会重新考虑它")
                    }
                }
                .buttonStyle(WMButtonStyle())
                .disabled(working || store.readOnly)
                .padding(.top, 10)
            }
        }
        .padding(16)
        .wmCard()
    }

    private var selectedRow: CopilotStageRow? {
        guard let selected else { return nil }
        return data.copilot?.stages.first { $0.stage == selected }
    }

    // MARK: 动作（同原 AutoCopilotView）

    /// 选一关就开搜。搜的时候照样能换关：上一次先取消、等它的子进程退出（放开搜索锁），再搜新的。
    private func search(_ stage: String) {
        let previous = searchTask
        previous?.cancel()
        searchID += 1
        let id = searchID
        selected = stage
        searching = true
        preview = nil
        chosen = nil
        dispatchedToken = nil
        searchTask = Task {
            await previous?.value
            await loadPreview(stage, id: id)
        }
    }

    private func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchID += 1
        searching = false
    }

    private func loadPreview(_ stage: String, id: Int) async {
        defer { if searchID == id { searching = false } }
        guard !Task.isCancelled else { return }
        do {
            let receipt = try await RemoteBridge.run(["copilot", "preview", stage], timeout: 120)
            guard searchID == id else { return }
            if !receipt.ok { message = (false, receipt.message) }
            guard receipt.ok else { return }
            let loaded = try receipt.decode(CopilotPreview.self, snakeCase: false)
            preview = loaded
            chosen = loaded.bestId
        } catch is CancellationError {
        } catch {
            if searchID == id { message = (false, error.localizedDescription) }
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

    /// 「我打过了」/「撤销通关记录」：只改本地记账（`copilot mark-cleared <关> all` / `copilot unmark <关>`），再重读关卡列表。
    /// 记「打过了」时这一关的搜索没用了：马上停掉，不等它搜完。
    private func mark(_ stage: String, cleared: Bool) async {
        if cleared {
            stopSearch()
            preview = nil
            chosen = nil
        }
        await run(cleared ? ["copilot", "mark-cleared", stage, "all"] : ["copilot", "unmark", stage])
        await data.loadCopilot()
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

/// 抄作业页右上角「规则」：自动抄作业开不开（`copilot auto on|off`），每天试几次、多久再找、
/// 离早晚场多近就不开新的一关。数值改了就写，可撤销；开关一拨就调命令。
struct CopilotRules: View {
    @Environment(RemoteStore.self) private var store
    /// 刚拨、命令还没回来时先显示拨到的位置。
    @State private var pendingAuto: Bool?

    static let keys: Set<String> = [
        "auto_copilot_max_attempts_per_day", "activity_search_retry_minutes", "auto_copilot_min_lead_minutes",
        "copilot_blackout_minutes",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormGroup {
                FormRow(
                    title: "自动抄作业",
                    help: "活动期间自动找作业、自动开打。关掉后正在打的这一关打完就停；手动抄作业不受影响"
                ) {
                    Toggle("自动抄作业", isOn: Binding(
                        get: { pendingAuto ?? !store.copilotAutoPaused },
                        set: { on in
                            pendingAuto = on
                            Task {
                                await store.perform(["copilot", "auto", on ? "on" : "off"])
                                pendingAuto = nil
                            }
                        }
                    ))
                    .toggleStyle(.switch).labelsHidden()
                    .disabled(pendingAuto != nil)
                }
            }
            .padding(.top, -20)
            FormGroup {
                ConfigFieldRow(key: "auto_copilot_max_attempts_per_day") { value in
                    Int(value.number ?? 0) == 0 ? "不限次数" : nil
                }
                ConfigFieldRow(key: "activity_search_retry_minutes") { value in
                    "没作业或练度不够时，\(Int(value.number ?? 0)) 分钟后再找"
                }
                ConfigFieldRow(key: "auto_copilot_min_lead_minutes") { value in
                    lead(value, "不自动开新的一关")
                }
                ConfigFieldRow(key: "copilot_blackout_minutes") { value in
                    lead(value, "不能开打")
                }
            }
            .padding(.top, -8)
        }
        .padding(16)
        .frame(width: 460)
        .disabled(store.readOnly)
    }

    private func lead(_ value: JSONValue, _ what: String) -> String? {
        let minutes = Int(value.number ?? 0)
        guard minutes > 0 else { return "不受早晚场影响" }
        return SessionLead.windows(store, minutes: minutes).map { "\($0) \(what)" }
    }
}

enum CopilotText {
    /// 去掉 status_text 前面的 emoji。
    static func status(_ row: CopilotStageRow) -> String {
        let text = row.statusText ?? ""
        return text.drop { !$0.isLetter && !$0.isNumber && $0 != "（" }.trimmingCharacters(in: .whitespaces)
    }

    /// 进不去的关（maa-remote 的 no_nav / not_indexed）统一一个说法，不透出原因原文。
    static func unsupported(_ row: CopilotStageRow) -> Bool {
        row.nav == false || row.status == "no_nav" || row.status == "not_indexed"
    }

    static func state(_ row: CopilotStageRow) -> String {
        if unsupported(row) { return "暂不支持自动前往" }
        return status(row).isEmpty ? "" : status(row)
    }

    /// maa-remote 给的原因；进不去的关、没有原因时不占一行。
    static func reason(_ row: CopilotStageRow) -> String? {
        guard !unsupported(row), let reason = row.reason, !reason.isEmpty else { return nil }
        return reason
    }

    static func detail(_ row: CopilotStageRow) -> String {
        if unsupported(row) { return "暂不支持自动前往" }
        return reason(row) ?? (row.status == "cleared" ? "已通" : "可以去搜作业")
    }
}
