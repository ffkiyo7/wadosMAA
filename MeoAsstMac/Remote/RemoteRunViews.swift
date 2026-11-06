//
//  RemoteRunViews.swift
//  Wado's MAA
//
//  S6：一键长草和自动战斗换成 maa-remote 的流程（K4、K11–K14）。
//
//  - 一键长草：「这一次」刷哪关、哪些环节跳过，开始就是 `run local`。走的是和 Discord「现在跑」
//    同一条路（`maa_daily.py now`）：持锁、摆窗口、截图核验、发 Discord 进度和战报。参数只对这一场
//    生效（K12）；早晚场的计划和持久默认值在「日常配置」里改。
//  - 自动抄作业：选关 → 预览全部候选 → 自动选中最优的完全满足那份 → 点「确认开打」才派发 → 可取消（K13）。
//
//  这两条路 GUI 都**不拿** run.lock：子进程自己抢。
//

import SwiftUI

// MARK: - 一键长草

struct RunChoices: Decodable, Sendable {
    struct Choice: Decodable, Sendable, Hashable {
        let label: String
        let stage: String
        let description: String
    }

    let choices: [Choice]
    let switches: [String]
    let taskNames: [String: String]
    let busy: String
    let blackout: String

    enum CodingKeys: String, CodingKey {
        case choices, switches, busy, blackout
        case taskNames = "task_names"
    }
}

struct LocalRunSection: View {
    @Environment(RemoteStore.self) private var store

    @State private var choices: RunChoices?
    @State private var loadError: String?
    @State private var stage = ""
    @State private var switches: [String: Bool] = [:]
    @State private var running = false
    @State private var result: (ok: Bool, text: String)?
    @State private var forceReason: String?

