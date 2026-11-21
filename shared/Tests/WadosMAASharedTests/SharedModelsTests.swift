import Foundation
import Testing

@testable import WadosMAAShared

@Suite struct ReceiptTests {
    @Test func parsesReceiptAndFillsCode() throws {
        let ok = try #require(RemoteReceipt(json: Data(#"{"ok":true,"message":"好","data":{"a":1}}"#.utf8)))
        #expect(ok.code == "ok")
        #expect(ok.dictionary["a"] as? Int == 1)
        let failed = try #require(RemoteReceipt(json: Data(#"{"ok":false,"code":"session_soon","message":"快开了"}"#.utf8)))
        #expect(failed.code == "session_soon")
        #expect(failed.data == nil)
        #expect(RemoteReceipt(json: Data("[]".utf8)) == nil)
    }

    @Test func decodeFailureKeepsDetail() {
        let receipt = RemoteReceipt(ok: true, code: "ok", message: "m", detail: nil, data: nil)
        #expect(throws: RemoteReceiptDecodeError.self) { try receipt.decoded(HealthStatus.self) }
    }
}

@Suite struct ConfigTests {
    @Test func changeMetaNamesIOS() {
        let meta = ChangeMeta(source: "ios", updatedAt: "2026-11-22T00:05:00+08:00")
        #expect(meta.text == "由 Wado's MAA (iOS) 于 11-22 00:05 改")
    }

