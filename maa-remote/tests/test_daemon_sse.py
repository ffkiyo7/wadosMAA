"""Phase 2 S2-2 SSE 实时广播引擎（25s 心跳与 6 类状态变化推送）离线单测。"""

from __future__ import annotations

import http.client
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_api  # noqa: E402
import maa_tls  # noqa: E402

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


def _read_sse_frame(resp: http.client.HTTPResponse) -> tuple[str, str]:
    """从 SSE 响应流读取一条完整注释行或 event/data 帧。"""
    event_name = ""
    data_lines: list[str] = []
    while True:
        raw = resp.readline()
        if not raw:
            return "eof", ""
        line = raw.decode("utf-8").rstrip("\r\n")
        if line == "":
            if event_name or data_lines:
                return event_name or "message", "\n".join(data_lines)
            continue
        if line.startswith(":"):
            return "comment", line[1:].strip()
        if line.startswith("event:"):
            event_name = line.split(":", 1)[1].strip()
        elif line.startswith("data:"):
            data_lines.append(line.split(":", 1)[1].strip())


class DaemonSSETests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="daemon-sse-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name) / "home"
        self.state_dir = self.home / "state" / "maa"
        self.runs_dir = self.state_dir / "runs"
        self.daemon_dir = self.home / "daemon"
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        self.daemon_dir.mkdir(parents=True, exist_ok=True)

        self.token = maa_tls.generate_token()
        self.secrets_path = self.daemon_dir / "secrets.json"
        maa_tls.merge_secrets(self.secrets_path, {"full_token_sha256": maa_tls.hash_token(self.token)})

        self.state_lock = threading.Lock()
        self.state: dict[str, Any] = {
            "lock": None,
            "last_run": None,
            "progress": None,
            "today_plan": {"date": "2026-11-21", "sessions": []},
            "upstream": {"verdict": "ok"},
            "resign": None,
        }

        self.ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=self.secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
            sse_keepalive_seconds=0.25,
            sse_poll_seconds=0.05,
        )
        # 注入内存状态源，精准验证 SSE 广播行为
        self.ctx.build_sse_state = self._snapshot_state  # type: ignore[method-assign]

        self.server = maa_api.create_server("127.0.0.1", 0, self.ctx)
        self.port = self.server.server_address[1]
        self._thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self._thread.start()
        self.addCleanup(lambda: (self.server.shutdown(), self.server.server_close(), self._thread.join(timeout=2.0)))

    def _snapshot_state(self) -> dict[str, Any]:
        with self.state_lock:
            return json.loads(json.dumps(self.state))

    def test_sse_keepalive_and_state_change_events(self) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3.0)
        self.addCleanup(conn.close)
        conn.request("GET", "/api/v1/events", headers={"Authorization": f"Bearer {self.token}"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        self.assertIn("text/event-stream", resp.getheader("Content-Type", ""))
        self.assertEqual(resp.getheader("X-Accel-Buffering"), "no")

        # 1. 连接成功即收 : connected
        kind, text = _read_sse_frame(resp)
        self.assertEqual((kind, text), ("comment", "connected"))

        # 2. 无状态变化超过 0.25s → 收到 : keepalive
        kind, text = _read_sse_frame(resp)
        self.assertEqual((kind, text), ("comment", "keepalive"))

        # 3. 变更 lock + progress（覆盖日常与抄作业）+ resign → 立即收到对应 event
        with self.state_lock:
            self.state["lock"] = {"holder": "copilot", "detail": "TL-EX-1", "run_id": "2026-11-21-copilot-a1-200000"}
            self.state["progress"] = {"kind": "copilot", "status": "running", "current": "stage_0"}
            self.state["resign"] = {"status": "ok"}
        self.server.sse_hub.notify_changed()

        received: dict[str, Any] = {}
        deadline = time.monotonic() + 2.0
        while len(received) < 3 and time.monotonic() < deadline:
            ev, data = _read_sse_frame(resp)
            if ev in ("lock", "progress", "resign"):
                received[ev] = json.loads(data)
        self.assertEqual(set(received), {"lock", "progress", "resign"})
        self.assertEqual(received["lock"]["holder"], "copilot")
        self.assertEqual(received["progress"]["kind"], "copilot")
        self.assertEqual(received["resign"]["status"], "ok")

    def test_sse_ignores_volatile_upstream_checked_at_timestamp(self) -> None:
        """回归：upstream.checked_at 每次重算变化不应触发空转 SSE 刷屏。"""
        counter = {"n": 0}

        def provider() -> dict[str, Any]:
            counter["n"] += 1
            return {"upstream": {"verdict": "stale", "checked_at": f"2026-11-21T20:00:0{counter['n']}+08:00"}}

        hub = maa_api.SSEHub(provider)
        hub._seed_initial()
        self.assertEqual(hub.poll_once(), [])
        self.assertEqual(hub.poll_once(), [])

    def test_build_sse_state_isolates_failing_source_without_blocking_lock_events(self) -> None:
        """评审【2】回归：today_plan/upstream 任一抛异常时，build_sse_state 与 SSEHub 仍正常推送 lock 事件。"""
        from unittest.mock import patch

        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=self.secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
        )
        lock_state: dict[str, Any] = {"val": None}

        with patch.object(ctx, "_read_lock", side_effect=lambda: lock_state["val"]), \
                patch.object(ctx, "_read_today_plan", side_effect=RuntimeError("corrupt plan")), \
                patch.object(ctx, "_read_upstream", side_effect=ValueError("corrupt config")):
            hub = maa_api.SSEHub(ctx.build_sse_state)
            hub._seed_initial()
            sub = hub.subscribe()
            lock_state["val"] = {"holder": "daily", "run_id": "2026-11-21-now-202500"}
            emitted = hub.poll_once()

        self.assertIn("lock", emitted)
        item = sub.get_nowait()
        self.assertIsNotNone(item)
        assert item is not None
        self.assertEqual(item[0], "lock")
        self.assertEqual(item[1]["run_id"], "2026-11-21-now-202500")


if __name__ == "__main__":
    unittest.main()