    var body: some View {
        Section {
            if let choices {
                Picker("刷哪关", selection: $stage) {
                    ForEach(choices.choices, id: \.self) { choice in
                        Text(choice.label).tag(choice.stage)
                    }
                }
                ForEach(choices.switches, id: \.self) { key in
                    Toggle(
                        choices.taskNames[key] ?? key,
                        isOn: Binding(get: { switches[key] ?? true }, set: { switches[key] = $0 }))
                }
                if !choices.busy.isEmpty {
                    Label("\(choices.busy)正在用游戏", systemImage: "lock").foregroundStyle(.orange)
                } else if !choices.blackout.isEmpty {
                    Label(choices.blackout, systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                }
                HStack {
                    Button {
                        Task { await start(force: false) }
                    } label: {
                        Label("开始这一场", systemImage: "play.fill")
                    }
                    .disabled(running || store.readOnly)
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("刷新") { Task { await load() } }
                }
                Text("不碎石、只吃临期药、不借助战。进度和战报照常发到 Discord。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let loadError {
                Text(loadError).foregroundStyle(.red)
                Button("重试") { Task { await load() } }
            } else {
                ProgressView()
            }
            if let result {
                Text(result.text)
                    .foregroundStyle(result.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text("这一次（maa-remote 的日常流程）")
        }
        .task { await load() }
        .alert(
            "定时场优先",
            isPresented: Binding(get: { forceReason != nil }, set: { if !$0 { forceReason = nil } })
        ) {
            Button("仍要开跑", role: .destructive) { Task { await start(force: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(forceReason ?? "")
        }
    }

    private func load() async {
        do {
            let loaded = try await RemoteBridge.run(["run", "choices"]).decode(RunChoices.self, snakeCase: false)
            choices = loaded
            loadError = nil
            if !loaded.choices.contains(where: { $0.stage == stage }) {
                stage = loaded.choices.first?.stage ?? ""
            }
            for key in loaded.switches where switches[key] == nil {
                switches[key] = true
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func start(force: Bool) async {
        running = true
        defer { running = false }
        let payload = (try? JSONSerialization.data(withJSONObject: switches, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var args = ["run", "local", stage, payload]
        if force { args.append("--force") }
        do {
            let receipt = try await RemoteBridge.run(args)
            result = (receipt.ok, receipt.message)
            if !receipt.ok, receipt.dictionary["blocked"] as? String == "blackout" {
                forceReason = (receipt.dictionary["reason"] as? String ?? receipt.message) + "\n确认后会跳过这条限制强行开跑（锁冲突仍然不能强行）。"
            }
        } catch {
            result = (false, error.localizedDescription)
        }
        await load()
    }
}

// MARK: - 自动抄作业

struct CopilotStageRow: Decodable, Sendable, Identifiable, Hashable {
    let stage: String
    let code: String?
    let nav: Bool?
    let reason: String?
    let status: String?
    let statusText: String?

    var id: String { stage }

    enum CodingKeys: String, CodingKey {
        case stage, code, nav, reason, status
        case statusText = "status_text"
    }
}

struct CopilotStages: Decodable, Sendable {
    let stages: [CopilotStageRow]
    let inActivity: Bool

    enum CodingKeys: String, CodingKey {
        case stages
        case inActivity = "in_activity"
    }
}

struct CopilotCandidate: Decodable, Sendable, Identifiable, Hashable {
    let id: Int
    let title: String?
    let uploader: String?
    let ratio: Double?
    let gaps: [String]?
    let softGaps: [String]?
    let views: Int?
    let ratingRatio: Double?
    let perfect: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, uploader, ratio, gaps, views, perfect
        case softGaps = "soft_gaps"
        case ratingRatio = "rating_ratio"
    }
}

struct CopilotPreview: Decodable, Sendable {
    let token: String
    let stage: String
    let modes: [String]?
    let sanityCost: Int?
    let bestId: Int?
    let blocker: String?
    let expiresAt: String?
    let total: Int?
    let candidates: [CopilotCandidate]

    enum CodingKeys: String, CodingKey {
        case token, stage, modes, blocker, total, candidates
        case sanityCost = "sanity_cost"
        case bestId = "best_id"
        case expiresAt = "expires_at"
    }
}

struct AutoCopilotView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var stages: CopilotStages?
    @State private var selectedStage: String?
    @State private var preview: CopilotPreview?
    @State private var chosen: Int?
    @State private var dispatchedToken: String?
    @State private var working = false
    @State private var message: (ok: Bool, text: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自动抄作业").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }
            }
            Text("只能选完全满足练度、没有任何缺口的作业；不吃药、不借助战、不忽略练度。确认后交给 maa-remote 派发，过同一个闸门。")
                .font(.callout).foregroundStyle(.secondary)
            HSplitView {
                stageList.frame(minWidth: 200, idealWidth: 220)
                candidateList.frame(minWidth: 380)
            }
            if let message {
                Text(message.text)
                    .foregroundStyle(message.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                if let token = dispatchedToken {
                    Button("刷新进度") { Task { await run(["copilot", "status", token]) } }
                    Button("取消本轮", role: .destructive) { Task { await run(["copilot", "cancel", token]) } }
                }
                // 不绑回车：自动选中后按一下回车就会派发，等于跳过了「确认开打」这一步（K13）。
                Button("确认开打") { Task { await go() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || chosen == nil || preview == nil || dispatchedToken != nil)
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 480)
        .task { await loadStages() }
    }

    private var stageList: some View {
        List(stages?.stages ?? [], selection: $selectedStage) { row in
            VStack(alignment: .leading) {
                Text(row.stage)
                Text(row.nav == false ? (row.reason ?? "导航不过去") : (row.statusText ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tag(row.stage)
            .disabled(row.nav == false)
        }
        .onChange(of: selectedStage) { _, stage in
            guard let stage else { return }
            Task { await loadPreview(stage) }
        }
    }

    @ViewBuilder private var candidateList: some View {
        if let preview {
            VStack(alignment: .leading) {
                Text("\(preview.stage)：搜到 \(preview.total ?? preview.candidates.count) 份；理智 \(preview.sanityCost.map(String.init) ?? "?")")
                    .font(.headline)
                if let blocker = preview.blocker, !blocker.isEmpty {
                    Text("现在不能派发：\(blocker)").foregroundStyle(.orange)
                }
                List(preview.candidates, selection: $chosen) { candidate in
                    HStack(alignment: .top) {
                        Image(systemName: candidate.perfect ? "checkmark.seal.fill" : "xmark.seal")
                            .foregroundStyle(candidate.perfect ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text("#\(candidate.id) \(candidate.title ?? "")").lineLimit(1)
                            Text(candidateDetail(candidate)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(candidate.id)
                    .selectionDisabled(!candidate.perfect)
                }
            }
        } else if working {
            ProgressView("搜作业中（5～20 秒）…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("左边选一关").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func candidateDetail(_ candidate: CopilotCandidate) -> String {
        var parts: [String] = []
        if let uploader = candidate.uploader { parts.append(uploader) }
        if let ratio = candidate.ratio { parts.append("满足 \(Int(ratio * 100))%") }
        let gaps = (candidate.gaps ?? []) + (candidate.softGaps ?? [])
        parts.append(gaps.isEmpty ? "没有缺口" : "缺：\(gaps.joined(separator: "、"))")
        return parts.joined(separator: " · ")
    }

    private func loadStages() async {
        do {
            stages = try await RemoteBridge.run(["copilot", "stages"]).decode(CopilotStages.self, snakeCase: false)
        } catch {
            message = (false, error.localizedDescription)
        }
    }

    private func loadPreview(_ stage: String) async {
        working = true
        defer { working = false }
        preview = nil
        chosen = nil
        dispatchedToken = nil
        do {
            let receipt = try await RemoteBridge.run(["copilot", "preview", stage], timeout: 120)
            message = (receipt.ok, receipt.message)
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
