#!/usr/bin/env python3
"""Wado's MAA 本地 TLS 证书平滑轮换脚本（Phase 2 S2-1）。

支持零中断两步轮换：
1. `--stage`：先生成 `daemon/tls/cert.next.pem` + `key.next.pem` 并输出新 SPKI 指纹，
   用户将其填入 iOS App 的「备用指纹」槽位；
2. `--activate`：将 `next` 证书原子替换正式 `cert.pem` / `key.pem`（自动备份旧证书），
   随后重载 `wados-maa-daemon` 与 `wados-maa-cloudflared`。

也支持默认一步直接替换（`--now`）。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_PATH = REPO_ROOT / "scripts"
if str(SCRIPTS_PATH) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_PATH))

import maa_common  # noqa: E402
import maa_tls  # noqa: E402


def stage_next_cert(
    target_home: Path,
    *,
    lan_ip: str = "192.168.50.2",
    days: int = maa_tls.DEFAULT_CERT_DAYS,
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    tls_dir = target_home / "daemon" / "tls"
    info = maa_tls.generate_self_signed_cert(
        tls_dir / "cert.next.pem",
        tls_dir / "key.next.pem",
        lan_ip=lan_ip,
        days=days,
        openssl_bin=openssl_bin,
    )
    return {"ok": True, "action": "staged", **info}


def activate_next_cert(
    target_home: Path,
    *,
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    tls_dir = target_home / "daemon" / "tls"
    next_cert = tls_dir / "cert.next.pem"
    next_key = tls_dir / "key.next.pem"
    live_cert = tls_dir / "cert.pem"
    live_key = tls_dir / "key.pem"
    if not (next_cert.is_file() and next_key.is_file()):
        raise FileNotFoundError("未找到待激活的 cert.next.pem / key.next.pem，请先运行 --stage。")

    backup_dir: Path | None = None
    if live_cert.is_file() or live_key.is_file():
        stamp = maa_common.now_beijing().strftime("%Y%m%dT%H%M%S")
        backup_dir = tls_dir / f"backup-{stamp}"
        maa_common.ensure_private_dir(backup_dir)
        for src in (live_cert, live_key):
            if src.is_file():
                dst = backup_dir / src.name
                shutil.copy2(src, dst)
                os.chmod(dst, 0o600)

    os.replace(next_cert, live_cert)
    os.replace(next_key, live_key)
    os.chmod(live_cert, 0o600)
    os.chmod(live_key, 0o600)
    spki = maa_tls.compute_spki_sha256(live_cert, openssl_bin=openssl_bin)
    expiry = maa_tls.cert_expiry_info(live_cert, openssl_bin=openssl_bin)
    return {
        "ok": True,
        "action": "activated",
        "cert_path": str(live_cert),
        "key_path": str(live_key),
        "backup_dir": str(backup_dir) if backup_dir else None,
        "spki_sha256": spki,
        "not_after": expiry["not_after"],
        "days_remaining": expiry["days_remaining"],
    }


def rotate_now(
    target_home: Path,
    *,
    lan_ip: str = "192.168.50.2",
    days: int = maa_tls.DEFAULT_CERT_DAYS,
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    stage_next_cert(target_home, lan_ip=lan_ip, days=days, openssl_bin=openssl_bin)
    result = activate_next_cert(target_home, openssl_bin=openssl_bin)
    result["action"] = "rotated"
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="平滑轮换 Wado's MAA 本地 TLS 自签证书")
    parser.add_argument("--home", default="", help="目标 WADOS_MAA_HOME")
    parser.add_argument("--lan-ip", default="192.168.50.2", help="Mac mini 局域网 IP")
    parser.add_argument("--days", type=int, default=maa_tls.DEFAULT_CERT_DAYS, help="新证书有效期天数")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--stage", action="store_true", help="仅预生成 next 证书并输出新 SPKI 指纹")
    group.add_argument("--activate", action="store_true", help="激活已预生成的 next 证书并备份旧证书")
    args = parser.parse_args(argv)

    home = Path(args.home).expanduser() if args.home else maa_common.resolve_home()
    if args.stage:
        out = stage_next_cert(home, lan_ip=args.lan_ip, days=args.days)
    elif args.activate:
        out = activate_next_cert(home)
    else:
        out = rotate_now(home, lan_ip=args.lan_ip, days=args.days)
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