    @Test func scheduleReportReadsBuiltInScheduler() throws {
        let json = #"""
            {"backend":"daemon","timezone":"Asia/Shanghai","depot_enabled":false,
             "sessions":{"am":{"time":"08:00","enabled":true,"cron":{}}},
             "jobs":{"daily_am":{"id":"daily_am","enabled":true,"next_run_at":"2026-11-23T08:00:00+08:00"}}}
            """#
        let report = try JSONDecoder().decode(ScheduleReport.self, from: Data(json.utf8))
        #expect(report.backend == "daemon")
        #expect(report.sessions["am"]?.time == "08:00")
        #expect(report.jobs?["daily_am"]?.enabled == true)
    }
}

@Suite struct RunProgressFileTests {
    @Test func readsDailyProgress() throws {
        let json = #"""
            {"kind":"daily","run_id":"r1","status":"running","started_at":"2026-11-22T08:00:00+08:00",
             "current":"fight",
             "steps":[{"key":"startup","label":"启动游戏","state":"done"},
                      {"key":"fight","label":"刷理智","state":"running","started_at":"2026-11-22T08:02:00+08:00"}],
             "fight":{"done":3,"estimate":7,"sanity":{"current":104,"max":208},
                      "drops":[{"name":"电极单元","count":2},{"name":"","count":9}]},
             "notes":[{"at":"2026-11-22T08:01:00+08:00","text":"重试了一次"},{"text":""}],
             "eta":"2026-11-22T08:30:00+08:00"}
            """#
        let file = try #require(RunProgressFile(data: Data(json.utf8)))
        #expect(file.steps.map(\.key) == ["StartUp", "Fight"])
        #expect(file.currentKey == "Fight")
        #expect(file.fightsDone == 3)
        #expect(file.fightEstimate == 7)
        #expect(file.sanity == .init(current: 104, max: 208))
        #expect(file.drops == [.init(name: "电极单元", count: 2)])
        #expect(file.notes.count == 1)
        #expect(file.eta != nil)
        #expect(file.copilot == nil)
    }

    @Test func readsCopilotProgress() throws {
        let json = #"""
            {"kind":"copilot","run_id":"c1","status":"running",
             "steps":[{"key":"TL-10:normal","label":"TL-10","state":"running"}],
             "copilot":{"done":1,"total":3,"current_stage":"TL-10","current_mode":"normal","elapsed_seconds":90}}
            """#
        let file = try #require(RunProgressFile(data: Data(json.utf8)))
        #expect(file.kind == "copilot")
        #expect(file.copilot == .init(done: 1, total: 3, currentStage: "TL-10", currentMode: "normal", elapsedSeconds: 90))
    }
}

@Suite struct SnapshotTests {
    @Test func oneBadFieldKeepsLockAndProgress() throws {
        let json = #"""
            {"lock":{"holder":"daily","detail":"早","pid":1,"since":"2026-11-22T08:00:00+08:00","run_id":"r1"},
             "last_run":{"status":"running","phase":"am"},
             "progress":{"kind":"daily","run_id":"r1","steps":[]},
             "today_plan":{"date":123},
             "schedule":null,"upstream":null,"copilot_auto_paused":true,
             "activity":null,"scheduler":{"jobs":{"daily_am":{"enabled":true}}},"resign":null,
             "errors":{"config":"bad"}}
            """#
        let snapshot = try #require(RemoteSnapshot(data: Data(json.utf8)))
        #expect(snapshot.lock?.runId == "r1")
        #expect(snapshot.lock?.name == "早场日常")
        #expect(snapshot.progress?.runId == "r1")
        #expect(snapshot.todayPlan == nil)
        #expect(snapshot.errors["today_plan"] != nil)
        #expect(snapshot.errors["config"] == "bad")
        #expect(snapshot.copilotAutoPaused == true)
        #expect(snapshot.scheduler?.jobs["daily_am"]?.enabled == true)
    }

    @Test func sseClearsLockAndUpdatesProgress() throws {
        var snapshot = RemoteSnapshot()
        snapshot.lock = LockHolder(holder: "daily", detail: nil, pid: nil, since: nil, runId: "r1")
        let clearedLock = snapshot.apply(SSEEvent(name: "lock", data: "null"))
        #expect(clearedLock)
        #expect(snapshot.lock == nil)
        let updated = snapshot.apply(SSEEvent(name: "progress", data: #"{"kind":"daily","run_id":"r2","steps":[]}"#))
        #expect(updated)
        #expect(snapshot.progress?.runId == "r2")
        let unknown = snapshot.apply(SSEEvent(name: "unknown", data: "{}"))
        #expect(!unknown)
    }

    @Test func historyPageSkipsBadRows() throws {
        let json = #"""
            {"items":[{"id":"a","phase":"am","status":"success","stage":"TL-9"},{"id":"b"},
                      {"id":"c","phase":"pm","status":"success","schema_version":99}],
             "total":3,"has_more":true}
            """#
        let page = try #require(HistoryPage(data: Data(json.utf8)))
        #expect(page.items.map(\.id) == ["a"])
        #expect(page.total == 3)
        #expect(page.hasMore)
    }
}

@Suite struct PairingTests {
    private let fingerprint = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func acceptsValidPayload() throws {
        let text = #"{"lan_url":"https://192.168.50.2:18170","remote_url":"https://maa.example.com","spki_sha256":"\#(fingerprint)","full_token":"t"}"#
        let payload = try #require(PairingPayload(text: text))
        #expect(payload.lanURL.port == 18170)
        #expect(payload.fullToken == "t")
    }

    @Test func rejectsPlainHTTPAndBadFingerprint() {
        #expect(PairingPayload(text: #"{"lan_url":"http://192.168.50.2:18170","remote_url":"https://m.example.com","spki_sha256":"\#(fingerprint)"}"#) == nil)
        #expect(PairingPayload(text: #"{"lan_url":"https://192.168.50.2:18170","remote_url":"https://m.example.com","spki_sha256":"abc"}"#) == nil)
    }
}

@Suite struct SSEParserTests {
    @Test func parsesEventsAndIgnoresHeartbeat() {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in [": connected", "", "event: lock", #"data: {"a":1}"#, "", ": keepalive", "", "data: x", "data: y", ""] {
            if let event = parser.feed(line: line) { events.append(event) }
        }
        #expect(events == [SSEEvent(name: "lock", data: #"{"a":1}"#), SSEEvent(name: "message", data: "x\ny")])
    }
}

@Suite struct RunStageParserTests {
    @Test func tracksFightAndSanity() {
        var parser = RunStageParser(copilot: false, annihilationPlanned: true)
        #expect(parser.parse(line: "Fight Start") == .started(RunStage(key: "Annihilation", label: "剿灭", doing: "正在打剿灭")))
        #expect(parser.parse(line: "Fight Completed") == .completed(RunStage(key: "Annihilation", label: "剿灭", doing: "正在打剿灭")))
        #expect(parser.parse(line: "Fight Start") == .started(RunStage(key: "Fight", label: "刷理智", doing: "正在刷理智")))
        #expect(parser.parse(line: "Mission started (3 times, use 90 sanity)") == .missions(times: 3, sanity: 90))
        #expect(parser.parse(line: "Current sanity: 104/208") == .sanity(104))
    }
}

@Suite struct AppFieldTests {
    @Test func readsSanityAndNotify() throws {
        let json = #"{"sanity":{"current":11,"max":208,"measured_at":"2026-11-22T08:18:00+08:00","estimated_now":148},"notify":{"configured":true}}"#
        let snapshot = try #require(RemoteSnapshot(data: Data(json.utf8)))
        #expect(snapshot.sanity?.current == 11)
        #expect(snapshot.sanity?.max == 208)
        #expect(snapshot.sanity?.estimatedNow == 148)
        #expect(snapshot.sanity?.measuredAt != nil)
        #expect(snapshot.notify?.configured == true)
    }

    @Test func oldBackendHasNoSanityOrNotify() throws {
        let snapshot = try #require(RemoteSnapshot(data: Data("{}".utf8)))
        #expect(snapshot.sanity == nil)
        #expect(snapshot.notify == nil)
    }

    @Test func stageCategoryFallsBackToName() throws {
        func row(_ json: String) throws -> CopilotStageRow {
            try JSONDecoder().decode(CopilotStageRow.self, from: Data(json.utf8))
        }
        #expect(try row(#"{"stage":"TL-1","category":"s"}"#).stageCategory == "s")
        #expect(try row(#"{"stage":"TL-EX-3"}"#).stageCategory == "ex")
        #expect(try row(#"{"stage":"TL-S-2"}"#).stageCategory == "s")
        #expect(try row(#"{"stage":"TL-9"}"#).stageCategory == "normal")
    }

    @Test func copilotRecordKeepsWonAndTotal() throws {
        let record = try #require(
            RunRecord(row: [
                "id": .string("c1"), "phase": .string("copilot-c1"), "status": .string("success"),
                "won": .number(3), "total": .number(3),
            ]))
        #expect(record.isCopilot)
        #expect(record.won == 3)
        #expect(record.total == 3)
    }
}
