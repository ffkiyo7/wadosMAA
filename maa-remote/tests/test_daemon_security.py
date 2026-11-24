"""Phase 2 S2-1 / S2-3 / S2-4 安全边界、TLS 抗挂死、证书生命周期、隧道配置与应急页单测。"""

from __future__ import annotations

import http.client
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "daemon"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import init_daemon  # noqa: E402
import maa_api  # noqa: E402
import maa_common  # noqa: E402
import maa_tls  # noqa: E402
import rotate_tls  # noqa: E402
from _helpers import BEIJING  # noqa: E402

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


def _has_openssl3() -> bool:
    try:
        maa_tls.find_openssl3()
        return True
    except RuntimeError:
        return False


def _tls_request(
    port: int,
    method: str,
    path: str,
    *,
    token: str = "",
    body: dict[str, Any] | None = None,
    timeout: float = 5.0,
) -> tuple[int, dict[str, Any]]:
    ctx = ssl._create_unverified_context()
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=timeout, context=ctx)
    headers: dict[str, str] = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    raw_body: bytes | None = None
    if body is not None:
        raw_body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=raw_body, headers=headers)
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, json.loads(data.decode("utf-8")) if data else {}
    finally:
        conn.close()


class DaemonSecurityTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="daemon-sec-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name) / "home"
        self.daemon_dir = self.home / "daemon"
        self.state_dir = self.home / "state" / "maa"
        self.runs_dir = self.state_dir / "runs"
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        self.daemon_dir.mkdir(parents=True, exist_ok=True)

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_slow_tls_handshake_times_out_without_blocking_concurrent_requests(self) -> None:
        """S2-1 验收项 1：慢速半开 TCP 连接不发 ClientHello，超时自动断开且并发正常请求零阻塞。"""
        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=30)

        full_token = maa_tls.generate_token()
        secrets_path = self.daemon_dir / "secrets.json"
        maa_tls.merge_secrets(secrets_path, {"full_token_sha256": maa_tls.hash_token(full_token)})

        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
            handshake_timeout=0.6,
        )
        server = maa_api.create_server("127.0.0.1", 0, ctx, cert_path=cert_path, key_path=key_path)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=2.0)))

        # 建立 3 条恶意半开 TCP 连接，故意不发 TLS ClientHello。
        slow_socks: list[socket.socket] = []
        for _ in range(3):
            s = socket.create_connection(("127.0.0.1", port), timeout=2.0)
            s.settimeout(3.0)
            slow_socks.append(s)
        self.addCleanup(lambda: [s.close() for s in slow_socks])

        # 在慢连接挂着期间，正常 HTTPS 请求应毫秒级完成，不被阻塞。
        t0 = time.monotonic()
        status, payload = _tls_request(port, "GET", "/healthz")
        elapsed = time.monotonic() - t0
        self.assertEqual(status, 200)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["service"], "wados-maa")
        self.assertLess(elapsed, 0.4, f"正常请求被慢连接拖慢：{elapsed:.2f}s")

        # 超过 handshake_timeout（0.6s）后，半开连接应被服务端主动关闭（recv 返回 b""）。
        for s in slow_socks:
            chunk = s.recv(16)
            self.assertEqual(chunk, b"", "慢速半开连接未被服务端超时断开")

    def test_ip_allowlist_and_token_scopes(self) -> None:
        """S2-1 验收项 2：来源 IP 白名单、无效 Token 401、`resign_only` 越权 403。"""
        nets = maa_api._parse_networks(maa_api.DEFAULT_ALLOWED_CIDRS)
        for allowed in ("127.0.0.1", "::1", "::ffff:127.0.0.1", "192.168.50.2", "192.168.50.201", "::ffff:192.168.50.99"):
            self.assertTrue(maa_api.is_ip_allowed(allowed, nets), allowed)
        for denied in ("192.168.51.2", "192.168.1.10", "10.0.0.5", "8.8.8.8", "not-an-ip"):
            self.assertFalse(maa_api.is_ip_allowed(denied, nets), denied)

        # 未配置 secrets.json 时 fail-closed（任何 Token 均拒）
        secrets_path = self.daemon_dir / "secrets.json"
        full_token = maa_tls.generate_token()
        resign_token = maa_tls.generate_token()

        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
            action_runner=lambda argv, src, _t: {"ok": True, "code": "ok", "message": "ok", "data": {"argv": argv, "source": src}},
        )
        server = maa_api.create_server("127.0.0.1", 0, ctx)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=2.0)))

        def req(method: str, path: str, *, token: str = "", body: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5.0)
            headers: dict[str, str] = {}
            if token:
                headers["Authorization"] = f"Bearer {token}"
            raw = json.dumps(body).encode("utf-8") if body is not None else None
            if raw is not None:
                headers["Content-Type"] = "application/json"
            try:
                conn.request(method, path, body=raw, headers=headers)
                r = conn.getresponse()
                data = r.read()
                return r.status, json.loads(data.decode("utf-8")) if data else {}
            finally:
                conn.close()

        # 1. /healthz 免鉴权，且不泄露敏感字段
        st, body = req("GET", "/healthz")
        self.assertEqual(st, 200)
        self.assertEqual(set(body), {"ok", "service", "api_version", "server_time"})

        # 2. 空 secrets 时必须 401（fail-closed）
        st, _ = req("GET", "/api/v1/snapshot", token=full_token)
        self.assertEqual(st, 401)

        # 写入双域 Token 哈希
        maa_tls.merge_secrets(
            secrets_path,
            {
                "full_token_sha256": maa_tls.hash_token(full_token),
                "resign_only_token_sha256": maa_tls.hash_token(resign_token),
            },
        )

        # 3. 缺少或错误 Token → 401
        self.assertEqual(req("GET", "/api/v1/snapshot")[0], 401)
        self.assertEqual(req("GET", "/api/v1/snapshot", token="wrong-token")[0], 401)

        # 4. resign_only 只能调 POST /api/v1/ios/resign（含 ?if_due=1），其他全部 403
        for method, path, payload in (
            ("GET", "/api/v1/snapshot", None),
            ("GET", "/api/v1/events", None),
            ("GET", "/api/v1/config", None),
            ("POST", "/api/v1/run/cancel", {"run_id": "2026-11-21-now-120000"}),
            ("POST", "/api/v1/plan/skip", {"phase": "am", "skip": True}),
            ("DELETE", "/api/v1/copilot/preview/12345678-1234-1234-1234-1234567890ab", None),
        ):
            st, err = req(method, path, token=resign_token, body=payload)
            self.assertEqual(st, 403, f"{method} {path} 应返回 403，实际 {st}: {err}")
            self.assertEqual(err.get("code"), "forbidden")

        st, res = req("POST", "/api/v1/ios/resign?if_due=1", token=resign_token, body={})
        self.assertEqual(st, 501)
        self.assertEqual(res["code"], "not_configured")
        self.assertTrue(res["data"]["if_due"])

        # 5. 非白名单来源 IP 服务端直接断连
        blocked_ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
            allowed_cidrs=("192.168.50.0/24",),  # 故意去掉 127.0.0.1
        )
        blocked_srv = maa_api.create_server("127.0.0.1", 0, blocked_ctx)
        bport = blocked_srv.server_address[1]
        bthread = threading.Thread(target=blocked_srv.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        bthread.start()
        self.addCleanup(lambda: (blocked_srv.shutdown(), blocked_srv.server_close(), bthread.join(timeout=2.0)))

        with socket.create_connection(("127.0.0.1", bport), timeout=2.0) as raw_sock:
            raw_sock.settimeout(2.0)
            try:
                raw_sock.sendall(b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n")
                self.assertEqual(raw_sock.recv(1024), b"")
            except (ConnectionResetError, BrokenPipeError):
                pass

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_cert_generation_named_curve_spki_expiry_alert_and_rotation(self) -> None:
        """S2-1 验收项 3：named_curve P-256 证书、SPKI 指纹、到期前 60 天告警与平滑轮换。"""
        # 预先写入 Bark 密钥，确认 init_daemon 绝不覆盖已有密钥
        secrets_path = self.daemon_dir / "secrets.json"
        maa_common.atomic_write_json(
            secrets_path,
            {"bark_device_key": "dev-keep", "bark_aes_key": "0123456789abcdef0123456789abcdef"},
        )

        result = init_daemon.init_daemon_home(
            self.home,
            lan_ip="192.168.50.2",
            remote_url="https://maa.luxraykit.com",
            api_port=18170,
            days=45,  # 故意设 45 天，落在 60 天告警窗内
        )
        self.assertTrue(result["ok"])
        self.assertTrue(result["cert_created"])
        cert_path = Path(result["cert"]["cert_path"])
        key_path = Path(result["cert"]["key_path"])
        self.assertEqual(os.stat(key_path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(secrets_path).st_mode & 0o777, 0o600)

        # 验证 OpenSSL 3 named_curve + SAN
        openssl = maa_tls.find_openssl3()
        txt = subprocess.run(
            [openssl, "x509", "-in", str(cert_path), "-text", "-noout"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        self.assertIn("prime256v1", txt)
        self.assertIn("IP Address:192.168.50.2", txt)
        self.assertIn("IP Address:127.0.0.1", txt)

        # 验证 SPKI 指纹格式（32 字节 SHA-256 的 Base64 为 44 字符且以 '=' 结尾）
        spki = result["cert"]["spki_sha256"]
        self.assertEqual(len(spki), 44)
        self.assertEqual(spki, maa_tls.compute_spki_sha256(cert_path))

        # 验证 Bark 密钥保留且只存 Token 哈希不存明文
        saved_secrets = json.loads(secrets_path.read_text(encoding="utf-8"))
        self.assertEqual(saved_secrets["bark_device_key"], "dev-keep")
        self.assertNotIn("full_token", saved_secrets)
        self.assertTrue(maa_tls.verify_token(result["pairing"]["full_token"], saved_secrets["full_token_sha256"]))
        self.assertTrue(maa_tls.verify_token(result["resign_only_token"], saved_secrets["resign_only_token_sha256"]))

        # 验证到期前 60 天告警 + 当天去重 + 次日再告警
        sent: list[dict[str, Any]] = []

        def fake_notify(title: str, body: str, **kwargs: Any) -> bool:
            sent.append({"title": title, "body": body, **kwargs})
            return True

        check_path = self.daemon_dir / "tls_check.json"
        day1 = datetime(2026, 11, 21, 9, 0, tzinfo=BEIJING)
        r1 = maa_tls.check_cert_expiry_and_notify(cert_path, check_path, now=day1, warn_days=60, notify_fn=fake_notify)
        self.assertTrue(r1["warn_due"])
        self.assertTrue(r1["notified"])
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0]["level"], "timeSensitive")
        self.assertEqual(sent[0]["notification_id"], "tls-cert")

        # 同一天再巡检不重复发
        r2 = maa_tls.check_cert_expiry_and_notify(
            cert_path, check_path, now=day1 + timedelta(hours=3), warn_days=60, notify_fn=fake_notify
        )
        self.assertFalse(r2["notified"])
        self.assertEqual(len(sent), 1)

        # 验证两步平滑轮换（stage → activate）产生新 SPKI、触发可注入重载器并备份旧证书
        reloaded_calls: list[tuple[str, str]] = []
        staged = rotate_tls.stage_next_cert(self.home, lan_ip="192.168.50.2", days=1825)
        self.assertNotEqual(staged["spki_sha256"], spki)
        activated = rotate_tls.activate_next_cert(
            self.home,
            daemon_reloader=lambda home, new_spki: (reloaded_calls.append(("daemon", new_spki)) or {"status": "reloaded"}),
            cloudflared_reloader=lambda home: (reloaded_calls.append(("cloudflared", str(home))) or {"status": "reloaded"}),
        )
        self.assertEqual(activated["spki_sha256"], staged["spki_sha256"])
        self.assertEqual([c[0] for c in reloaded_calls], ["daemon", "cloudflared"])
        self.assertTrue(Path(activated["backup_dir"]).is_dir())
        self.assertEqual(maa_tls.compute_spki_sha256(cert_path), staged["spki_sha256"])

        # 新 5 年证书不在 60 天告警窗内
        r3 = maa_tls.check_cert_expiry_and_notify(
            cert_path, check_path, now=day1 + timedelta(days=1), warn_days=60, notify_fn=fake_notify
        )
        self.assertFalse(r3["warn_due"])
        self.assertFalse(r3["notified"])

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_tls_hot_reload_updates_served_cert_and_expiry_checks_served_cert(self) -> None:
        """评审【4】回归：daemon 热重载真正切换在服务证书；未重载时到期巡检仍按旧在服务证书告警；重载失败明确报错。"""
        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        old_info = maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=20)

        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=self.daemon_dir / "secrets.json",
            rescue_html_path=ROOT / "daemon" / "rescue.html",
        )
        server = maa_api.create_server("127.0.0.1", 0, ctx, cert_path=cert_path, key_path=key_path)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=2.0)))

        def fetch_peer_der() -> bytes:
            cctx = ssl._create_unverified_context()
            with socket.create_connection(("127.0.0.1", port), timeout=3.0) as raw:
                with cctx.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                    der = tls.getpeercert(binary_form=True)
                    assert der is not None
                    return der

        der_before = fetch_peer_der()
        served_before = server.get_active_cert_info()
        assert served_before is not None
        self.assertEqual(served_before["spki_sha256"], old_info["spki_sha256"])

        # 仅替换磁盘证书为 5 年新证书，故意不重载服务端：巡检按在服务旧证书（20天）仍必须告警！
        staged = rotate_tls.stage_next_cert(self.home, lan_ip="192.168.50.2", days=1825)
        with self.assertRaises(RuntimeError):
            rotate_tls.activate_next_cert(
                self.home,
                daemon_reloader=lambda _h, _s: (_ for _ in ()).throw(RuntimeError("daemon reload timeout")),
                cloudflared_reloader=lambda _h: {"status": "not_running"},
            )
        sent: list[str] = []
        check_path = self.daemon_dir / "tls_check.json"
        r_old = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            warn_days=60,
            served_info=server.get_active_cert_info(),
            notify_fn=lambda title, _body, **_kw: (sent.append(title) or True),
        )
        self.assertTrue(r_old["warn_due"])
        self.assertTrue(r_old["notified"])
        self.assertEqual(len(sent), 1)

        # 热重载 TLS 后：新连接收到新证书，且巡检识别新指纹不再告警。
        new_meta = server.reload_tls()
        self.assertEqual(new_meta["spki_sha256"], staged["spki_sha256"])
        der_after = fetch_peer_der()
        self.assertNotEqual(der_before, der_after)

        r_new = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            warn_days=60,
            served_info=server.get_active_cert_info(),
            notify_fn=lambda title, _body, **_kw: (sent.append(title) or True),
        )
        self.assertFalse(r_new["warn_due"])
        self.assertFalse(r_new["notified"])
        self.assertEqual(len(sent), 1)

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_cert_expiry_notify_backoff_disabled_skip_and_nonblocking_monitor(self) -> None:
        """评审【7】回归：推送失败每小时最多重试一次、未启用推送不重试、后台巡检不阻塞调度主循环。"""
        import maa_daemon

        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=20)
        check_path = self.daemon_dir / "tls_check.json"

        # 1. 未启用推送：记录 skipped，当天不再重试
        day1 = datetime(2026, 11, 21, 9, 0, tzinfo=BEIJING)
        calls = 0

        def failing_notify(_t: str, _b: str, **_kw: Any) -> bool:
            nonlocal calls
            calls += 1
            return False

        r_disabled_1 = maa_tls.check_cert_expiry_and_notify(
            cert_path, check_path, now=day1, warn_days=60, notify_fn=failing_notify, notify_enabled=False
        )
        self.assertTrue(r_disabled_1["skipped"])
        self.assertEqual(calls, 0)
        r_disabled_2 = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            now=day1 + timedelta(hours=2),
            warn_days=60,
            notify_fn=failing_notify,
            notify_enabled=False,
        )
        self.assertTrue(r_disabled_2["cached"])
        self.assertTrue(r_disabled_2["skipped"])
        self.assertEqual(calls, 0)

        # 2. 启用推送但失败：10 秒 / 30 分钟内退避不重试，满 1 小时才允许重试一次
        r_fail_1 = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            now=day1 + timedelta(hours=3),
            warn_days=60,
            notify_fn=failing_notify,
            notify_enabled=True,
            retry_backoff_seconds=3600,
        )
        self.assertFalse(r_fail_1["notified"])
        self.assertEqual(calls, 1)

        r_backoff_10s = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            now=day1 + timedelta(hours=3, seconds=10),
            warn_days=60,
            notify_fn=failing_notify,
            notify_enabled=True,
            retry_backoff_seconds=3600,
        )
        self.assertTrue(r_backoff_10s["backoff"])
        self.assertEqual(calls, 1)

        r_backoff_30m = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            now=day1 + timedelta(hours=3, minutes=30),
            warn_days=60,
            notify_fn=failing_notify,
            notify_enabled=True,
            retry_backoff_seconds=3600,
        )
        self.assertTrue(r_backoff_30m["backoff"])
        self.assertEqual(calls, 1)

        r_retry_1h = maa_tls.check_cert_expiry_and_notify(
            cert_path,
            check_path,
            now=day1 + timedelta(hours=4, seconds=1),
            warn_days=60,
            notify_fn=failing_notify,
            notify_enabled=True,
            retry_backoff_seconds=3600,
        )
        self.assertTrue(r_retry_1h["checked"])
        self.assertEqual(calls, 2)

        # 3. AsyncCertMonitor 后台异步执行且防重入，绝不阻塞调度主循环
        gate = threading.Event()
        started = threading.Event()

        def slow_checker(*_args: Any, **_kwargs: Any) -> dict[str, Any]:
            started.set()
            gate.wait(timeout=2.0)
            return {"checked": True}

        monitor = maa_daemon.AsyncCertMonitor(checker=slow_checker)
        t0 = time.monotonic()
        self.assertTrue(monitor.trigger(cert_path, check_path, warn_days=60))
        elapsed = time.monotonic() - t0
        self.assertLess(elapsed, 0.1, f"后台巡检派发阻塞了主循环：{elapsed:.2f}s")
        self.assertTrue(started.wait(timeout=1.0))
        # 运行中再次 trigger 立即跳过，不重叠堆积线程
        self.assertFalse(monitor.trigger(cert_path, check_path, warn_days=60))
        gate.set()
        monitor.wait(timeout=2.0)

    def test_pure_python_qr_encoder_and_terminal_render(self) -> None:
        pairing = json.dumps(
            {
                "lan_url": "https://192.168.50.2:18170",
                "remote_url": "https://maa.luxraykit.com",
                "spki_sha256": "A" * 43 + "=",
                "full_token": "tok_" + "x" * 40,
            },
            separators=(",", ":"),
        )
        matrix = maa_tls.encode_qr_matrix(pairing)
        size = len(matrix)
        self.assertGreaterEqual(size, 45)
        self.assertTrue(all(len(row) == size for row in matrix))
        # 左上 Finder Pattern 7x7 外框全黑、中心 3x3 全黑
        self.assertTrue(all(matrix[0][c] for c in range(7)))
        self.assertTrue(all(matrix[6][c] for c in range(7)))
        self.assertTrue(all(matrix[r][c] for r in range(2, 5) for c in range(2, 5)))
        # Dark module 固定在 (size-8, 8)
        self.assertTrue(matrix[size - 8][8])

        rendered = maa_tls.render_qr_terminal(pairing)
        self.assertTrue(any(ch in rendered for ch in ("█", "▀", "▄")))

    def test_qr_keeps_alignment_patterns_and_both_format_copies(self) -> None:
        """Version 7 起校正图案会落在时序线上，漏画后手机无法解码配对码。"""
        for length in (60, 150, 199, 270, 400, 580):
            with self.subTest(length=length):
                matrix = maa_tls.encode_qr_matrix("x" * length)
                size = len(matrix)
                version = (size - 17) // 4
                centers = maa_tls._QR_ALIGNMENT[version]
                corners = {
                    (centers[0], centers[0]),
                    (centers[0], centers[-1]),
                    (centers[-1], centers[0]),
                }
                for row in centers:
                    for col in centers:
                        if (row, col) in corners:
                            continue
                        for dr in range(-2, 3):
                            for dc in range(-2, 3):
                                self.assertEqual(
                                    matrix[row + dr][col + dc],
                                    max(abs(dr), abs(dc)) != 1,
                                    f"version={version} center=({row},{col}) offset=({dr},{dc})",
                                )

                first = [matrix[i][8] for i in range(6)] + [matrix[7][8], matrix[8][8], matrix[8][7]]
                first += [matrix[8][14 - i] for i in range(9, 15)]
                second = [matrix[8][size - 1 - i] for i in range(8)]
                second += [matrix[size - 15 + i][8] for i in range(8, 15)]
                self.assertEqual(first, second)
                format_bits = sum(int(bit) << i for i, bit in enumerate(first))
                self.assertIn(format_bits, {maa_tls._format_bits(0b01, mask) for mask in range(8)})
                self.assertTrue(matrix[size - 8][8])

    def test_cloudflared_template_and_rescue_html_constraints(self) -> None:
        """S2-3 & S2-4：隧道配置校验（含 cloudflared validate）与 `/rescue` 零外部依赖校验。"""
        fake_cert = self.daemon_dir / "tls" / "cert.pem"
        fake_cert.parent.mkdir(parents=True, exist_ok=True)
        fake_cert.write_text("dummy", encoding="utf-8")
        fake_creds = self.home / "creds.json"
        fake_creds.write_text("{}", encoding="utf-8")

        yml_path, plist_path = init_daemon.render_cloudflared_files(
            self.home,
            cert_path=fake_cert,
            api_port=18170,
            credentials_file=fake_creds,
        )
        yml_text = yml_path.read_text(encoding="utf-8")
        self.assertIn("protocol: http2", yml_text)
        self.assertIn("dcd1aac1-ff11-4a1f-b91c-9fb37b045716", yml_text)
        self.assertIn("https://127.0.0.1:18170", yml_text)
        self.assertIn(f"caPool: {fake_cert}", yml_text)
        self.assertIn("http_status:404", yml_text)

        plist_text = plist_path.read_text(encoding="utf-8")
        self.assertIn("io.github.ffkiyo7.wados-maa.cloudflared", plist_text)
        self.assertIn(str(yml_path), plist_text)
        self.assertIn("<key>KeepAlive</key>", plist_text)

        if shutil.which("cloudflared"):
            val = subprocess.run(
                ["cloudflared", "tunnel", "--config", str(yml_path), "ingress", "validate"],
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            self.assertEqual(val.returncode, 0, val.stderr or val.stdout)
            self.assertIn("OK", val.stdout + val.stderr)

        # S2-4: rescue.html 零外部资源依赖 + 严格 3 项应急能力 + 不把 token 放 URL
        html = (ROOT / "daemon" / "rescue.html").read_text(encoding="utf-8")
        self.assertNotRegex(html, r"https?://")
        for expected in (
            "/api/v1/snapshot",
            "/api/v1/run/cancel",
            "/api/v1/ios/resign",
            "Authorization",
            "Bearer ",
            "run_id",
            "window.confirm",
        ):
            self.assertIn(expected, html)
        self.assertIsNone(re.search(r"<script[^>]+src=", html, re.IGNORECASE))
        self.assertIsNone(re.search(r"<link[^>]+href=", html, re.IGNORECASE))

    def test_http11_unconsumed_body_closes_connection_and_rejects_transfer_encoding(self) -> None:
        """评审【1】回归：未消费请求体的 401/403/413/404 与带 body 的 GET/DELETE 必须断开，且拒绝 Transfer-Encoding。"""
        full_token = maa_tls.generate_token()
        resign_token = maa_tls.generate_token()
        secrets_path = self.daemon_dir / "secrets.json"
        maa_tls.merge_secrets(
            secrets_path,
            {
                "full_token_sha256": maa_tls.hash_token(full_token),
                "resign_only_token_sha256": maa_tls.hash_token(resign_token),
            },
        )
        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=secrets_path,
            rescue_html_path=ROOT / "daemon" / "rescue.html",
        )
        server = maa_api.create_server("127.0.0.1", 0, ctx)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=2.0)))

        def send_raw(raw_bytes: bytes) -> bytes:
            with socket.create_connection(("127.0.0.1", port), timeout=3.0) as sock:
                sock.settimeout(2.0)
                sock.sendall(raw_bytes)
                chunks: list[bytes] = []
                while True:
                    try:
                        chunk = sock.recv(4096)
                    except (ConnectionResetError, TimeoutError, socket.timeout):
                        break
                    if not chunk:
                        break
                    chunks.append(chunk)
                return b"".join(chunks)

        smuggled = b"GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n"

        # 1. 无 Token 的 POST 内嵌 GET /healthz：只应返回 401 + Connection: close，绝不返回第二条 200
        raw_401 = (
            f"POST /api/v1/run/cancel HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(smuggled)}\r\n\r\n".encode()
            + smuggled
        )
        resp_401 = send_raw(raw_401)
        self.assertIn(b"HTTP/1.1 401 ", resp_401)
        self.assertIn(b"Connection: close", resp_401)
        self.assertEqual(resp_401.count(b"HTTP/1.1 "), 1, f"发生 HTTP/1.1 请求走私：{resp_401!r}")

        # 2. resign_only 越权 403 带未消费 body：必须关连接
        raw_403 = (
            f"POST /api/v1/run/cancel HTTP/1.1\r\nHost: localhost\r\n"
            f"Authorization: Bearer {resign_token}\r\n"
            f"Content-Length: {len(smuggled)}\r\n\r\n".encode()
            + smuggled
        )
        resp_403 = send_raw(raw_403)
        self.assertIn(b"HTTP/1.1 403 ", resp_403)
        self.assertEqual(resp_403.count(b"HTTP/1.1 "), 1)

        # 3. 413 超限 body：不读体且关连接
        raw_413 = (
            f"POST /api/v1/plan/skip HTTP/1.1\r\nHost: localhost\r\n"
            f"Authorization: Bearer {full_token}\r\n"
            f"Content-Length: {maa_api.MAX_REQUEST_BODY_BYTES + 100}\r\n\r\n".encode()
            + smuggled
        )
        resp_413 = send_raw(raw_413)
        self.assertIn(b"HTTP/1.1 413 ", resp_413)
        self.assertEqual(resp_413.count(b"HTTP/1.1 "), 1)

        # 4. 404 带未消费 body（GET/DELETE 同样覆盖）
        raw_get_body = (
            f"GET /healthz HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(smuggled)}\r\n\r\n".encode()
            + smuggled
        )
        resp_get = send_raw(raw_get_body)
        self.assertIn(b"HTTP/1.1 200 ", resp_get)
        self.assertIn(b"Connection: close", resp_get)
        self.assertEqual(resp_get.count(b"HTTP/1.1 "), 1)

        raw_del_body = (
            f"DELETE /api/v1/unknown HTTP/1.1\r\nHost: localhost\r\n"
            f"Authorization: Bearer {full_token}\r\n"
            f"Content-Length: {len(smuggled)}\r\n\r\n".encode()
            + smuggled
        )
        resp_del = send_raw(raw_del_body)
        self.assertIn(b"HTTP/1.1 404 ", resp_del)
        self.assertEqual(resp_del.count(b"HTTP/1.1 "), 1)

        # 5. Transfer-Encoding: chunked 防走私与 cloudflared 兼容：
        #    - 未鉴权的 chunked POST 不会消费请求体，必须返回 401 + Connection: close，绝不执行内嵌请求
        raw_te_unauth = (
            b"POST /api/v1/plan/skip HTTP/1.1\r\nHost: localhost\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + smuggled
        )
        resp_te_unauth = send_raw(raw_te_unauth)
        self.assertIn(b"HTTP/1.1 401 ", resp_te_unauth)
        self.assertIn(b"Connection: close", resp_te_unauth)
        self.assertEqual(resp_te_unauth.count(b"HTTP/1.1 "), 1)

        #    - CL + TE 并存必须 400 拒绝并断连
        raw_cl_te = (
            b"POST /api/v1/notify/test HTTP/1.1\r\nHost: localhost\r\n"
            + f"Authorization: Bearer {full_token}\r\n".encode()
            + b"Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
            + smuggled
        )
        resp_cl_te = send_raw(raw_cl_te)
        self.assertIn(b"HTTP/1.1 400 ", resp_cl_te)
        self.assertIn(b"Connection: close", resp_cl_te)
        self.assertEqual(resp_cl_te.count(b"HTTP/1.1 "), 1)

        #    - 非纯 chunked（如 gzip, chunked）必须 400 拒绝并断连
        raw_te_bad = (
            b"POST /api/v1/notify/test HTTP/1.1\r\nHost: localhost\r\n"
            + f"Authorization: Bearer {full_token}\r\n".encode()
            + b"Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n"
            + smuggled
        )
        resp_te_bad = send_raw(raw_te_bad)
        self.assertIn(b"HTTP/1.1 400 ", resp_te_bad)
        self.assertIn(b"unsupported_transfer_encoding", resp_te_bad)
        self.assertIn(b"Connection: close", resp_te_bad)
        self.assertEqual(resp_te_bad.count(b"HTTP/1.1 "), 1)

        #    - 合法的空体 chunked POST（cloudflared 转发空体 POST 的真实形态）正常通过鉴权并进入端点
        raw_te_empty_ok = (
            b"POST /api/v1/ios/resign?if_due=1 HTTP/1.1\r\nHost: localhost\r\n"
            + f"Authorization: Bearer {resign_token}\r\n".encode()
            + b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n"
        )
        resp_te_empty_ok = send_raw(raw_te_empty_ok)
        self.assertIn(b"HTTP/1.1 501 ", resp_te_empty_ok)
        self.assertIn(b"not_configured", resp_te_empty_ok)

        #    - 合法的多分块 JSON chunked POST 正常解码执行
        part1 = b'{"if_due":'
        part2 = b" true}"
        raw_te_multi_ok = (
            b"POST /api/v1/ios/resign HTTP/1.1\r\nHost: localhost\r\n"
            + f"Authorization: Bearer {resign_token}\r\n".encode()
            + b"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            + f"{len(part1):x}\r\n".encode()
            + part1
            + b"\r\n"
            + f"{len(part2):x}\r\n".encode()
            + part2
            + b"\r\n0\r\n\r\n"
        )
        resp_te_multi_ok = send_raw(raw_te_multi_ok)
        self.assertIn(b"HTTP/1.1 501 ", resp_te_multi_ok)
        self.assertIn(b'"if_due": true', resp_te_multi_ok)

        #    - 超限 chunked POST 返回 413 并断连
        oversize = maa_api.MAX_REQUEST_BODY_BYTES + 1
        raw_te_413 = (
            b"POST /api/v1/ios/resign HTTP/1.1\r\nHost: localhost\r\n"
            + f"Authorization: Bearer {resign_token}\r\n".encode()
            + b"Transfer-Encoding: chunked\r\n\r\n"
            + f"{oversize:x}\r\n".encode()
            + smuggled
        )
        resp_te_413 = send_raw(raw_te_413)
        self.assertIn(b"HTTP/1.1 413 ", resp_te_413)
        self.assertIn(b"Connection: close", resp_te_413)
        self.assertEqual(resp_te_413.count(b"HTTP/1.1 "), 1)

    def test_rescue_cancel_feedback_is_not_overwritten_by_refresh(self) -> None:
        """评审【3】回归：rescue.html 停止回执（如 run_changed）不被随后的 refreshStatus 覆盖。"""
        html = (ROOT / "daemon" / "rescue.html").read_text(encoding="utf-8")
        self.assertIn("refreshStatus({ preserveFeedback: true })", html)
        match = re.search(r"<script>(.*)</script>", html, re.DOTALL)
        self.assertIsNotNone(match)
        assert match is not None
        script_src = match.group(1)

        # 若本机装有 node，直接执行页面脚本端到端验证 DOM 反馈状态。
        node = shutil.which("node")
        if node:
            harness = f"""
const elements = {{}};
function mkEl(id) {{
  const el = {{
    id, value: "", checked: false, disabled: false, textContent: "", className: "",
    listeners: {{}},
    addEventListener(ev, fn) {{ this.listeners[ev] = fn; }}
  }};
  elements[id] = el;
  return el;
}}
["tokenInput","rememberSession","authBadge","runBadge","lockHolder","runId",
 "progressText","lastRunText","updatedAt","feedback","refreshBtn","cancelBtn","resignBtn"].forEach(mkEl);
global.document = {{ getElementById: (id) => elements[id] }};
global.window = {{
  sessionStorage: {{ getItem: () => null, setItem() {{}}, removeItem() {{}} }},
  confirm: () => true,
}};
let step = 0;
global.fetch = async (path, opts) => {{
  if (path === "/api/v1/snapshot") {{
    step += 1;
    return {{
      status: 200, ok: true,
      json: async () => ({{
        lock: {{ holder: "daily", detail: "手动", run_id: step === 1 ? "run-old" : "run-new" }},
        last_run: {{ status: "running", phase: "now" }},
        progress: null,
        errors: {{}},
      }}),
    }};
  }}
  if (path === "/api/v1/run/cancel") {{
    return {{
      status: 200, ok: true,
      json: async () => ({{ ok: false, code: "run_changed", message: "当前运行的已经是另一场，没有停下。" }}),
    }};
  }}
  throw new Error("unexpected " + path);
}};
{script_src}
(async () => {{
  elements.tokenInput.value = "tok-full";
  await elements.refreshBtn.listeners.click();
  await elements.cancelBtn.listeners.click();
  console.log(JSON.stringify({{
    feedback: elements.feedback.textContent,
    cls: elements.feedback.className,
    runId: elements.runId.textContent,
  }}));
}})();
"""
            proc = subprocess.run([node, "-e", harness], capture_output=True, text=True, check=True, timeout=10)
            out = json.loads(proc.stdout.strip())
            self.assertEqual(out["feedback"], "当前运行的已经是另一场，没有停下。")
            self.assertIn("err", out["cls"])
            self.assertEqual(out["runId"], "run-new")

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_rotate_tls_skips_cloudflared_when_daemon_reload_fails(self) -> None:
        """复审【A】回归 1：daemon 重载失败时绝不调用 cloudflared_reloader，报错与回执写清未重载、不一致与恢复步骤。"""
        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=30)
        rotate_tls.stage_next_cert(self.home, lan_ip="192.168.50.2", days=1825)

        cf_calls: list[Path] = []

        def failing_daemon(_home: Path, _spki: str) -> dict[str, Any]:
            raise RuntimeError("daemon SIGHUP timeout")

        def spy_cloudflared(home: Path) -> dict[str, Any]:
            cf_calls.append(home)
            return {"status": "reloaded"}

        with self.assertRaises(rotate_tls.RotationReloadError) as caught:
            rotate_tls.activate_next_cert(
                self.home,
                daemon_reloader=failing_daemon,
                cloudflared_reloader=spy_cloudflared,
            )

        self.assertEqual(cf_calls, [], "daemon 重载失败后不应调用 cloudflared reloader")
        msg = str(caught.exception)
        self.assertIn("cloudflared 未重载", msg)
        self.assertIn("不一致", msg)
        self.assertIn("下一步", msg)
        rep = caught.exception.report
        self.assertFalse(rep["ok"])
        self.assertFalse(rep["disk_cert_matches_served"])
        self.assertEqual(rep["reload"]["daemon"]["status"], "failed")
        self.assertEqual(rep["reload"]["cloudflared"]["status"], "skipped")
        self.assertTrue(rep.get("backup_dir"))
        self.assertTrue(rep.get("recovery"))

    @unittest.skipUnless(_has_openssl3(), "需要 Homebrew OpenSSL 3")
    def test_daemon_sighup_reloads_tls_even_when_config_json_is_corrupted(self) -> None:
        """复审【A】回归 2：config.json 损坏导致调度重载失败时，真实 SIGHUP 仍完成 TLS 热重载并切换在服务证书。"""
        import signal

        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        old_info = maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=30)

        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]

        maa_common.atomic_write_json(
            self.daemon_dir / "daemon.json",
            {
                "schema_version": 1,
                "notify_backend": "none",
                "depot_enabled": False,
                "api_enabled": True,
                "api_host": "127.0.0.1",
                "api_port": port,
                "allowed_cidrs": ["127.0.0.1/32"],
            },
        )
        (self.state_dir / "config.json").write_text("{broken-json", encoding="utf-8")

        env = dict(os.environ)
        env["WADOS_MAA_HOME"] = str(self.home)
        proc = subprocess.Popen(
            [sys.executable, str(ROOT / "scripts" / "maa_daemon.py")],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

        def _cleanup_proc() -> None:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2.0)
            if proc.stdout:
                proc.stdout.close()
            if proc.stderr:
                proc.stderr.close()

        self.addCleanup(_cleanup_proc)

        active_path = self.daemon_dir / "active_tls.json"
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            if active_path.is_file():
                doc = json.loads(active_path.read_text(encoding="utf-8"))
                if doc.get("spki_sha256") == old_info["spki_sha256"]:
                    break
            time.sleep(0.1)
        self.assertTrue(active_path.is_file(), "daemon 未及时写出 active_tls.json")

        staged = rotate_tls.stage_next_cert(self.home, lan_ip="192.168.50.2", days=1825)
        os.replace(self.daemon_dir / "tls" / "cert.next.pem", cert_path)
        os.replace(self.daemon_dir / "tls" / "key.next.pem", key_path)
        proc.send_signal(signal.SIGHUP)

        switched = False
        deadline = time.monotonic() + 8.0
        while time.monotonic() < deadline:
            doc = json.loads(active_path.read_text(encoding="utf-8"))
            if doc.get("spki_sha256") == staged["spki_sha256"]:
                switched = True
                break
            time.sleep(0.1)
        self.assertTrue(switched, "config.json 损坏时 SIGHUP 未完成 TLS 热重载")

        cctx = ssl._create_unverified_context()
        with socket.create_connection(("127.0.0.1", port), timeout=3.0) as raw:
            with cctx.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                peer_der = tls.getpeercert(binary_form=True)
        expected_der = ssl.PEM_cert_to_DER_cert(cert_path.read_text(encoding="utf-8"))
        self.assertEqual(peer_der, expected_der)

    @unittest.skipUnless(_has_openssl3(), "生成测试用夹具证书需要 Homebrew OpenSSL 3")
    def test_api_starts_reloads_and_verifies_without_openssl3_and_expiry_degrades_safely(self) -> None:
        """复审【B】回归：无 OpenSSL 3 时 API 与 /rescue 照常启动、reload_tls 照常切换、到期巡检安全降级不崩不误报、rotate_tls 不误报确认。"""
        from unittest.mock import patch

        cert_path = self.daemon_dir / "tls" / "cert.pem"
        key_path = self.daemon_dir / "tls" / "key.pem"
        cert2_path = self.daemon_dir / "tls" / "cert2.pem"
        key2_path = self.daemon_dir / "tls" / "key2.pem"
        # 先准备两套合法测试证书，随后彻底屏蔽 find_openssl3 模拟无 OpenSSL 3 环境。
        maa_tls.generate_self_signed_cert(cert_path, key_path, lan_ip="192.168.50.2", days=20)
        maa_tls.generate_self_signed_cert(cert2_path, key2_path, lan_ip="192.168.50.2", days=1825)
        expected_sha1 = maa_tls.compute_cert_sha256(cert_path)
        expected_sha2 = maa_tls.compute_cert_sha256(cert2_path)
        self.assertNotEqual(expected_sha1, expected_sha2)

        ctx = maa_api.APIContext(
            home_dir=self.home,
            scripts_dir=ROOT / "scripts",
            state_dir=self.state_dir,
            runs_dir=self.runs_dir,
            daemon_dir=self.daemon_dir,
            secrets_path=self.daemon_dir / "secrets.json",
            rescue_html_path=ROOT / "daemon" / "rescue.html",
        )

        with patch.object(maa_tls, "find_openssl3", side_effect=RuntimeError("openssl@3 missing")):
            # 1. 无 OpenSSL 3 时服务器照常启动，/healthz 与 /rescue 均可访问
            server = maa_api.create_server("127.0.0.1", 0, ctx, cert_path=cert_path, key_path=key_path)
            port = server.server_address[1]
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
            thread.start()
            self.addCleanup(lambda: (server.shutdown(), server.server_close(), thread.join(timeout=2.0)))

            st, health = _tls_request(port, "GET", "/healthz")
            self.assertEqual(st, 200)
            self.assertTrue(health["ok"])

            cctx = ssl._create_unverified_context()
            conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=3.0, context=cctx)
            try:
                conn.request("GET", "/rescue")
                r = conn.getresponse()
                self.assertEqual(r.status, 200)
                self.assertIn(b"Wado's MAA", r.read())
            finally:
                conn.close()

            # Bark 推送头像免鉴权：没配 icon_path 时 404，配了返回 PNG
            st, missing = _tls_request(port, "GET", "/icon.png")
            self.assertEqual(st, 404)
            self.assertEqual(missing["code"], "not_found")
            ctx.icon_path = ROOT / "daemon" / "icon.png"
            conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=3.0, context=cctx)
            try:
                conn.request("GET", "/icon.png")
                r = conn.getresponse()
                self.assertEqual(r.status, 200)
                self.assertEqual(r.getheader("Content-Type"), "image/png")
                self.assertEqual(r.read(), (ROOT / "daemon" / "icon.png").read_bytes())
            finally:
                conn.close()

            info1 = server.get_active_cert_info()
            assert info1 is not None
            self.assertFalse(info1["meta_ok"])
            self.assertEqual(info1["spki_sha256"], "")
            self.assertEqual(info1["cert_sha256"], expected_sha1)

            # 2. 到期巡检在 served_info.meta_ok=False 时安全降级，不崩溃也不误报告警
            sent: list[str] = []
            chk = maa_tls.check_cert_expiry_and_notify(
                cert_path,
                self.daemon_dir / "tls_check.json",
                warn_days=60,
                served_info=info1,
                notify_fn=lambda title, _body, **_kw: (sent.append(title) or True),
            )
            self.assertTrue(chk["degraded"])
            self.assertFalse(chk["notified"])
            self.assertEqual(sent, [])

            # 3. 无 OpenSSL 3 时 reload_tls 仍可成功切换新证书并更新 cert_sha256
            os.replace(cert2_path, cert_path)
            os.replace(key2_path, key_path)
            meta2 = server.reload_tls()
            self.assertFalse(meta2["meta_ok"])
            self.assertEqual(meta2["cert_sha256"], expected_sha2)

            with socket.create_connection(("127.0.0.1", port), timeout=3.0) as raw:
                with cctx.wrap_socket(raw, server_hostname="127.0.0.1") as tls:
                    peer_der = tls.getpeercert(binary_form=True)
            self.assertEqual(peer_der, ssl.PEM_cert_to_DER_cert(cert_path.read_text(encoding="utf-8")))

            # 4. rotate_tls.reload_running_daemon：无 OpenSSL 3 时凭纯 Python cert_sha256 精确核验；
            #    若 active_tls.json 指纹不匹配（仍是旧证书），绝不误报成功，超时明确报错。
            pid = os.getpid()
            (self.daemon_dir / "daemon.pid").write_text(f"{pid}\n", encoding="utf-8")
            with patch.object(rotate_tls, "_is_daemon_pid", return_value=True), \
                    patch.object(rotate_tls.os, "kill"):
                maa_common.atomic_write_json(
                    self.daemon_dir / "active_tls.json",
                    {"pid": pid, "spki_sha256": "", "cert_sha256": expected_sha1},
                )
                with self.assertRaises(RuntimeError):
                    rotate_tls.reload_running_daemon(self.home, "", wait_seconds=0.3)

                maa_common.atomic_write_json(
                    self.daemon_dir / "active_tls.json",
                    {"pid": pid, "spki_sha256": "", "cert_sha256": expected_sha2},
                )
                ok_res = rotate_tls.reload_running_daemon(self.home, "", wait_seconds=0.5)
                self.assertTrue(ok_res["reloaded"])
                self.assertEqual(ok_res["verified_via"], "cert_sha256")
                self.assertEqual(ok_res["cert_sha256"], expected_sha2)


if __name__ == "__main__":
    unittest.main()
