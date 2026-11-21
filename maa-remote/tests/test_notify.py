"""`barkcrypt.swift` + `maa_notify.py` 通知出口离线单测（S1-2，不变量 #63）。"""

from __future__ import annotations

import base64
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_notify  # noqa: E402

_DEVICE_GUARDS: list = []
_MODULE_PATCHES: list = []
_COMPILED_DIR: tempfile.TemporaryDirectory[str] | None = None
_BARKCRYPT_BIN: Path | None = None


def setUpModule() -> None:
    global _COMPILED_DIR, _BARKCRYPT_BIN
    _DEVICE_GUARDS[:] = _isolation.guard_devices()
    _MODULE_PATCHES[:] = _helpers.start_module_patches()
    if shutil.which("swiftc"):
        _COMPILED_DIR = tempfile.TemporaryDirectory(prefix="barkcrypt-test-")
        out = Path(_COMPILED_DIR.name) / "barkcrypt"
        proc = subprocess.run(
            ["swiftc", "-O", "-warnings-as-errors", str(ROOT / "scripts" / "barkcrypt.swift"), "-o", str(out)],
            capture_output=True,
            text=True,
            check=False,
            timeout=180,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"barkcrypt.swift 编译失败：\n{proc.stderr}\n{proc.stdout}")
        _BARKCRYPT_BIN = out


def tearDownModule() -> None:
    global _COMPILED_DIR, _BARKCRYPT_BIN
    if _COMPILED_DIR is not None:
        _COMPILED_DIR.cleanup()
        _COMPILED_DIR = None
        _BARKCRYPT_BIN = None
    _helpers.stop_patches(_MODULE_PATCHES)
    for item in reversed(_DEVICE_GUARDS):
        item.stop()
    _isolation.assert_shared_home_clean()


