"""Phase 2 S2-2 REST 全部读/写端点、`request_id` 预览子进程中止与路径防穿越单测。"""

from __future__ import annotations

import http.client
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import timedelta
from pathlib import Path
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_action  # noqa: E402
import maa_api  # noqa: E402
import maa_common  # noqa: E402
import maa_copilot  # noqa: E402
import maa_notify  # noqa: E402
import maa_schedule  # noqa: E402
import maa_tls  # noqa: E402
import maa_upstream  # noqa: E402

_DEVICE_GUARDS: list = []
_MODULE_PATCHES: list = []


def setUpModule() -> None:
    _DEVICE_GUARDS[:] = _isolation.guard_devices()
    _MODULE_PATCHES[:] = _helpers.start_module_patches()


def tearDownModule() -> None:
    _helpers.stop_patches(_MODULE_PATCHES)
    for item in reversed(_DEVICE_GUARDS):
        item.stop()
    _isolation.assert_shared_home_clean()


# 最小合法 1x1 PNG 字节，用于截图与缩略图测试。
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x02\x00\x00\x00\x90wS\xde\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0"
    b"\x00\x00\x03\x01\x01\x00\x18\xdd\x8d\xb0\x00\x00\x00\x00IEND\xaeB`\x82"
)


class DaemonAPITests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="daemon-api-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name) / "home"
        self.state_dir = self.home / "state" / "maa"
        self.runs_dir = self.state_dir / "runs"
        self.daemon_dir = self.home / "daemon"
        self.previews_dir = self.state_dir / "copilot" / "previews"
        for d in (self.runs_dir, self.daemon_dir, self.previews_dir):
            d.mkdir(parents=True, exist_ok=True)

        self.full_token = maa_tls.generate_token()
        self.secrets_path = self.daemon_dir / "secrets.json"
        maa_tls.merge_secrets(self.secrets_path, {"full_token_sha256": maa_tls.hash_token(self.full_token)})

        self.recorded_actions: list[tuple[list[str], str]] = []
        self.reloaded_count = 0

        def fake_action(argv: list[str], source: str, _timeout: float) -> dict[str, Any]:
            self.recorded_actions.append((argv, source))
            if argv[:3] == ["run", "cancel", "--run-id"] and argv[3] == "old-run-id":
                return {"ok": False, "code": "run_changed", "message": "当前运行的已经是另一场，没有停下。"}
            return {"ok": True, "code": "dispatched", "message": "ok", "data": {"argv": argv, "source": source}}

        self.ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=self.secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
            action_runner=fake_action,
            on_schedule_reload=self._bump_reload,
        )
        self.server = maa_api.create_server("127.0.0.1", 0, self.ctx)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self._thread.start()
        self.addCleanup(lambda: (self.server.shutdown(), self.server.server_close(), self._thread.join(timeout=2.0)))

    def _bump_reload(self) -> None:
        self.reloaded_count += 1

    def _req(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        token: str | None = None,
    ) -> tuple[int, str, bytes]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10.0)
        headers: dict[str, str] = {}
        tok = self.full_token if token is None else token
        if tok:
            headers["Authorization"] = f"Bearer {tok}"
        raw = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        if raw is not None:
            headers["Content-Type"] = "application/json"
        try:
            conn.request(method, path, body=raw, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.getheader("Content-Type", ""), resp.read()
        finally:
            conn.close()

    def _json(self, method: str, path: str, *, body: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
        st, _ct, raw = self._req(method, path, body=body)
        return st, json.loads(raw.decode("utf-8"))

    def test_all_read_endpoints_and_path_traversal_guard(self) -> None:
        # 准备状态文件：last_run, progress, report, screenshot, log, index.jsonl, activity_watch, scheduler, resign
        run_id = "2026-11-21-now-192135"
        cop_id = "2026-11-21-copilot-abc123-193000"
        old_id = "2026-11-10-am"
        maa_common.atomic_write_json(
            self.state_dir / "last_run.json",
            {
                "schema_version": 1,
                "run_id": run_id,
                "phase": "now",
                "status": "running",
                "started_at": "2026-11-21T19:21:35+08:00",
                "progress": str(self.runs_dir / f"{run_id}.progress.json"),
            },
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{run_id}.progress.json",
            {
                "schema_version": 1,
                "kind": "daily",
                "run_id": run_id,
                "started_at": "2026-11-21T19:21:35+08:00",
                "status": "running",
                "current": "fight",
            },
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{run_id}-report.json",
            {"title": "日常战报", "run_id": run_id, "status": "success"},
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{cop_id}-report.json",
            {"title": "抄作业战报", "run_id": cop_id, "kind": "copilot"},
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{old_id}-report.json",
            {"title": "旧命名战报", "phase": "am"},
        )
        (self.runs_dir / f"{run_id}.png").write_bytes(TINY_PNG)
        (self.runs_dir / f"{run_id}.log").write_text("line1\nline2\nline3\nline4\nline5\n", encoding="utf-8")
        (self.runs_dir / "index.jsonl").write_text(
            "\n".join(
                [
                    json.dumps({"schema_version": 1, "id": old_id, "kind": "daily", "status": "success"}),
                    "not-json-garbage",
                    json.dumps({"schema_version": 999, "id": "future-schema", "kind": "daily"}),
                    json.dumps({"schema_version": 1, "id": run_id, "kind": "daily", "status": "success"}),
                    json.dumps({"schema_version": 1, "id": cop_id, "kind": "copilot", "status": "success"}),
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        maa_common.atomic_write_json(self.state_dir / "activity_watch.json", {"status": "idle"})
        maa_common.atomic_write_json(self.daemon_dir / "scheduler.json", {"schema_version": 1, "jobs": {}})
        signed = maa_common.now_beijing()
        maa_common.atomic_write_json(
            self.daemon_dir / "resign.json",
            {
                "status": "running",
                "last_signed_at": signed.isoformat(),
                "expiration_date": (signed + timedelta(days=7)).isoformat(),
            },
        )

        with patch.object(maa_common, "run_lock_holder", return_value={"holder": "daily", "detail": "手动", "pid": 123, "run_id": run_id}), \
                patch.object(maa_common, "load_config", return_value={"schema_version": 1}), \
                patch.object(maa_action, "plan_today", return_value=(True, "ok", {"date": "2026-11-21", "sessions": []})), \
                patch.object(maa_schedule, "schedule_report", return_value={"backend": "daemon", "sessions": {}}), \
                patch.object(maa_upstream, "status", return_value={"verdict": "ok"}), \
                patch.object(maa_copilot, "auto_pause_state", return_value={"paused": True}), \
                patch.object(maa_action, "run_choices", return_value=(True, "ok", {"choices": [{"stage": "1-7"}]})), \
                patch.object(maa_action, "copilot_stages", return_value=(True, "ok", {"stages": [], "in_activity": False})), \
                patch.object(maa_action, "config_get", return_value=(True, "ok", {"fields": [], "values": {}})), \
                patch.object(maa_action, "defaults_show", return_value=(True, "ok", {"stage": "1-7", "tasks": {}})):

            # GET /rescue
            st, ct, raw = self._req("GET", "/rescue", token="")
            self.assertEqual(st, 200)
            self.assertIn("text/html", ct)
            self.assertIn("Wado's MAA", raw.decode("utf-8"))

            # GET /api/v1/snapshot
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertEqual(
                set(snap),
                {
                    "lock",
                    "last_run",
                    "progress",
                    "today_plan",
                    "schedule",
                    "upstream",
                    "copilot_auto_paused",
                    "activity",
                    "scheduler",
                    "resign",
                    "sanity",
                    "notify",
                    "errors",
                },
            )
            self.assertEqual(snap["errors"], {})
            self.assertEqual(snap["progress"]["run_id"], run_id)
            self.assertTrue(snap["copilot_auto_paused"])
            self.assertEqual(snap["resign"]["status"], "ok")
            self.assertIsNone(snap["sanity"])
            self.assertEqual(snap["notify"], {"configured": False})

            # GET /api/v1/choices, /copilot/stages, /config, /defaults
            self.assertEqual(self._json("GET", "/api/v1/choices")[1], {"choices": [{"stage": "1-7"}]})
            self.assertEqual(self._json("GET", "/api/v1/copilot/stages")[1], {"stages": [], "in_activity": False})
            self.assertEqual(self._json("GET", "/api/v1/config")[1], {"fields": [], "values": {}})
            self.assertEqual(self._json("GET", "/api/v1/defaults")[1], {"stage": "1-7", "tasks": {}})

        # GET /api/v1/history 倒序分页 + 跳过损坏/高版本行
        st, page1 = self._json("GET", "/api/v1/history?limit=2&offset=0")
        self.assertEqual(st, 200)
        self.assertEqual(page1["total"], 3)
        self.assertTrue(page1["has_more"])
        self.assertEqual([item["id"] for item in page1["items"]], [cop_id, run_id])

        st, page2 = self._json("GET", "/api/v1/history?limit=2&offset=2")
        self.assertEqual(st, 200)
        self.assertFalse(page2["has_more"])
        self.assertEqual([item["id"] for item in page2["items"]], [old_id])

        # GET /api/v1/history?kind=daily|copilot 过滤后计算 total 和 has_more
        st, daily_p1 = self._json("GET", "/api/v1/history?kind=daily&limit=1&offset=0")
        self.assertEqual(st, 200)
        self.assertEqual(daily_p1["total"], 2)
        self.assertTrue(daily_p1["has_more"])
        self.assertEqual([item["id"] for item in daily_p1["items"]], [run_id])

        st, daily_p2 = self._json("GET", "/api/v1/history?kind=daily&limit=1&offset=1")
        self.assertEqual(st, 200)
        self.assertEqual(daily_p2["total"], 2)
        self.assertFalse(daily_p2["has_more"])
        self.assertEqual([item["id"] for item in daily_p2["items"]], [old_id])

        st, cop_only = self._json("GET", "/api/v1/history?kind=copilot&limit=10&offset=0")
        self.assertEqual(st, 200)
        self.assertEqual(cop_only["total"], 1)
        self.assertFalse(cop_only["has_more"])
        self.assertEqual([item["id"] for item in cop_only["items"]], [cop_id])

        st, bad_kind = self._json("GET", "/api/v1/history?kind=unknown")
        self.assertEqual(st, 400)
        self.assertEqual(bad_kind["code"], "bad_args")

        # GET /api/v1/runs/<id>/report（日常 + 抄作业 + 旧命名 + 404）
        self.assertEqual(self._json("GET", f"/api/v1/runs/{run_id}/report")[1]["title"], "日常战报")
        self.assertEqual(self._json("GET", f"/api/v1/runs/{cop_id}/report")[1]["kind"], "copilot")
        self.assertEqual(self._json("GET", f"/api/v1/runs/{old_id}/report")[1]["title"], "旧命名战报")
        self.assertEqual(self._json("GET", "/api/v1/runs/no-such-run/report")[0], 404)

        # GET /api/v1/runs/<id>/screenshot（原图 & thumb=1）
        st, ct, img = self._req("GET", f"/api/v1/runs/{run_id}/screenshot")
        self.assertEqual(st, 200)
        self.assertEqual(ct, "image/png")
        self.assertEqual(img, TINY_PNG)

        st, ct, thumb = self._req("GET", f"/api/v1/runs/{run_id}/screenshot?thumb=1")
        self.assertEqual(st, 200)
        self.assertIn(ct, ("image/jpeg", "image/png"))
        self.assertTrue(len(thumb) > 0)

        # GET /api/v1/runs/<id>/log?tail=3
        st, log_res = self._json("GET", f"/api/v1/runs/{run_id}/log?tail=3")
        self.assertEqual(st, 200)
        self.assertEqual(log_res["lines"], ["line3", "line4", "line5"])
        self.assertTrue(log_res["truncated"])

        st, log_full = self._json("GET", f"/api/v1/runs/{run_id}/log?tail=10")
        self.assertEqual(st, 200)
        self.assertEqual(len(log_full["lines"]), 5)
        self.assertFalse(log_full["truncated"])

        # 路径穿越防御
        for bad_path in (
            "/api/v1/runs/../report",
            "/api/v1/runs/..%2fsecrets/report",
            "/api/v1/runs/%2e%2e/report",
            "/api/v1/runs/a%2fb/log",
            "/api/v1/runs/a/b/log",
        ):
            st, _ = self._json("GET", bad_path)
            self.assertEqual(st, 400, f"{bad_path} 应被拒为 400，实际 {st}")

    def test_all_write_endpoints_map_to_controlled_argv_with_ios_source(self) -> None:
        # 1. plan/stage (manual & auto)
        st, _ = self._json("POST", "/api/v1/plan/stage", body={"phase": "am", "stage": "1-7"})
        self.assertEqual(st, 200)
        st, _ = self._json("POST", "/api/v1/plan/stage", body={"phase": "pm", "auto": True})
        self.assertEqual(st, 200)

        # 2. plan/skip & plan/fight
        self.assertEqual(self._json("POST", "/api/v1/plan/skip", body={"phase": "am", "skip": True})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/plan/fight", body={"phase": "pm", "fight": False})[0], 200)

        # 3. run/local (with --force)
        switches = {"fight": True, "infrast": True, "recruit": True, "mall": True, "award": True, "annihilation": False}
        self.assertEqual(
            self._json("POST", "/api/v1/run/local", body={"stage": "TL-9", "switches": switches, "force": True})[0],
            200,
        )

        # 4. run/cancel 必须携带 run_id；缺失 400；旧 run_id 返回 run_changed
        self.assertEqual(self._json("POST", "/api/v1/run/cancel", body={})[0], 400)
        self.assertEqual(self._json("POST", "/api/v1/run/cancel", body={"run_id": ""})[0], 400)
        st, changed_resp = self._json("POST", "/api/v1/run/cancel", body={"run_id": "old-run-id"})
        self.assertEqual(st, 200)
        self.assertEqual(changed_resp["code"], "run_changed")
        self.assertEqual(self._json("POST", "/api/v1/run/cancel", body={"run_id": "2026-11-21-now-192135"})[0], 200)

        # 5. copilot/go, copilot/auto, copilot/mark
        self.assertEqual(self._json("POST", "/api/v1/copilot/go", body={"token": "abcdef123456", "candidate_id": 42})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/copilot/auto", body={"enabled": False})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/copilot/mark", body={"stage": "TL-9", "cleared": True, "mode": "all"})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/copilot/mark", body={"stage": "TL-9", "cleared": False})[0], 200)

        # 6. schedule（含 depot_enabled 与热重载回调）
        self.assertEqual(self._json("POST", "/api/v1/schedule", body={"phase": "am", "time": "08:30", "enabled": True})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/schedule", body={"depot_enabled": True})[0], 200)
        self.assertEqual(self.reloaded_count, 2)

        # 7. defaults, config, upstream/update
        self.assertEqual(self._json("POST", "/api/v1/defaults", body={"stage": "CE-6"})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/defaults", body={"task": "mall", "enabled": False})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/config", body={"key": "recruit_times", "value": 4})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/config", body={"patch": {"fight_times": 999}})[0], 200)
        self.assertEqual(self._json("POST", "/api/v1/upstream/update", body={})[0], 200)

        # 8. notify/test
        with patch.object(maa_notify, "send_test", return_value=(True, "推送已发送", {"backend": "bark"})):
            st, nres = self._json("POST", "/api/v1/notify/test", body={})
            self.assertEqual(st, 200)
            self.assertTrue(nres["ok"])
            self.assertEqual(nres["code"], "notify_sent")

        # 9. ios/resign
        st, rres = self._json("POST", "/api/v1/ios/resign?if_due=1", body={})
        self.assertEqual(st, 501)
        self.assertEqual(rres["code"], "not_configured")

        # 校验全部写动作均注入 source="ios" 且 argv 精确受控
        self.assertTrue(all(src == "ios" for _argv, src in self.recorded_actions))
        argvs = [argv for argv, _src in self.recorded_actions]
        self.assertIn(["plan", "set-stage", "1-7", "am"], argvs)
        self.assertIn(["plan", "auto-stage", "pm"], argvs)
        self.assertIn(["plan", "skip-today", "on", "am"], argvs)
        self.assertIn(["plan", "fight", "off", "pm"], argvs)
        self.assertIn(["run", "cancel", "--run-id", "2026-11-21-now-192135"], argvs)
        self.assertIn(["copilot", "go", "abcdef123456", "42"], argvs)
        self.assertIn(["copilot", "auto", "off"], argvs)
        self.assertIn(["copilot", "mark-cleared", "TL-9", "all"], argvs)
        self.assertIn(["copilot", "unmark", "TL-9"], argvs)
        self.assertIn(["schedule", "set", "am", "08:30"], argvs)
        self.assertIn(["schedule", "enable", "am"], argvs)
        self.assertIn(["schedule", "depot", "on"], argvs)
        self.assertIn(["defaults", "set", "stage", "CE-6"], argvs)
        self.assertIn(["defaults", "set", "task", "mall", "off"], argvs)
        self.assertIn(["config", "set", "recruit_times", "4"], argvs)
        self.assertIn(["config", "patch", '{"fight_times": 999}'], argvs)
        self.assertIn(["upstream", "update"], argvs)

    def test_delete_copilot_preview_kills_inflight_subprocess_and_cleans_file(self) -> None:
        """S2-2 验收项 2：`DELETE /api/v1/copilot/preview/<request_id>` 可靠中止正在搜索的子进程。"""
        spawned: list[subprocess.Popen[Any]] = []
        started = threading.Event()

        def slow_spawner(_argv: list[str], _env: dict[str, str]) -> subprocess.Popen[Any]:
            proc = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(30)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            spawned.append(proc)
            started.set()
            return proc

        self.ctx.preview_spawner = slow_spawner
        req_id = "11111111-2222-3333-4444-555555555555"
        post_result: dict[str, Any] = {}

        def run_post() -> None:
            st, body = self._json("POST", "/api/v1/copilot/preview", body={"stage": "TL-9", "request_id": req_id})
            post_result["status"] = st
            post_result["body"] = body

        t = threading.Thread(target=run_post, daemon=True)
        t.start()
        self.assertTrue(started.wait(timeout=3.0), "预览子进程未启动")
        time.sleep(0.1)

        st, del_resp = self._json("DELETE", f"/api/v1/copilot/preview/{req_id}")
        self.assertEqual(st, 200)
        self.assertTrue(del_resp["ok"])
        self.assertEqual(del_resp["code"], "preview_canceled")
        self.assertTrue(del_resp["data"]["killed"])

        t.join(timeout=5.0)
        self.assertFalse(t.is_alive(), "中止后 POST 预览线程未及时返回")
        self.assertEqual(post_result["status"], 200)
        self.assertEqual(post_result["body"]["code"], "preview_canceled")
        self.assertIsNotNone(spawned[0].poll(), "被取消的预览子进程仍存活")

        # 已完成预览文件也可通过 DELETE 清理
        preview_token = "a1b2c3d4e5f6"
        preview_file = self.previews_dir / f"{preview_token}.json"
        preview_file.write_text("{}", encoding="utf-8")
        st2, del2 = self._json("DELETE", f"/api/v1/copilot/preview/{preview_token}")
        self.assertEqual(st2, 200)
        self.assertEqual(del2["code"], "preview_deleted")
        self.assertFalse(preview_file.exists())

    def test_snapshot_isolates_corrupted_config_and_still_returns_lock_last_run_progress(self) -> None:
        """评审【2】回归：config.json 损坏时 /api/v1/snapshot 仍返回 200 及 lock/last_run/progress，并标注 errors。"""
        run_id = "2026-11-21-now-202000"
        maa_common.atomic_write_json(
            self.state_dir / "last_run.json",
            {
                "schema_version": 1,
                "run_id": run_id,
                "phase": "now",
                "status": "running",
                "started_at": "2026-11-21T20:20:00+08:00",
                "progress": str(self.runs_dir / f"{run_id}.progress.json"),
            },
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{run_id}.progress.json",
            {
                "schema_version": 1,
                "kind": "daily",
                "run_id": run_id,
                "started_at": "2026-11-21T20:20:00+08:00",
                "status": "running",
                "current": "fight",
            },
        )
        broken_cfg = self.state_dir / "config.json"
        broken_cfg.write_text("{corrupted-json", encoding="utf-8")

        with patch.object(maa_common, "CONFIG_PATH", broken_cfg), \
                patch.object(maa_common, "run_lock_holder", return_value={"holder": "daily", "detail": "手动", "pid": 999, "run_id": run_id}), \
                patch.object(maa_copilot, "auto_pause_state", return_value=None):
            st, snap = self._json("GET", "/api/v1/snapshot")

        self.assertEqual(st, 200)
        self.assertEqual(snap["lock"]["run_id"], run_id)
        self.assertEqual(snap["last_run"]["run_id"], run_id)
        self.assertEqual(snap["progress"]["run_id"], run_id)
        self.assertIsNone(snap["today_plan"])
        self.assertIsNone(snap["schedule"])
        self.assertIsNone(snap["upstream"])
        for failed_key in ("config", "today_plan", "schedule", "upstream"):
            self.assertIn(failed_key, snap["errors"])

    def test_active_progress_never_falls_back_to_previous_run_while_locked_and_enforces_started_at(self) -> None:
        """评审【5】回归：持锁且新进度文件尚未落盘时返回 None；空闲或持锁均严格遵守 started_at 规则。"""
        old_id = "2026-11-21-now-190000"
        new_id = "2026-11-21-now-203000"
        maa_common.atomic_write_json(
            self.state_dir / "last_run.json",
            {
                "schema_version": 1,
                "run_id": old_id,
                "phase": "now",
                "status": "success",
                "started_at": "2026-11-21T19:00:00+08:00",
                "progress": str(self.runs_dir / f"{old_id}.progress.json"),
            },
        )
        maa_common.atomic_write_json(
            self.runs_dir / f"{old_id}.progress.json",
            {
                "schema_version": 1,
                "kind": "daily",
                "run_id": old_id,
                "started_at": "2026-11-21T19:00:00+08:00",
                "status": "success",
                "current": None,
            },
        )

        # 1. 新场次刚拿到锁、新 progress.json 还没写出来 → 绝不能回退旧场次进度
        new_lock = {"holder": "daily", "detail": "手动", "pid": 456, "run_id": new_id}
        last_run = self.ctx._read_last_run()
        self.assertIsNone(self.ctx._read_active_progress(new_lock, last_run))

        # 2. update 等无 run_id 的持锁任务 → 也不返回旧场次进度
        update_lock = {"holder": "update", "detail": "gui", "pid": 457}
        self.assertIsNone(self.ctx._read_active_progress(update_lock, last_run))

        # 3. 新场次进度文件写入后，持锁态立刻读出新进度
        maa_common.atomic_write_json(
            self.runs_dir / f"{new_id}.progress.json",
            {
                "schema_version": 1,
                "kind": "daily",
                "run_id": new_id,
                "started_at": "2026-11-21T20:30:00+08:00",
                "status": "running",
                "current": "startup",
            },
        )
        prog = self.ctx._read_active_progress(new_lock, last_run)
        self.assertIsNotNone(prog)
        assert prog is not None
        self.assertEqual(prog["run_id"], new_id)

        # 4. 空闲态 started_at 对不上（如同名旧文件或缺失 started_at）→ 忽略返回 None
        maa_common.atomic_write_json(
            self.runs_dir / f"{old_id}.progress.json",
            {
                "schema_version": 1,
                "kind": "daily",
                "run_id": old_id,
                "started_at": "2026-11-20T19:00:00+08:00",
                "status": "success",
            },
        )
        self.assertIsNone(self.ctx._read_active_progress(None, last_run))

    def test_snapshot_sanity_returns_estimated_fields_and_null_when_missing(self) -> None:
        from datetime import datetime

        base_dt = datetime(2026, 11, 21, 10, 0, 0, tzinfo=maa_common.BEIJING)
        now_dt = datetime(2026, 11, 21, 11, 0, 0, tzinfo=maa_common.BEIJING)
        self.ctx.clock = lambda: now_dt

        with patch.object(maa_common, "run_lock_holder", return_value=None), \
                patch.object(maa_common, "load_config", return_value={"schema_version": 1}), \
                patch.object(maa_action, "plan_today", return_value=(True, "ok", {"date": "2026-11-21", "sessions": []})), \
                patch.object(maa_schedule, "schedule_report", return_value={"backend": "daemon", "sessions": {}}), \
                patch.object(maa_upstream, "status", return_value={"verdict": "ok"}), \
                patch.object(maa_copilot, "auto_pause_state", return_value=None):
            # 1. 无 roster.json 时 sanity 为 None
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertIsNone(snap["sanity"])

            # 2. 写入有效 roster.json（10:00 测得 80/208，11:00 应估算为 90/208）
            ts = int(base_dt.timestamp())
            roster_path = self.state_dir / "copilot" / "roster.json"
            maa_common.atomic_write_json(
                roster_path,
                {
                    "fetched_at": base_dt.isoformat(),
                    "source": "skland",
                    "chars": {},
                    "sanity": {
                        "current": 80,
                        "max": 208,
                        "last_ap_add_at": ts,
                        "server_current_at": ts,
                    },
                },
            )
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertEqual(
                snap["sanity"],
                {
                    "current": 80,
                    "max": 208,
                    "measured_at": base_dt.isoformat(),
                    "estimated_now": 90,
                },
            )

            # 3. 写入更新的 operbox 快照（无 sanity）→ 返回 None
            maa_common.atomic_write_json(
                self.state_dir / "copilot" / "roster-operbox.json",
                {
                    "fetched_at": now_dt.isoformat(),
                    "source": "operbox",
                    "chars": {},
                },
            )
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertIsNone(snap["sanity"])

    def test_snapshot_notify_configured_flag_never_leaks_secrets(self) -> None:
        secret_device = "SUPER_SECRET_BARK_DEVICE_KEY_999"
        secret_aes = "0123456789abcdef0123456789abcdef"  # 32 bytes

        with patch.object(maa_common, "run_lock_holder", return_value=None), \
                patch.object(maa_common, "load_config", return_value={"schema_version": 1}), \
                patch.object(maa_action, "plan_today", return_value=(True, "ok", {"date": "2026-11-21", "sessions": []})), \
                patch.object(maa_schedule, "schedule_report", return_value={"backend": "daemon", "sessions": {}}), \
                patch.object(maa_upstream, "status", return_value={"verdict": "ok"}), \
                patch.object(maa_copilot, "auto_pause_state", return_value=None):
            # 1. 未配置 → False
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertEqual(snap["notify"], {"configured": False})

            # 2. 配置 bark 但缺 aes key → False
            maa_common.atomic_write_json(self.daemon_dir / "daemon.json", {"notify_backend": "bark"})
            maa_tls.merge_secrets(self.secrets_path, {"bark_device_key": secret_device})
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertEqual(snap["notify"], {"configured": False})

            # 3. 补齐 32 字节 aes key → True，且绝不泄露任何密钥
            maa_tls.merge_secrets(self.secrets_path, {"bark_aes_key": secret_aes})
            st, _ct, raw = self._req("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            text = raw.decode("utf-8")
            snap = json.loads(text)
            self.assertEqual(snap["notify"], {"configured": True})
            self.assertEqual(set(snap["notify"]), {"configured"})
            self.assertNotIn(secret_device, text)
            self.assertNotIn(secret_aes, text)
            self.assertNotIn("bark_device_key", text)
            self.assertNotIn("bark_aes_key", text)
            self.assertNotIn("full_token_sha256", text)

            # 4. backend 切回 none → False
            maa_common.atomic_write_json(self.daemon_dir / "daemon.json", {"notify_backend": "none"})
            st, snap = self._json("GET", "/api/v1/snapshot")
            self.assertEqual(st, 200)
            self.assertEqual(snap["notify"], {"configured": False})


if __name__ == "__main__":
    unittest.main()
