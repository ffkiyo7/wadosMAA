#!/usr/bin/env python3
"""统一通知出口（Bark + `barkcrypt` AES-GCM 端到端加密，遵守不变量 #63）。

职责：
1. 读取 `daemon/daemon.json`（`notify_backend` / `bark_base_url` / `bark_icon_url`）
   与 `daemon/secrets.json`（`bark_device_key` / `bark_aes_key`）；
2. 通过 `scripts/barkcrypt`（Swift CryptoKit）用 AES-GCM 加密内层推送内容
   （所有敏感参数经 stdin JSON 传递，绝不经 argv 暴露）；
3. 严格遵守不变量 #63：任何配置缺失、加密失败、网络/HTTP 错误均记录日志、永不抛给业务主流程。
"""

from __future__ import annotations

import json
import secrets
import string
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Literal, Mapping

from maa_common import DAEMON_DIR, SCRIPTS_DIR, load_json

DAEMON_CONFIG_PATH = DAEMON_DIR / "daemon.json"
SECRETS_PATH = DAEMON_DIR / "secrets.json"
BARKCRYPT_BIN = SCRIPTS_DIR / "barkcrypt"

DEFAULT_BARK_BASE_URL = "https://api.day.app"
DEFAULT_GROUP = "wados-maa"
VALID_LEVELS = frozenset({"passive", "active", "timeSensitive"})
_IV_ALPHABET = string.ascii_letters + string.digits
_REQUEST_TIMEOUT = 15
_MAX_RESPONSE_BYTES = 64 * 1024

NotifyLevel = Literal["passive", "active", "timeSensitive"]


def generate_iv() -> str:
    """生成 12 字节随机 ASCII IV（UTF-8 原始 12 字节）。"""
    return "".join(secrets.choice(_IV_ALPHABET) for _ in range(12))


def load_notify_config() -> dict[str, Any]:
    raw = load_json(DAEMON_CONFIG_PATH, {})
    return raw if isinstance(raw, dict) else {}


def load_notify_secrets() -> dict[str, Any]:
    raw = load_json(SECRETS_PATH, {})
    return raw if isinstance(raw, dict) else {}


def is_configured(
    *,
    config: Mapping[str, Any] | None = None,
    secret_map: Mapping[str, Any] | None = None,
) -> bool:
    """判断通知出口是否已配置完整（仅返回布尔值，绝不返回任何密钥）。"""
    cfg = load_notify_config() if config is None else config
    backend = str(cfg.get("notify_backend") or "none").strip().lower()
    if backend != "bark":
        return False
    sec = load_notify_secrets() if secret_map is None else secret_map
    device_key = str(sec.get("bark_device_key") or "").strip()
    aes_key = str(sec.get("bark_aes_key") or "").strip()
    if not device_key or not aes_key:
        return False
    return len(aes_key.encode("utf-8")) in (16, 32)


