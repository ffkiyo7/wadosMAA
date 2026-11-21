#!/usr/bin/env python3
"""Wado's MAA 本地 TLS 证书平滑轮换脚本（Phase 2 S2-1）。

支持零中断两步轮换：
1. `--stage`：先生成 `daemon/tls/cert.next.pem` + `key.next.pem` 并输出新 SPKI 指纹，
   用户将其填入 iOS App 的「备用指纹」槽位；
2. `--activate`：将 `next` 证书原子替换正式 `cert.pem` / `key.pem`（自动备份旧证书），
   并**立即触发并核验**运行中的 `wados-maa-daemon` 热重载 TLS 证书与本目录对应的
   `wados-maa-cloudflared` 重载新 `caPool`；重载失败会明确报错（退出码非 0）。

也支持默认一步直接替换（先 stage 再 activate）。
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_PATH = REPO_ROOT / "scripts"
if str(SCRIPTS_PATH) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_PATH))

import maa_common  # noqa: E402
import maa_tls  # noqa: E402

CLOUDFLARED_LABEL = "io.github.ffkiyo7.wados-maa.cloudflared"

DaemonReloader = Callable[[Path, str], dict[str, Any]]
CloudflaredReloader = Callable[[Path], dict[str, Any]]


class RotationReloadError(RuntimeError):
    """证书已落盘但服务重载失败时抛出，附带结构化回执与恢复指引。"""

    def __init__(self, message: str, *, report: dict[str, Any]) -> None:
        super().__init__(message)
        self.report = report


def _is_daemon_pid(pid: int) -> bool:
    try:
        proc = subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if proc.returncode != 0:
        return False
    return any(Path(part).name == "maa_daemon.py" for part in proc.stdout.strip().split())


def reload_running_daemon(
    target_home: Path,
    expected_spki: str,
    *,
    expected_cert_sha256: str = "",
    wait_seconds: float = 5.0,
) -> dict[str, Any]:
    """通知运行中的 `wados-maa-daemon` 热重载 TLS 证书并核对 `active_tls.json` 确已切换。

    优先比对 `spki_sha256`；当 daemon 因缺少 OpenSSL 3 无法产出 `spki_sha256` 时，
    使用不依赖 openssl 命令的纯 Python `cert_sha256`（DER SHA-256）核验；
    两者均无法确认匹配时绝不误报成功，超时明确抛 `RuntimeError`。
    """
    daemon_dir = target_home / "daemon"
    pid_file = daemon_dir / "daemon.pid"
    if not pid_file.is_file():
        return {"status": "not_running", "reloaded": False}
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return {"status": "not_running", "reloaded": False}
    if pid <= 1 or not _is_daemon_pid(pid):
        return {"status": "not_running", "reloaded": False}

    cert_sha256 = expected_cert_sha256.strip().lower()
    if not cert_sha256:
        live_cert = daemon_dir / "tls" / "cert.pem"
        if live_cert.is_file():
            try:
                cert_sha256 = maa_tls.compute_cert_sha256(live_cert)
            except (OSError, ValueError):
                cert_sha256 = ""

    if not expected_spki and not cert_sha256:
        raise RuntimeError("无法计算新证书指纹（SPKI 与 cert_sha256 均不可用），拒绝确认 daemon 重载成功。")

    maa_common.atomic_write_text(
        daemon_dir / "reload.flag",
        maa_common.now_beijing().isoformat() + "\n",
        mode=0o600,
    )
    try:
        os.kill(pid, signal.SIGHUP)
    except OSError as exc:
        raise RuntimeError(f"向 wados-maa-daemon (pid={pid}) 发送 SIGHUP 失败：{exc}") from exc

    active_path = daemon_dir / "active_tls.json"
    deadline = time.monotonic() + max(0.5, wait_seconds)
    while time.monotonic() < deadline:
        info = maa_common.load_json(active_path, {})
        if isinstance(info, dict) and info.get("pid") == pid:
            actual_spki = str(info.get("spki_sha256") or "")
            actual_cert_sha = str(info.get("cert_sha256") or "").strip().lower()
            if expected_spki and actual_spki:
                if actual_spki == expected_spki and (not cert_sha256 or not actual_cert_sha or actual_cert_sha == cert_sha256):
                    return {
                        "status": "reloaded",
                        "reloaded": True,
                        "pid": pid,
                        "spki_sha256": expected_spki,
                        "cert_sha256": actual_cert_sha or cert_sha256,
                        "verified_via": "spki_sha256",
                    }
            elif cert_sha256 and actual_cert_sha and actual_cert_sha == cert_sha256:
                return {
                    "status": "reloaded",
                    "reloaded": True,
                    "pid": pid,
                    "spki_sha256": actual_spki,
                    "cert_sha256": cert_sha256,
                    "verified_via": "cert_sha256",
                }
        time.sleep(0.1)

    raise RuntimeError(
        f"wados-maa-daemon (pid={pid}) 收到重载信号后 {wait_seconds:.1f}s 内未确认切换至新证书"
        f"（预期 SPKI={expected_spki or '无'} / cert_sha256={cert_sha256 or '无'}），"
        "请检查 daemon.log 并重启守护进程。"
    )


def _installed_cloudflared_plist() -> Path:
    return Path.home() / "Library" / "LaunchAgents" / f"{CLOUDFLARED_LABEL}.plist"


def _plist_targets_home(plist_path: Path, target_home: Path) -> bool:
    if not plist_path.is_file():
        return False
    try:
        data = plistlib.loads(plist_path.read_bytes())
    except (OSError, ValueError):
        return False
    args = data.get("ProgramArguments") if isinstance(data, dict) else None
    if not isinstance(args, list):
        return False
    expected_cfg = str((target_home / "daemon" / "wados-maa-cloudflared.yml").resolve())
    for item in args:
        try:
            if str(Path(str(item)).expanduser().resolve()) == expected_cfg:
                return True
        except OSError:
            continue
    return False


def _find_target_cloudflared_pids(target_home: Path) -> list[int]:
    expected_cfg = str(target_home / "daemon" / "wados-maa-cloudflared.yml")
    resolved_cfg = str((target_home / "daemon" / "wados-maa-cloudflared.yml").resolve())
    try:
        proc = subprocess.run(
            ["/bin/ps", "-ax", "-o", "pid=,command="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if proc.returncode != 0:
        return []
    pids: list[int] = []
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        cmd = parts[1]
        if "cloudflared" in cmd and (expected_cfg in cmd or resolved_cfg in cmd):
            pids.append(int(parts[0]))
    return pids


def reload_running_cloudflared(target_home: Path) -> dict[str, Any]:
    """仅重载与 `target_home` 绑定的 `wados-maa-cloudflared`，绝不碰线上或其他隧道。"""
    plist_path = _installed_cloudflared_plist()
    uid = os.getuid()
    domain_target = f"gui/{uid}/{CLOUDFLARED_LABEL}"

    if _plist_targets_home(plist_path, target_home) and shutil.which("launchctl"):
        probe = subprocess.run(
            ["launchctl", "print", domain_target],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        if probe.returncode == 0:
            kick = subprocess.run(
                ["launchctl", "kickstart", "-k", domain_target],
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            if kick.returncode != 0:
                detail = (kick.stderr or kick.stdout or "").strip()[:300]
                raise RuntimeError(f"重载 {domain_target} 失败：{detail}")
            return {"status": "reloaded", "reloaded": True, "via": "launchctl", "target": domain_target}

    pids = _find_target_cloudflared_pids(target_home)
    if pids:
        raise RuntimeError(
            f"检测到独立运行的 cloudflared 进程（pid={pids}）未由 LaunchAgent 托管，无法自动重载新 caPool，请手动重启它。"
        )
    return {"status": "not_running", "reloaded": False}


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
    reload_services: bool = True,
    daemon_reloader: DaemonReloader | None = None,
    cloudflared_reloader: CloudflaredReloader | None = None,
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
    cert_sha256 = maa_tls.compute_cert_sha256(live_cert)
    spki = ""
    not_after: str | None = None
    days_remaining: float | None = None
    try:
        spki = maa_tls.compute_spki_sha256(live_cert, openssl_bin=openssl_bin)
        expiry = maa_tls.cert_expiry_info(live_cert, openssl_bin=openssl_bin)
        not_after = expiry["not_after"]
        days_remaining = expiry["days_remaining"]
    except Exception as exc:  # noqa: BLE001 — (c) OpenSSL 3 不可用时降级改由 cert_sha256 核验
        print(f"warning: activate_next_cert metadata unavailable: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)

    reload_report: dict[str, Any] = {}
    if reload_services:
        d_reloader = daemon_reloader or reload_running_daemon
        c_reloader = cloudflared_reloader or reload_running_cloudflared
        daemon_failed_err = ""
        try:
            d_res = d_reloader(target_home, spki)
            reload_report["daemon"] = d_res
            if isinstance(d_res, dict) and d_res.get("status") == "failed":
                daemon_failed_err = str(d_res.get("error") or "daemon 返回重载失败状态")
        except Exception as exc:  # noqa: BLE001 — (a) 收集并显式抛出重载失败原因
            daemon_failed_err = str(exc)
            reload_report["daemon"] = {"status": "failed", "reloaded": False, "error": daemon_failed_err}

        if daemon_failed_err:
            # 关键防断链：daemon 未确认切换至新证书前绝不重载 cloudflared，
            # 否则 cloudflared 改信新 caPool 而 daemon 仍服务旧证书会导致公网隧道与 /rescue 中断。
            reload_report["cloudflared"] = {
                "status": "skipped",
                "reloaded": False,
                "reason": "daemon_reload_failed",
            }
            recovery = (
                f"可先检查 {target_home / 'logs' / 'daemon.log'} 排障后重启 wados-maa-daemon 与 "
                "wados-maa-cloudflared；若需立刻恢复磁盘与在服务证书一致，请将 "
                f"{backup_dir or (tls_dir / 'backup-<timestamp>')} 下的旧 cert.pem/key.pem 拷回 {tls_dir}。"
            )
            msg = (
                f"新证书已落盘但 wados-maa-daemon 重载失败（{daemon_failed_err}）；"
                "为避免公网隧道中断，cloudflared 未重载（仍信任旧证书）。"
                f"当前磁盘 cert.pem 与 daemon 在服务证书不一致。下一步：{recovery}"
            )
            fail_report: dict[str, Any] = {
                "ok": False,
                "action": "activated",
                "cert_path": str(live_cert),
                "key_path": str(live_key),
                "backup_dir": str(backup_dir) if backup_dir else None,
                "spki_sha256": spki,
                "disk_cert_matches_served": False,
                "reload": reload_report,
                "recovery": recovery,
                "error": msg,
            }
            raise RotationReloadError(msg, report=fail_report)

        try:
            reload_report["cloudflared"] = c_reloader(target_home)
        except Exception as exc:  # noqa: BLE001 — (a) 收集并显式抛出重载失败原因
            reload_report["cloudflared"] = {"status": "failed", "reloaded": False, "error": str(exc)}
            recovery = (
                "wados-maa-daemon 已切换至新证书，但 cloudflared 尚未重载新 caPool；"
                "请手动重启对应 wados-maa-cloudflared 进程/LaunchAgent 使公网隧道加载新证书。"
            )
            msg = f"新证书已落盘且 daemon 已切换，但 cloudflared 重载失败（{exc}）。下一步：{recovery}"
            fail_report = {
                "ok": False,
                "action": "activated",
                "cert_path": str(live_cert),
                "key_path": str(live_key),
                "backup_dir": str(backup_dir) if backup_dir else None,
                "spki_sha256": spki,
                "disk_cert_matches_served": True,
                "reload": reload_report,
                "recovery": recovery,
                "error": msg,
            }
            raise RotationReloadError(msg, report=fail_report) from exc

    return {
        "ok": True,
        "action": "activated",
        "cert_path": str(live_cert),
        "key_path": str(live_key),
        "backup_dir": str(backup_dir) if backup_dir else None,
        "cert_sha256": cert_sha256,
        "spki_sha256": spki,
        "not_after": not_after,
        "days_remaining": days_remaining,
        "reload": reload_report,
    }


def rotate_now(
    target_home: Path,
    *,
    lan_ip: str = "192.168.50.2",
    days: int = maa_tls.DEFAULT_CERT_DAYS,
    openssl_bin: str | None = None,
    reload_services: bool = True,
    daemon_reloader: DaemonReloader | None = None,
    cloudflared_reloader: CloudflaredReloader | None = None,
) -> dict[str, Any]:
    stage_next_cert(target_home, lan_ip=lan_ip, days=days, openssl_bin=openssl_bin)
    result = activate_next_cert(
        target_home,
        openssl_bin=openssl_bin,
        reload_services=reload_services,
        daemon_reloader=daemon_reloader,
        cloudflared_reloader=cloudflared_reloader,
    )
    result["action"] = "rotated"
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="平滑轮换 Wado's MAA 本地 TLS 自签证书")
    parser.add_argument("--home", default="", help="目标 WADOS_MAA_HOME")
    parser.add_argument("--lan-ip", default="192.168.50.2", help="Mac mini 局域网 IP")
    parser.add_argument("--days", type=int, default=maa_tls.DEFAULT_CERT_DAYS, help="新证书有效期天数")
    parser.add_argument("--no-reload", action="store_true", help="仅替换磁盘证书，不自动重载运行中的服务")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--stage", action="store_true", help="仅预生成 next 证书并输出新 SPKI 指纹")
    group.add_argument("--activate", action="store_true", help="激活已预生成的 next 证书并重载 daemon / cloudflared")
    args = parser.parse_args(argv)

    home = Path(args.home).expanduser() if args.home else maa_common.resolve_home()
    try:
        if args.stage:
            out = stage_next_cert(home, lan_ip=args.lan_ip, days=args.days)
        elif args.activate:
            out = activate_next_cert(home, reload_services=not args.no_reload)
        else:
            out = rotate_now(home, lan_ip=args.lan_ip, days=args.days, reload_services=not args.no_reload)
    except RotationReloadError as exc:
        print(json.dumps(exc.report, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — (a) CLI 顶层返回结构化失败回执与非零退出码
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