class BarkCryptBinaryTests(unittest.TestCase):
    def setUp(self) -> None:
        if _BARKCRYPT_BIN is None:
            self.skipTest("当前环境无 swiftc")

    def _run_helper(self, payload: dict) -> subprocess.CompletedProcess[str]:
        assert _BARKCRYPT_BIN is not None
        return subprocess.run(
            [str(_BARKCRYPT_BIN)],
            input=json.dumps(payload, ensure_ascii=False),
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    def test_aes_256_gcm_roundtrip_and_no_nonce_prefix(self) -> None:
        assert _BARKCRYPT_BIN is not None
        key = "0123456789abcdef0123456789abcdef"  # 32 ASCII bytes
        iv = "AbCdEf123456"  # 12 ASCII bytes
        inner = json.dumps(
            {"title": "早场完成", "body": "TL-9 刷完 5 把", "level": "active", "group": "wados-maa"},
            ensure_ascii=False,
            separators=(",", ":"),
        )
        ct_b64 = maa_notify.encrypt_payload(inner, key, iv, helper_bin=_BARKCRYPT_BIN)
        raw = base64.b64decode(ct_b64)
        # 严格校验输出为 ciphertext + 16B tag，绝不含 12B 前导 nonce（禁止 .combined）。
        self.assertEqual(len(raw), len(inner.encode("utf-8")) + 16)

        dec = self._run_helper({"action": "decrypt", "ciphertext": ct_b64, "key": key, "iv": iv})
        self.assertEqual(dec.returncode, 0, dec.stderr)
        self.assertEqual(json.loads(dec.stdout)["plaintext"], inner)

    def test_aes_128_gcm_roundtrip_and_wrong_iv_fails(self) -> None:
        assert _BARKCRYPT_BIN is not None
        key = "1234567890abcdef"  # 16 ASCII bytes
        iv = "123456789012"
        plaintext = '{"title":"测试"}'
        ct_b64 = maa_notify.encrypt_payload(plaintext, key, iv, helper_bin=_BARKCRYPT_BIN)
        dec_ok = self._run_helper({"action": "decrypt", "ciphertext": ct_b64, "key": key, "iv": iv})
        self.assertEqual(dec_ok.returncode, 0, dec_ok.stderr)
        self.assertEqual(json.loads(dec_ok.stdout)["plaintext"], plaintext)

        dec_bad = self._run_helper({"action": "decrypt", "ciphertext": ct_b64, "key": key, "iv": "000000000000"})
        self.assertNotEqual(dec_bad.returncode, 0)

    def test_rejects_invalid_key_or_iv_length(self) -> None:
        assert _BARKCRYPT_BIN is not None
        with self.assertRaises(ValueError):
            maa_notify.encrypt_payload("hi", "short", "123456789012", helper_bin=_BARKCRYPT_BIN)
        with self.assertRaises(ValueError):
            maa_notify.encrypt_payload("hi", "0" * 32, "short", helper_bin=_BARKCRYPT_BIN)


class MaaNotifyTests(unittest.TestCase):
    def test_envelope_keeps_sensitive_fields_encrypted_and_id_in_outer_layer(self) -> None:
        if _BARKCRYPT_BIN is None:
            self.skipTest("当前环境无 swiftc")
        key = "a" * 32
        iv = "iv1234567890"
        outer = maa_notify.build_bark_envelope(
            device_key="dev_key_1",
            aes_key=key,
            title="早场开跑 · TL-9",
            body="预计 10 分钟",
            subtitle="日常",
            level="passive",
            icon="https://example.invalid/icon.png",
            url="wadosmaa://run/2026-11-21-am-080000",
            notification_id="run-2026-11-21-am-080000",
            iv=iv,
            helper_bin=_BARKCRYPT_BIN,
        )
        # 外层明文只含 device_key / ciphertext / iv / id，不包含 title/body/url 等敏感内容。
        self.assertEqual(set(outer), {"device_key", "ciphertext", "iv", "id"})
        self.assertEqual(outer["device_key"], "dev_key_1")
        self.assertEqual(outer["iv"], iv)
        self.assertEqual(outer["id"], "run-2026-11-21-am-080000")

        proc = subprocess.run(
            [str(_BARKCRYPT_BIN)],
            input=json.dumps({"action": "decrypt", "ciphertext": outer["ciphertext"], "key": key, "iv": iv}),
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        )
        inner = json.loads(json.loads(proc.stdout)["plaintext"])
        self.assertEqual(inner["title"], "早场开跑 · TL-9")
        self.assertEqual(inner["body"], "预计 10 分钟")
        self.assertEqual(inner["subtitle"], "日常")
        self.assertEqual(inner["level"], "passive")
        self.assertEqual(inner["group"], "wados-maa")
        self.assertEqual(inner["icon"], "https://example.invalid/icon.png")
        self.assertEqual(inner["url"], "wadosmaa://run/2026-11-21-am-080000")

    def test_missing_config_or_backend_none_degrades_silently(self) -> None:
        with patch.object(maa_notify, "_post_json") as post:
            self.assertFalse(maa_notify.notify("t", "b", config={"notify_backend": "none"}, secret_map={}))
            self.assertFalse(maa_notify.notify("t", "b", config={"notify_backend": "bark"}, secret_map={}))
            post.assert_not_called()

    def test_notify_never_raises_on_encryption_or_network_failure(self) -> None:
        cfg = {"notify_backend": "bark", "bark_base_url": "https://api.day.app"}
        sec = {"bark_device_key": "dev", "bark_aes_key": "0" * 32}
        with patch.object(maa_notify, "encrypt_payload", side_effect=RuntimeError("helper crashed")):
            self.assertFalse(maa_notify.notify("t", "b", config=cfg, secret_map=sec))
        with patch.object(maa_notify, "encrypt_payload", return_value="Y2lwaGVy"), \
                patch.object(maa_notify, "_post_json", side_effect=RuntimeError("network down")):
            self.assertFalse(maa_notify.notify("t", "b", config=cfg, secret_map=sec))

    def test_send_test_posts_to_configured_base_url_and_returns_receipt(self) -> None:
        cfg = {"notify_backend": "bark", "bark_base_url": "https://bark.example.test/", "bark_icon_url": ""}
        sec = {"bark_device_key": "dev", "bark_aes_key": "0" * 32}
        captured: list[tuple[str, dict]] = []

        def fake_post(url: str, payload: dict) -> dict:
            captured.append((url, dict(payload)))
            return {"code": 200, "message": "success"}

        with patch.object(maa_notify, "encrypt_payload", return_value="Y2lwaGVy"), \
                patch.object(maa_notify, "_post_json", side_effect=fake_post):
            ok, msg, data = maa_notify.send_test(config=cfg, secret_map=sec)
        self.assertTrue(ok, msg)
        self.assertEqual(data["backend"], "bark")
        self.assertEqual(captured[0][0], "https://bark.example.test/push")
        self.assertEqual(captured[0][1]["id"], "wados-maa-test")


if __name__ == "__main__":
    unittest.main()
