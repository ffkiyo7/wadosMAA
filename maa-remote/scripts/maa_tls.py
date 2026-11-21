#!/usr/bin/env python3
"""本地自签 TLS 证书（OpenSSL 3 ECDSA P-256 named_curve）、Token 哈希、证书到期巡检与终端 QR 编码器。

纯 Python 标准库（零第三方依赖），供 `maa_daemon.py`、`maa_api.py` 与 `daemon/init_daemon.py` /
`daemon/rotate_tls.py` 共用。

关键约束（来自 P0 S0-3 实证）：
- 必须使用 OpenSSL 3 显式加 `-pkeyopt ec_param_enc:named_curve` 生成 ECDSA P-256 证书，
  macOS 系统 LibreSSL 默认 explicit EC parameters 会被 Apple `SecCertificateCopyKey` 拒认。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import ipaddress
import os
import secrets
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping

from maa_common import (
    BEIJING,
    DAEMON_DIR,
    atomic_write_json,
    atomic_write_text,
    ensure_private_dir,
    load_json,
    now_beijing,
)

OPENSSL3_CANDIDATES = (
    "/opt/homebrew/opt/openssl@3/bin/openssl",
    "/usr/local/opt/openssl@3/bin/openssl",
)
DEFAULT_TLS_DIR = DAEMON_DIR / "tls"
DEFAULT_CERT_PATH = DEFAULT_TLS_DIR / "cert.pem"
DEFAULT_KEY_PATH = DEFAULT_TLS_DIR / "key.pem"
DEFAULT_TLS_CHECK_PATH = DAEMON_DIR / "tls_check.json"
DEFAULT_CERT_DAYS = 365 * 5
DEFAULT_WARN_DAYS = 60


def find_openssl3(explicit: str | None = None) -> str:
    """定位 Homebrew OpenSSL 3 可执行文件；拒绝系统 LibreSSL（S0-3 实证）。"""
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    env_override = os.environ.get("WADOS_OPENSSL_BIN", "").strip()
    if env_override:
        candidates.append(env_override)
    candidates.extend(OPENSSL3_CANDIDATES)
    from_path = shutil.which("openssl")
    if from_path and from_path not in candidates:
        candidates.append(from_path)

    saw_libressl = False
    for path in candidates:
        if not path or not os.path.isfile(path) or not os.access(path, os.X_OK):
            continue
        try:
            proc = subprocess.run(
                [path, "version"],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        version_text = (proc.stdout or proc.stderr or "").strip()
        if version_text.startswith("OpenSSL 3."):
            return path
        if "LibreSSL" in version_text:
            saw_libressl = True

    if saw_libressl:
        raise RuntimeError(
            "检测到系统 LibreSSL，未找到 Homebrew OpenSSL 3（/opt/homebrew/opt/openssl@3/bin/openssl）。"
            "LibreSSL 生成的 EC 证书会被 Apple SecCertificateCopyKey 拒认，请安装 openssl@3。"
        )
    raise RuntimeError("未找到 OpenSSL 3（预期路径：/opt/homebrew/opt/openssl@3/bin/openssl）。")


def _validate_ip_list(ips: list[str]) -> list[str]:
    clean: list[str] = []
    for raw in ips:
        text = raw.strip()
        if not text:
            continue
        parsed = str(ipaddress.ip_address(text))
        if parsed not in clean:
            clean.append(parsed)
    if not clean:
        raise ValueError("SAN IP 列表不能为空")
    return clean


def compute_spki_sha256(cert_path: Path, *, openssl_bin: str | None = None) -> str:
    """计算 X.509 证书公钥（SubjectPublicKeyInfo DER）的 SHA-256 Base64 指纹。"""
    if not cert_path.is_file():
        raise FileNotFoundError(f"证书文件不存在：{cert_path}")
    openssl = openssl_bin or find_openssl3()
    proc = subprocess.run(
        [openssl, "x509", "-in", str(cert_path), "-pubkey", "-noout"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[:300]
        raise RuntimeError(f"提取证书公钥失败：{detail}")
    b64_lines = [
        line.strip()
        for line in proc.stdout.splitlines()
        if line.strip() and not line.strip().startswith("-----")
    ]
    if not b64_lines:
        raise RuntimeError("证书公钥输出为空")
    spki_der = base64.b64decode("".join(b64_lines))
    return base64.b64encode(hashlib.sha256(spki_der).digest()).decode("ascii")


def parse_openssl_not_after(output: str) -> datetime:
    """解析 `openssl x509 -enddate -noout` 输出为 UTC datetime。"""
    text = output.strip()
    for line in text.splitlines():
        if line.lower().startswith("notafter="):
            raw_date = line.split("=", 1)[1].strip()
            # OpenSSL 格式示例：Nov 21 11:55:00 2031 GMT（日期可能是单位数带双空格）
            normalized = " ".join(raw_date.split())
            dt = datetime.strptime(normalized, "%b %d %H:%M:%S %Y GMT")
            return dt.replace(tzinfo=timezone.utc)
    raise ValueError(f"无法解析证书到期时间：{text[:120]!r}")


def cert_expiry_info(
    cert_path: Path,
    *,
    now: datetime | None = None,
    warn_days: int = DEFAULT_WARN_DAYS,
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    """读取证书到期时间、剩余天数与是否进入告警窗口。"""
    if not cert_path.is_file():
        raise FileNotFoundError(f"证书文件不存在：{cert_path}")
    openssl = openssl_bin or find_openssl3()
    proc = subprocess.run(
        [openssl, "x509", "-in", str(cert_path), "-enddate", "-noout"],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()[:300]
        raise RuntimeError(f"读取证书到期时间失败：{detail}")
    not_after_utc = parse_openssl_not_after(proc.stdout)
    moment = (now or now_beijing()).astimezone(timezone.utc)
    remaining_seconds = (not_after_utc - moment).total_seconds()
    days_remaining = round(remaining_seconds / 86400.0, 2)
    return {
        "cert_path": str(cert_path),
        "not_after": not_after_utc.astimezone(BEIJING).isoformat(),
        "not_after_utc": not_after_utc.isoformat(),
        "days_remaining": days_remaining,
        "expired": remaining_seconds <= 0,
        "warn_due": days_remaining <= float(warn_days),
    }


def generate_self_signed_cert(
    cert_path: Path,
    key_path: Path,
    *,
    lan_ip: str = "192.168.50.2",
    extra_ips: list[str] | None = None,
    days: int = DEFAULT_CERT_DAYS,
    common_name: str = "Wado's MAA Local TLS",
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    """生成 5 年期 ECDSA P-256（named_curve）自签证书，SAN 含局域网 IP 与 127.0.0.1。"""
    if days < 1 or days > 3650:
        raise ValueError(f"证书有效期天数须在 1~3650 之间，收到 {days}")
    openssl = openssl_bin or find_openssl3()
    ips = _validate_ip_list([lan_ip, "127.0.0.1", *(extra_ips or [])])
    san = ",".join(f"IP:{ip}" for ip in ips)

    ensure_private_dir(cert_path.parent)
    ensure_private_dir(key_path.parent)
    with tempfile.TemporaryDirectory(prefix="wados-tls-") as tmp:
        tmp_dir = Path(tmp)
        tmp_cert = tmp_dir / "cert.pem"
        tmp_key = tmp_dir / "key.pem"
        argv = [
            openssl,
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
            "-pkeyopt",
            "ec_param_enc:named_curve",
            "-nodes",
            "-sha256",
            "-days",
            str(days),
            "-subj",
            f"/CN={common_name}",
            "-addext",
            f"subjectAltName={san}",
            "-addext",
            "basicConstraints=critical,CA:FALSE",
            "-addext",
            "keyUsage=critical,digitalSignature",
            "-addext",
            "extendedKeyUsage=serverAuth",
            "-keyout",
            str(tmp_key),
            "-out",
            str(tmp_cert),
        ]
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()[:400]
            raise RuntimeError(f"生成自签证书失败（退出码 {proc.returncode}）：{detail}")
        cert_bytes = tmp_cert.read_bytes()
        key_bytes = tmp_key.read_bytes()

    atomic_write_text(cert_path, cert_bytes.decode("utf-8"), mode=0o600)
    atomic_write_text(key_path, key_bytes.decode("utf-8"), mode=0o600)
    spki = compute_spki_sha256(cert_path, openssl_bin=openssl)
    expiry = cert_expiry_info(cert_path, openssl_bin=openssl)
    return {
        "cert_path": str(cert_path),
        "key_path": str(key_path),
        "san_ips": ips,
        "spki_sha256": spki,
        "not_after": expiry["not_after"],
        "days_remaining": expiry["days_remaining"],
    }


def _expiry_from_not_after_utc(
    cert_path: Path,
    not_after_utc: datetime,
    *,
    now: datetime | None = None,
    warn_days: int = DEFAULT_WARN_DAYS,
    spki_sha256: str = "",
) -> dict[str, Any]:
    moment = (now or now_beijing()).astimezone(timezone.utc)
    remaining_seconds = (not_after_utc.astimezone(timezone.utc) - moment).total_seconds()
    days_remaining = round(remaining_seconds / 86400.0, 2)
    return {
        "cert_path": str(cert_path),
        "spki_sha256": spki_sha256,
        "not_after": not_after_utc.astimezone(BEIJING).isoformat(),
        "not_after_utc": not_after_utc.astimezone(timezone.utc).isoformat(),
        "days_remaining": days_remaining,
        "expired": remaining_seconds <= 0,
        "warn_due": days_remaining <= float(warn_days),
    }


def check_cert_expiry_and_notify(
    cert_path: Path,
    state_path: Path,
    *,
    now: datetime | None = None,
    warn_days: int = DEFAULT_WARN_DAYS,
    openssl_bin: str | None = None,
    notify_fn: Callable[..., bool] | None = None,
    served_info: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """每日巡检 TLS 证书剩余有效期；到期前 `warn_days`（默认 60 天）发 timeSensitive Bark 提醒。

    当传入 `served_info`（内存实际正在服务的证书元数据，含 `not_after_utc` / `spki_sha256`）时，
    以实际在服务的证书为准，避免仅换了磁盘文件但服务未重载导致旧证书到期不告警。
    """
    moment = (now or now_beijing()).astimezone(BEIJING)
    today = moment.date().isoformat()
    state = load_json(state_path, {})
    if not isinstance(state, dict):
        state = {}

    served_spki = str(served_info.get("spki_sha256") or "") if served_info else ""
    served_not_after: datetime | None = None
    if served_info and served_info.get("not_after_utc"):
        try:
            served_not_after = datetime.fromisoformat(str(served_info["not_after_utc"]))
        except ValueError:
            served_not_after = None

    if served_not_after is None and not cert_path.is_file():
        return {"checked": False, "reason": "missing_cert", "notified": False}

    # 若在服务证书指纹发生变化（例如刚刚热重载了新证书），不能复用旧证书的当日缓存。
    same_cert = not served_spki or state.get("spki_sha256") == served_spki
    if same_cert and state.get("last_checked_date") == today and (
        not state.get("warn_due") or state.get("last_notified_date") == today
    ):
        return {
            "checked": False,
            "cached": True,
            "notified": False,
            "days_remaining": state.get("days_remaining"),
            "warn_due": bool(state.get("warn_due")),
        }

    if served_not_after is not None:
        info = _expiry_from_not_after_utc(
            cert_path,
            served_not_after,
            now=moment,
            warn_days=warn_days,
            spki_sha256=served_spki,
        )
    else:
        info = cert_expiry_info(cert_path, now=moment, warn_days=warn_days, openssl_bin=openssl_bin)
        info["spki_sha256"] = served_spki

    notified = False
    if info["warn_due"] and (not same_cert or state.get("last_notified_date") != today):
        sender = notify_fn
        if sender is None:
            import maa_notify

            sender = maa_notify.notify
        days_int = max(0, int(info["days_remaining"]))
        if info["expired"]:
            title = "⚠️ 本地 TLS 证书已过期"
            body = "请在 Mac mini 运行 rotate_tls.py 轮换证书并更新 iOS App 证书指纹，否则局域网直连和远程隧道将中断。"
        else:
            title = f"⚠️ 本地 TLS 证书将在 {days_int} 天后到期"
            body = (
                f"到期时间：{str(info['not_after'])[:10]}。"
                "建议提前在 iOS App 写入备用指纹并在 Mac mini 运行 rotate_tls.py 实现零中断轮换。"
            )
        notified = bool(
            sender(
                title,
                body,
                level="timeSensitive",
                url="wadosmaa://settings",
                notification_id="tls-cert",
            )
        )

    new_state = {
        "schema_version": 1,
        "spki_sha256": info.get("spki_sha256", ""),
        "last_checked_date": today,
        "checked_at": moment.isoformat(),
        "not_after": info["not_after"],
        "days_remaining": info["days_remaining"],
        "warn_due": info["warn_due"],
        "last_notified_date": today if notified else (state.get("last_notified_date", "") if same_cert else ""),
    }
    ensure_private_dir(state_path.parent)
    atomic_write_json(state_path, new_state)
    return {
        "checked": True,
        "notified": notified,
        "days_remaining": info["days_remaining"],
        "not_after": info["not_after"],
        "warn_due": info["warn_due"],
        "spki_sha256": info.get("spki_sha256", ""),
    }


# ---------------------------------------------------------------------------
# Bearer Token 工具（仅落盘 SHA-256 哈希，常时间比对）
# ---------------------------------------------------------------------------


def generate_token(nbytes: int = 32) -> str:
    """生成高熵 URL-safe 随机 Bearer Token。"""
    return secrets.token_urlsafe(nbytes)


def hash_token(token: str) -> str:
    """返回 Token 的小写十六进制 SHA-256 哈希。"""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def verify_token(token: str, expected_sha256: str) -> bool:
    """常时间比对明文 Token 与预期 SHA-256 十六进制哈希。"""
    if not token or not expected_sha256:
        return False
    expected = expected_sha256.strip().lower()
    if len(expected) != 64:
        return False
    actual = hash_token(token)
    return hmac.compare_digest(actual, expected)


def merge_secrets(secrets_path: Path, updates: Mapping[str, Any]) -> dict[str, Any]:
    """安全 merge 写入 `daemon/secrets.json`（权限 0600，绝不丢失已有 Bark 等密钥）。"""
    ensure_private_dir(secrets_path.parent)
    existing = load_json(secrets_path, {})
    merged: dict[str, Any] = dict(existing) if isinstance(existing, dict) else {}
    merged.update(updates)
    atomic_write_json(secrets_path, merged)
    os.chmod(secrets_path, 0o600)
    return merged


# ---------------------------------------------------------------------------
# 零依赖纯 Python QR Code（ISO/IEC 18004 Byte Mode, EC Level L, Version 1–16）
# 用于 Mac 终端展示一次性配对二维码，无需任何第三方依赖。
# ---------------------------------------------------------------------------

# Version -> (total_codewords, ec_per_block, group1_blocks, group1_data, group2_blocks, group2_data)
_QR_L_SPEC: dict[int, tuple[int, int, int, int, int, int]] = {
    1: (26, 7, 1, 19, 0, 0),
    2: (44, 10, 1, 34, 0, 0),
    3: (70, 15, 1, 55, 0, 0),
    4: (100, 20, 1, 80, 0, 0),
    5: (134, 26, 1, 108, 0, 0),
    6: (172, 18, 2, 68, 0, 0),
    7: (196, 20, 2, 78, 0, 0),
    8: (242, 24, 2, 97, 0, 0),
    9: (292, 30, 2, 116, 0, 0),
    10: (346, 18, 2, 68, 2, 69),
    11: (404, 20, 4, 81, 0, 0),
    12: (466, 24, 2, 92, 2, 93),
    13: (532, 26, 4, 107, 0, 0),
    14: (581, 30, 3, 115, 1, 116),
    15: (655, 22, 5, 87, 1, 88),
    16: (733, 24, 5, 98, 1, 99),
}

_QR_ALIGNMENT: dict[int, tuple[int, ...]] = {
    1: (),
    2: (6, 18),
    3: (6, 22),
    4: (6, 26),
    5: (6, 30),
    6: (6, 34),
    7: (6, 22, 38),
    8: (6, 24, 42),
    9: (6, 26, 46),
    10: (6, 28, 50),
    11: (6, 30, 54),
    12: (6, 32, 58),
    13: (6, 34, 62),
    14: (6, 26, 46, 66),
    15: (6, 26, 48, 70),
    16: (6, 26, 50, 74),
}


def _gf_mul(a: int, b: int) -> int:
    res = 0
    while b > 0:
        if b & 1:
            res ^= a
        a <<= 1
        if a & 0x100:
            a ^= 0x11D
        b >>= 1
    return res


def _rs_generator(degree: int) -> list[int]:
    poly = [1]
    root = 1
    for _ in range(degree):
        nxt = [0] * (len(poly) + 1)
        for i, coeff in enumerate(poly):
            nxt[i] ^= coeff
            nxt[i + 1] ^= _gf_mul(coeff, root)
        poly = nxt
        root = _gf_mul(root, 2)
    return poly


def _rs_remainder(data: list[int], degree: int) -> list[int]:
    gen = _rs_generator(degree)
    rem = [0] * degree
    for byte in data:
        factor = byte ^ rem[0]
        rem = rem[1:] + [0]
        if factor:
            for i in range(degree):
                rem[i] ^= _gf_mul(gen[i + 1], factor)
    return rem


def _select_qr_version(data_len: int) -> int:
    for version in sorted(_QR_L_SPEC):
        _total, _ec, g1_cnt, g1_len, g2_cnt, g2_len = _QR_L_SPEC[version]
        data_codewords = g1_cnt * g1_len + g2_cnt * g2_len
        count_bits = 8 if version <= 9 else 16
        max_bytes = (data_codewords * 8 - 4 - count_bits) // 8
        if data_len <= max_bytes:
            return version
    raise ValueError(f"配对载荷过长（{data_len} 字节），超出 QR Version 16 容量")


def _encode_qr_codewords(payload: bytes, version: int) -> list[int]:
    _total, ec_len, g1_cnt, g1_len, g2_cnt, g2_len = _QR_L_SPEC[version]
    data_cap = g1_cnt * g1_len + g2_cnt * g2_len
    bits: list[int] = []

    def push(val: int, width: int) -> None:
        for shift in range(width - 1, -1, -1):
            bits.append((val >> shift) & 1)

    push(0b0100, 4)  # Byte mode
    push(len(payload), 8 if version <= 9 else 16)
    for b in payload:
        push(b, 8)
    cap_bits = data_cap * 8
    terminator = min(4, cap_bits - len(bits))
    push(0, terminator)
    while len(bits) % 8 != 0:
        bits.append(0)
    data_bytes = [
        sum(bits[i + k] << (7 - k) for k in range(8)) for i in range(0, len(bits), 8)
    ]
    pad_seq = (0xEC, 0x11)
    pad_idx = 0
    while len(data_bytes) < data_cap:
        data_bytes.append(pad_seq[pad_idx & 1])
        pad_idx += 1

    # 分块并生成 Reed-Solomon 纠错码，然后按列交错。
    blocks: list[list[int]] = []
    ecs: list[list[int]] = []
    pos = 0
    for count, length in ((g1_cnt, g1_len), (g2_cnt, g2_len)):
        for _ in range(count):
            blk = data_bytes[pos : pos + length]
            pos += length
            blocks.append(blk)
            ecs.append(_rs_remainder(blk, ec_len))

    out: list[int] = []
    max_blk = max(len(b) for b in blocks)
    for col in range(max_blk):
        for blk in blocks:
            if col < len(blk):
                out.append(blk[col])
    for col in range(ec_len):
        for ec in ecs:
            out.append(ec[col])
    return out


def _format_bits(ec_bits: int, mask: int) -> int:
    data = (ec_bits << 3) | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    return ((data << 10) | rem) ^ 0x5412


def _version_bits(version: int) -> int:
    rem = version
    for _ in range(12):
        rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
    return (version << 12) | rem


def _qr_penalty(grid: list[list[bool]]) -> int:
    size = len(grid)
    score = 0
    # 规则 1：同色连续 >= 5
    for r in range(size):
        run_color = grid[r][0]
        run_len = 1
        for c in range(1, size):
            if grid[r][c] == run_color:
                run_len += 1
            else:
                if run_len >= 5:
                    score += 3 + (run_len - 5)
                run_color = grid[r][c]
                run_len = 1
        if run_len >= 5:
            score += 3 + (run_len - 5)
    for c in range(size):
        run_color = grid[0][c]
        run_len = 1
        for r in range(1, size):
            if grid[r][c] == run_color:
                run_len += 1
            else:
                if run_len >= 5:
                    score += 3 + (run_len - 5)
                run_color = grid[r][c]
                run_len = 1
        if run_len >= 5:
            score += 3 + (run_len - 5)
    # 规则 2：2x2 同色块
    for r in range(size - 1):
        for c in range(size - 1):
            v = grid[r][c]
            if v == grid[r][c + 1] == grid[r + 1][c] == grid[r + 1][c + 1]:
                score += 3
    # 规则 4：黑块比例偏离 50%
    dark = sum(1 for row in grid for cell in row if cell)
    k = abs(dark * 20 - size * size * 10) // (size * size)
    score += k * 10
    return score


def encode_qr_matrix(text: str) -> list[list[bool]]:
    """把 UTF-8 文本编码为标准 QR 布尔矩阵（True = 深色模块）。"""
    payload = text.encode("utf-8")
    version = _select_qr_version(len(payload))
    size = version * 4 + 17
    modules = [[False] * size for _ in range(size)]
    is_func = [[False] * size for _ in range(size)]

    def set_func(r: int, c: int, dark: bool) -> None:
        modules[r][c] = dark
        is_func[r][c] = True

    # Finder + Separator
    for fr, fc in ((0, 0), (0, size - 7), (size - 7, 0)):
        for dr in range(-1, 8):
            for dc in range(-1, 8):
                r, c = fr + dr, fc + dc
                if 0 <= r < size and 0 <= c < size:
                    in_outer = 0 <= dr <= 6 and 0 <= dc <= 6
                    on_border = dr in (0, 6) or dc in (0, 6)
                    in_center = 2 <= dr <= 4 and 2 <= dc <= 4
                    set_func(r, c, in_outer and (on_border or in_center))

    # Timing Patterns
    for i in range(8, size - 8):
        if not is_func[6][i]:
            set_func(6, i, i % 2 == 0)
        if not is_func[i][6]:
            set_func(i, 6, i % 2 == 0)

    # Alignment Patterns
    centers = _QR_ALIGNMENT[version]
    for ar in centers:
        for ac in centers:
            if is_func[ar][ac]:
                continue
            for dr in range(-2, 3):
                for dc in range(-2, 3):
                    dark = max(abs(dr), abs(dc)) != 1
                    set_func(ar + dr, ac + dc, dark)

    # 预留 Format Info 区域 + Dark Module
    for i in range(9):
        if i != 6:
            set_func(8, i, False)
            set_func(i, 8, False)
    for i in range(8):
        set_func(8, size - 1 - i, False)
        set_func(size - 1 - i, 8, False)
    set_func(size - 8, 8, True)

    # Version Info（Version >= 7）
    if version >= 7:
        vbits = _version_bits(version)
        for i in range(18):
            bit = bool((vbits >> i) & 1)
            a = size - 11 + (i % 3)
            b = i // 3
            set_func(b, a, bit)
            set_func(a, b, bit)

    # 按蛇形路径填入数据 + 纠错位
    codewords = _encode_qr_codewords(payload, version)
    bit_idx = 0
    total_bits = len(codewords) * 8
    upward = True
    col = size - 1
    while col > 0:
        if col == 6:
            col -= 1
        rows = range(size - 1, -1, -1) if upward else range(size)
        for r in rows:
            for dc in (0, -1):
                c = col + dc
                if not is_func[r][c]:
                    if bit_idx < total_bits:
                        bit = bool((codewords[bit_idx >> 3] >> (7 - (bit_idx & 7))) & 1)
                    else:
                        bit = False
                    modules[r][c] = bit
                    bit_idx += 1
        upward = not upward
        col -= 2

    def mask_cond(mask: int, r: int, c: int) -> bool:
        if mask == 0:
            return (r + c) % 2 == 0
        if mask == 1:
            return r % 2 == 0
        if mask == 2:
            return c % 3 == 0
        if mask == 3:
            return (r + c) % 3 == 0
        if mask == 4:
            return ((r // 2) + (c // 3)) % 2 == 0
        if mask == 5:
            return (r * c) % 2 + (r * c) % 3 == 0
        if mask == 6:
            return ((r * c) % 2 + (r * c) % 3) % 2 == 0
        return ((r + c) % 2 + (r * c) % 3) % 2 == 0

    def apply_mask_and_format(mask: int) -> list[list[bool]]:
        grid = [row[:] for row in modules]
        for r in range(size):
            for c in range(size):
                if not is_func[r][c] and mask_cond(mask, r, c):
                    grid[r][c] = not grid[r][c]
        # EC Level L 的 2-bit 编码为 0b01
        fbits = _format_bits(0b01, mask)
        for i in range(6):
            grid[8][i] = bool((fbits >> (14 - i)) & 1)
        grid[8][7] = bool((fbits >> 8) & 1)
        grid[8][8] = bool((fbits >> 7) & 1)
        grid[7][8] = bool((fbits >> 6) & 1)
        for i in range(9, 15):
            grid[14 - i][8] = bool((fbits >> (14 - i)) & 1)
        for i in range(8):
            grid[size - 1 - i][8] = bool((fbits >> i) & 1)
        for i in range(8):
            grid[8][size - 8 + i] = bool((fbits >> (7 - i)) & 1)
        return grid

    best_grid: list[list[bool]] | None = None
    best_score = 10**9
    for m in range(8):
        candidate = apply_mask_and_format(m)
        score = _qr_penalty(candidate)
        if score < best_score:
            best_score = score
            best_grid = candidate
    assert best_grid is not None
    return best_grid


def render_qr_terminal(text: str, *, border: int = 2, invert: bool = False) -> str:
    """用 Unicode 半块字符将 QR 矩阵渲染为紧凑终端文本。

    默认白底黑码语义适合浅色背景或支持深色反显的终端；`invert=True` 反转深浅（黑底白字终端更易扫）。
    """
    matrix = encode_qr_matrix(text)
    size = len(matrix)
    pad = max(1, border)
    padded: list[list[bool]] = []
    empty_row = [False] * (size + pad * 2)
    for _ in range(pad):
        padded.append(empty_row[:])
    for row in matrix:
        padded.append([False] * pad + row + [False] * pad)
    for _ in range(pad):
        padded.append(empty_row[:])

    if invert:
        padded = [[not cell for cell in row] for row in padded]

    lines: list[str] = []
    height = len(padded)
    width = len(padded[0])
    for r in range(0, height, 2):
        top = padded[r]
        bot = padded[r + 1] if r + 1 < height else [invert] * width
        chars: list[str] = []
        for c in range(width):
            t, b = top[c], bot[c]
            if t and b:
                chars.append("█")
            elif t and not b:
                chars.append("▀")
            elif not t and b:
                chars.append("▄")
            else:
                chars.append(" ")
        lines.append("".join(chars))
    return "\n".join(lines)