def encrypt_payload(
    plaintext: str,
    key: str,
    iv: str,
    *,
    helper_bin: Path | None = None,
) -> str:
    """调用 `barkcrypt` 加密，返回 `Base64(ciphertext + tag)`。敏感入参仅走 stdin JSON。"""
    binary = helper_bin or BARKCRYPT_BIN
    if not binary.is_file():
        raise FileNotFoundError(f"找不到加密工具：{binary}")
    key_bytes = key.encode("utf-8")
    if len(key_bytes) not in (16, 32):
        raise ValueError(f"bark_aes_key 长度必须是 16 或 32 字节，当前 {len(key_bytes)}")
    iv_bytes = iv.encode("utf-8")
    if len(iv_bytes) != 12:
        raise ValueError(f"iv 长度必须是 12 字节，当前 {len(iv_bytes)}")
    req = json.dumps(
        {"action": "encrypt", "plaintext": plaintext, "key": key, "iv": iv},
        ensure_ascii=False,
    )
    proc = subprocess.run(
        [str(binary)],
        input=req,
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[:300]
        raise RuntimeError(f"barkcrypt 失败（退出码 {proc.returncode}）：{detail}")
    parsed = json.loads(proc.stdout)
    ciphertext = parsed.get("ciphertext") if isinstance(parsed, dict) else None
    if not isinstance(ciphertext, str) or not ciphertext:
        raise RuntimeError("barkcrypt 未返回 ciphertext")
    return ciphertext


def build_bark_envelope(
    *,
    device_key: str,
    aes_key: str,
    title: str,
    body: str,
    subtitle: str = "",
    level: str = "active",
    group: str = DEFAULT_GROUP,
    icon: str = "",
    url: str = "",
    notification_id: str = "",
    iv: str | None = None,
    helper_bin: Path | None = None,
) -> dict[str, str]:
    """组装 Bark 加密请求体：外层仅放 device_key/ciphertext/iv/id，其余全部进密文。"""
    clean_level = level if level in VALID_LEVELS else "active"
    inner: dict[str, str] = {
        "title": title,
        "body": body,
        "level": clean_level,
        "group": group or DEFAULT_GROUP,
    }
    if subtitle:
        inner["subtitle"] = subtitle
    if icon:
        inner["icon"] = icon
    if url:
        inner["url"] = url
    actual_iv = iv if iv is not None else generate_iv()
    plaintext = json.dumps(inner, ensure_ascii=False, separators=(",", ":"))
    ciphertext = encrypt_payload(plaintext, aes_key, actual_iv, helper_bin=helper_bin)
    outer: dict[str, str] = {
        "device_key": device_key,
        "ciphertext": ciphertext,
        "iv": actual_iv,
    }
    if notification_id:
        outer["id"] = notification_id
    return outer


def _post_json(url: str, payload: Mapping[str, Any], *, timeout: int = _REQUEST_TIMEOUT) -> dict[str, Any]:
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": "Wados-MAA/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(_MAX_RESPONSE_BYTES + 1)
            if len(raw) > _MAX_RESPONSE_BYTES:
                raise RuntimeError("Bark 响应超过大小上限")
            parsed = json.loads(raw.decode("utf-8"))
            if not isinstance(parsed, dict):
                raise RuntimeError("Bark 响应不是 JSON object")
            code = parsed.get("code")
            if code is not None and code != 200:
                raise RuntimeError(f"Bark 返回异常 code={code}: {parsed.get('message', '')}")
            return parsed
    except urllib.error.HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")[:300]
        raise RuntimeError(f"Bark HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Bark 网络错误: {exc.reason}") from exc


def _send_bark_strict(
    *,
    title: str,
    body: str,
    subtitle: str = "",
    level: str = "active",
    group: str = DEFAULT_GROUP,
    url: str = "",
    notification_id: str = "",
    config: Mapping[str, Any] | None = None,
    secret_map: Mapping[str, Any] | None = None,
    helper_bin: Path | None = None,
) -> tuple[bool, str, dict[str, Any]]:
    """带明确状态与错误信息的内部发送函数，供 `notify()` 与 `send_test()` 共用。"""
    cfg = dict(load_notify_config() if config is None else config)
    backend = str(cfg.get("notify_backend") or "none").strip().lower()
    if backend == "none":
        return False, "notify_backend=none，未启用推送", {"skipped": True, "backend": "none"}
    if backend != "bark":
        return False, f"不支持的通知后端：{backend}", {"skipped": True, "backend": backend}

    sec = dict(load_notify_secrets() if secret_map is None else secret_map)
    device_key = str(sec.get("bark_device_key") or "").strip()
    aes_key = str(sec.get("bark_aes_key") or "").strip()
    if not device_key or not aes_key:
        return False, "缺少 bark_device_key 或 bark_aes_key，已跳过推送", {"skipped": True, "backend": "bark"}

    base_url = str(cfg.get("bark_base_url") or DEFAULT_BARK_BASE_URL).strip().rstrip("/")
    icon_url = str(cfg.get("bark_icon_url") or "").strip()
    envelope = build_bark_envelope(
        device_key=device_key,
        aes_key=aes_key,
        title=title,
        body=body,
        subtitle=subtitle,
        level=level,
        group=group,
        icon=icon_url,
        url=url,
        notification_id=notification_id,
        helper_bin=helper_bin,
    )
    resp = _post_json(f"{base_url}/push", envelope)
    return True, "推送已发送", {"backend": "bark", "id": notification_id, "response": resp}


def notify(
    title: str,
    body: str,
    *,
    subtitle: str = "",
    level: str = "active",
    group: str = DEFAULT_GROUP,
    url: str = "",
    notification_id: str = "",
    config: Mapping[str, Any] | None = None,
    secret_map: Mapping[str, Any] | None = None,
    helper_bin: Path | None = None,
) -> bool:
    """统一业务通知出口：永远捕获异常写日志、返回是否成功发送，绝不抛给业务主流程（#63）。"""
    try:
        ok, reason, info = _send_bark_strict(
            title=title,
            body=body,
            subtitle=subtitle,
            level=level,
            group=group,
            url=url,
            notification_id=notification_id,
            config=config,
            secret_map=secret_map,
            helper_bin=helper_bin,
        )
        if not ok and not info.get("skipped"):
            print(f"通知发送失败：{reason}", file=sys.stderr, flush=True)
        return ok
    except Exception as exc:  # noqa: BLE001 — (c) 通知出口异常永不阻断业务主流程（#63）
        print(f"通知发送失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return False


def send_test(
    *,
    config: Mapping[str, Any] | None = None,
    secret_map: Mapping[str, Any] | None = None,
    helper_bin: Path | None = None,
) -> tuple[bool, str, dict[str, Any]]:
    """给 `POST /api/v1/notify/test` 复用的测试推送入口，永不抛异常。"""
    try:
        return _send_bark_strict(
            title="Wado's MAA 测试推送",
            body="端到端加密通道工作正常，点此可打开 App。",
            level="active",
            url="wadosmaa://today",
            notification_id="wados-maa-test",
            config=config,
            secret_map=secret_map,
            helper_bin=helper_bin,
        )
    except Exception as exc:  # noqa: BLE001 — (a) 测试接口将异常转为结构化回执返回
        return False, f"测试推送失败：{type(exc).__name__}: {exc}", {"backend": "bark", "error": str(exc)}
