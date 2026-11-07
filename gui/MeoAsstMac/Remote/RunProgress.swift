//
//  RunProgress.swift
//  Wado's MAA
//
//  maa-remote 跑日常 / 手动场 / 抄作业时，跟着本场的 maa-cli 日志（`last_run.log`，DEV_GUIDE §12.3）
//  算出现在在哪个阶段。`RemoteStore` 每次读到 `last_run.json` 就喂进来；运行中每秒只读日志新增的部分
//  （`state/maa/` 的目录监听收不到 `runs/` 里的追加）。跑完、切环境就停。
//

import Foundation
import Observation

@MainActor @Observable final class RunProgress {
    struct Entry: Identifiable, Equatable {
        enum Tone { case run, stage, ok, error }

        let id = UUID()
        let date: Date
        /// 打开 App 时这一场已经跑了一段：之前那些阶段只知道顺序，不知道时刻。
        let exact: Bool
        let text: String
        let tone: Tone
    }

    /// 最近一场的阶段行（开始、各阶段、出错、结果）。新一场开跑时清空。
    private(set) var entries: [Entry] = []
    /// 正在跑的阶段；不在跑或还没到第一个阶段时是 nil。
    private(set) var current: RunStage?

    static let pollInterval: Duration = .seconds(1)
    /// 一次最多读这么多，日志再大也不会卡住主线程。
    static let readLimit = 4 * 1024 * 1024

    /// 正在跟（或刚跟完）的那一场：phase|started_at。
    @ObservationIgnored private var runKey: String?
    @ObservationIgnored private var finished = false
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var logURL: URL?
    @ObservationIgnored private var offset: UInt64 = 0
    /// 跟的时候日志还没建、或还是同名旧场的内容：之后读到的都是现场发生的。
    @ObservationIgnored private var sawNotReady = false
    @ObservationIgnored private var parser = RunStageParser(copilot: false, annihilationPlanned: false)
    @ObservationIgnored private var poll: Task<Void, Never>?

    /// 读到新的 `last_run.json` 时调用。
    func update(run: [String: JSONValue]) {
        let status = run["status"]?.string ?? ""
        let startedText = run["started_at"]?.string ?? ""
        let key = (run["phase"]?.string ?? "") + "|" + startedText
        if status == "running" {
            if key != runKey { begin(run: run, key: key, started: RunLock.parseISO(startedText)) }
            // 旧版 maa-remote 运行中不给 `log`，那就只有开始和结果两行。
            if let path = run["log"]?.string, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                if url != logURL {
                    logURL = url
                    resetRead()
                }
                startPolling()
            }
        } else if key == runKey, !finished, !LastRunText.ongoing.contains(status) {
            readNew()
            stopPolling()
            finished = true
            current = nil
            let ok = status == "success"
            entries.append(Entry(date: Date(), exact: true, text: "\(title) \(LastRunText.statusWord(status))",
                                 tone: ok || status == "skipped" ? .ok : .error))
        }
    }

    /// 切环境：停掉并清空。
    func stop() {
        stopPolling()
        runKey = nil
        finished = false
        logURL = nil
        entries = []
        current = nil
    }

    private func begin(run: [String: JSONValue], key: String, started: Date?) {
        stopPolling()
        runKey = key
        finished = false
        title = LastRunText.title(run)
        startedAt = started
        logURL = nil
        current = nil
        let annihilation = run["plan"]?.object?["annihilation"]?.bool == true
        parser = RunStageParser(copilot: LastRunText.isCopilot(run), annihilationPlanned: annihilation)
        resetRead()
        entries = [Entry(date: started ?? Date(), exact: started != nil, text: "\(title) 开始", tone: .run)]
    }

    private func resetRead() {
        offset = 0
        sawNotReady = false
    }

    private func startPolling() {
        guard poll == nil else { return }
        readNew()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.readNew()
            }
        }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func readNew() {
        guard let logURL else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            sawNotReady = true
            return
        }
        // maa run 开写前，同名文件可能还是今天上一场（比如第二次手动场）的内容。
        if let startedAt, let modified = attributes[.modificationDate] as? Date, modified < startedAt {
            sawNotReady = true
            return
        }
        if size < offset {
            // 被截断重写了：从头来。
            offset = 0
            parser = RunStageParser(copilot: parser.copilot, annihilationPlanned: parser.annihilationPlanned)
        }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let catchUp = offset == 0 && !sawNotReady
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.read(upToCount: min(Int(size - offset), Self.readLimit)), !data.isEmpty
        else { return }
        offset += UInt64(data.count)
        let date = catchUp ? (startedAt ?? Date()) : Date()
        for event in parser.feed(data) {
            switch event {
            case let .started(stage):
                current = stage
                entries.append(Entry(date: date, exact: !catchUp, text: stage.doing, tone: .stage))
            case let .failed(stage):
                entries.append(Entry(date: date, exact: !catchUp, text: "\(stage.label)未完成", tone: .error))
            case .allDone:
                current = RunStageParser.wrapUp
            }
        }
    }
}
