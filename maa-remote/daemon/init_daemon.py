#!/usr/bin/env python3
"""Wado's MAA 守护进程初始化脚本（Phase 2 S2-1）。

职责：
1. 使用 Homebrew OpenSSL 3（ECDSA P-256 `named_curve`）生成 5 年自签证书 `daemon/tls/cert.pem` + `key.pem`（0600），
   SAN 含局域网 IP（默认 `192.168.50.2`）与 `127.0.0.1`，并计算 SPKI SHA-256 指纹；
2. 生成高熵 `full` 与 `resign_only` 两个 Bearer Token，仅将其 SHA-256 哈希 merge 写进 `daemon/secrets.json`（0600，保留既有 Bark 密钥）；
3. 更新 `daemon/daemon.json` 中的网络与端口配置（保留既有通知与 depot 开关）；
4. 渲染 `daemon/wados-maa-cloudflared.yml` 与 `daemon/io.github.ffkiyo7.wados-maa.cloudflared.plist`；
5. 在终端输出一次性配对 JSON 与标准 Unicode QR 二维码（含 `lan_url`、`remote_url`、`spki_sha256`、`full_token`）。
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_PATH = REPO_ROOT / "scripts"
if str(SCRIPTS_PATH) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_PATH))

import maa_common  # noqa: E402
import maa_daemon  # noqa: E402
import maa_tls  # noqa: E402

DEFAULT_TUNNEL_ID = "dcd1aac1-ff11-4a1f-b91c-9fb37b045716"
DEFAULT_HOSTNAME = "maa.luxraykit.com"


def render_cloudflared_files(
    target_home: Path,
    *,
    cert_path: Path,
    api_port: int = 18170,
    tunnel_id: str = DEFAULT_TUNNEL_ID,
    hostname: str = DEFAULT_HOSTNAME,
    credentials_file: Path | None = None,
) -> tuple[Path, Path]:
    """根据模板渲染独立的 cloudflared 配置与 LaunchAgent plist 到 `target_home/daemon/`。"""
    daemon_dir = target_home / "daemon"
    logs_dir = target_home / "logs"
    maa_common.ensure_private_dir(daemon_dir)
    maa_common.ensure_private_dir(logs_dir)

    creds = credentials_file or (Path.home() / ".cloudflared" / f"{tunnel_id}.json")
    yml_tmpl = REPO_ROOT / "daemon" / "wados-maa-cloudflared.yml.tmpl"
    yml_target = daemon_dir / "wados-maa-cloudflared.yml"
    yml_text = (
        yml_tmpl.read_text(encoding="utf-8")
        .replace("__TUNNEL_ID__", tunnel_id)
        .replace("__CREDENTIALS_FILE__", str(creds))
        .replace("__HOSTNAME__", hostname)
        .replace("__API_PORT__", str(api_port))
        .replace("__TLS_CERT_PATH__", str(cert_path))
    )
    maa_common.atomic_write_text(yml_target, yml_text, mode=0o600)

    plist_tmpl = REPO_ROOT / "daemon" / "io.github.ffkiyo7.wados-maa.cloudflared.plist"
    plist_target = daemon_dir / "io.github.ffkiyo7.wados-maa.cloudflared.plist"
    plist_text = (
        plist_tmpl.read_text(encoding="utf-8")
        .replace("__CLOUDFLARED_CONFIG__", str(yml_target))
        .replace("__LOGS_DIR__", str(logs_dir))
    )
    maa_common.atomic_write_text(plist_target, plist_text, mode=0o600)
    return yml_target, plist_target


def init_daemon_home(
    target_home: Path,
    *,
    lan_ip: str = "192.168.50.2",
    remote_url: str = "https://maa.luxraykit.com",
    api_port: int = 18170,
    days: int = maa_tls.DEFAULT_CERT_DAYS,
    force_cert: bool = False,
    force_tokens: bool = False,
    openssl_bin: str | None = None,
) -> dict[str, Any]:
    """初始化（或补齐）指定运行目录的 TLS 证书、分域 Token 与隧道配置。"""
    daemon_dir = target_home / "daemon"
    tls_dir = daemon_dir / "tls"
    cert_path = tls_dir / "cert.pem"
    key_path = tls_dir / "key.pem"
    secrets_path = daemon_dir / "secrets.json"
    daemon_cfg_path = daemon_dir / "daemon.json"
    maa_common.ensure_private_dir(daemon_dir)
    maa_common.ensure_private_dir(tls_dir)

    if force_cert or not (cert_path.is_file() and key_path.is_file()):
        cert_info = maa_tls.generate_self_signed_cert(
            cert_path,
            key_path,
            lan_ip=lan_ip,
            days=days,
            openssl_bin=openssl_bin,
        )
        cert_created = True
    else:
        spki = maa_tls.compute_spki_sha256(cert_path, openssl_bin=openssl_bin)
        expiry = maa_tls.cert_expiry_info(cert_path, openssl_bin=openssl_bin)
        cert_info = {
            "cert_path": str(cert_path),
            "key_path": str(key_path),
            "spki_sha256": spki,
            "not_after": expiry["not_after"],
            "days_remaining": expiry["days_remaining"],
        }
        cert_created = False

    existing_secrets = maa_common.load_json(secrets_path, {})
    if not isinstance(existing_secrets, dict):
        existing_secrets = {}
    updates: dict[str, Any] = {}
    full_token: str | None = None
    resign_token: str | None = None

    if force_tokens or not existing_secrets.get("full_token_sha256"):
        full_token = maa_tls.generate_token()
        updates["full_token_sha256"] = maa_tls.hash_token(full_token)
    if force_tokens or not existing_secrets.get("resign_only_token_sha256"):
        resign_token = maa_tls.generate_token()
        updates["resign_only_token_sha256"] = maa_tls.hash_token(resign_token)
    if updates:
        maa_tls.merge_secrets(secrets_path, updates)

    cfg = maa_daemon.load_daemon_config(daemon_cfg_path)
    cfg["api_enabled"] = True
    cfg["api_port"] = int(api_port)
    cfg["lan_ip"] = lan_ip
    cfg["remote_url"] = remote_url.rstrip("/")
    maa_common.atomic_write_json(daemon_cfg_path, cfg)
    os.chmod(daemon_cfg_path, 0o600)

    hostname = remote_url.replace("https://", "").replace("http://", "").split("/", 1)[0] or DEFAULT_HOSTNAME
    yml_path, plist_path = render_cloudflared_files(
        target_home,
        cert_path=cert_path,
        api_port=int(api_port),
        hostname=hostname,
    )

    pairing: dict[str, Any] = {
        "lan_url": f"https://{lan_ip}:{int(api_port)}",
        "remote_url": remote_url.rstrip("/"),
        "spki_sha256": cert_info["spki_sha256"],
    }
    if full_token is not None:
        pairing["full_token"] = full_token

    return {
        "ok": True,
        "home": str(target_home),
        "cert_created": cert_created,
        "cert": cert_info,
        "secrets_path": str(secrets_path),
        "cloudflared_config": str(yml_path),
        "cloudflared_plist": str(plist_path),
        "pairing": pairing,
        "resign_only_token": resign_token,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="初始化 Wado's MAA TLS 证书、Token 与配对二维码")
    parser.add_argument("--home", default="", help="目标 WADOS_MAA_HOME（默认读取环境变量或 ~/.wados-maa）")
    parser.add_argument("--lan-ip", default="192.168.50.2", help="Mac mini 局域网 IP")
    parser.add_argument("--remote-url", default="https://maa.luxraykit.com", help="Cloudflare Tunnel 远程地址")
    parser.add_argument("--port", type=int, default=18170, help="本地 HTTPS API 端口")
    parser.add_argument("--days", type=int, default=maa_tls.DEFAULT_CERT_DAYS, help="证书有效期天数")
    parser.add_argument("--force-cert", action="store_true", help="强制重新生成 TLS 证书")
    parser.add_argument("--force-tokens", action="store_true", help="强制重新生成 full / resign_only Token")
    parser.add_argument("--json-only", action="store_true", help="仅输出单行 JSON，不打印终端二维码")
    parser.add_argument("--invert-qr", action="store_true", help="反色二维码（深色终端更易扫描）")
    args = parser.parse_args(argv)

    home = Path(args.home).expanduser() if args.home else maa_common.resolve_home()
    result = init_daemon_home(
        home,
        lan_ip=args.lan_ip,
        remote_url=args.remote_url,
        api_port=args.port,
        days=args.days,
        force_cert=args.force_cert,
        force_tokens=args.force_tokens,
    )
    if args.json_only:
        print(json.dumps(result, ensure_ascii=False))
        return 0

    pairing_json = json.dumps(result["pairing"], ensure_ascii=False, separators=(",", ":"))
    print("Wado's MAA 守护进程初始化完成")
    print(f"  运行目录：{result['home']}")
    print(f"  TLS 证书：{result['cert']['cert_path']}（到期：{result['cert']['not_after']}）")
    print(f"  SPKI 指纹：{result['cert']['spki_sha256']}")
    print(f"  隧道配置：{result['cloudflared_config']}")
    print("\n配对 JSON（供 iOS App 扫码或粘贴）：")
    print(json.dumps(result["pairing"], ensure_ascii=False, indent=2))
    if result["resign_only_token"]:
        print("\n独立续签 Token（仅限 iOS 快捷指令使用，仅显示一次）：")
        print(result["resign_only_token"])
    elif "full_token" not in result["pairing"]:
        print("\n提示：Token 已存在未重新生成（如需轮换请加 --force-tokens）。")
    print("\n一次性配对二维码：")
    print(maa_tls.render_qr_terminal(pairing_json, invert=args.invert_qr))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
