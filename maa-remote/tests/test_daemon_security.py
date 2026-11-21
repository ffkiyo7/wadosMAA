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

        # 验证两步平滑轮换（stage → activate）产生新 SPKI 并备份旧证书
        staged = rotate_tls.stage_next_cert(self.home, lan_ip="192.168.50.2", days=1825)
        self.assertNotEqual(staged["spki_sha256"], spki)
        activated = rotate_tls.activate_next_cert(self.home)
        self.assertEqual(activated["spki_sha256"], staged["spki_sha256"])
        self.assertTrue(Path(activated["backup_dir"]).is_dir())
        self.assertEqual(maa_tls.compute_spki_sha256(cert_path), staged["spki_sha256"])

        # 新 5 年证书不在 60 天告警窗内
        r3 = maa_tls.check_cert_expiry_and_notify(
            cert_path, check_path, now=day1 + timedelta(days=1), warn_days=60, notify_fn=fake_notify
        )
        self.assertFalse(r3["warn_due"])
        self.assertFalse(r3["notified"])

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

        # 5. 拒绝 Transfer-Encoding: chunked 且立即断连
        raw_te = (
            b"POST /api/v1/plan/skip HTTP/1.1\r\nHost: localhost\r\n"
            b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + smuggled
        )
        resp_te = send_raw(raw_te)
        self.assertIn(b"HTTP/1.1 400 ", resp_te)
        self.assertIn(b"unsupported_transfer_encoding", resp_te)
        self.assertEqual(resp_te.count(b"HTTP/1.1 "), 1)


if __name__ == "__main__":
    unittest.main()
