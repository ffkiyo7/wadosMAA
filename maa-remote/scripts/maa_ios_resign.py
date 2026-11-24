#!/usr/bin/env python3
"""iOS App 无线自动续签（Phase 4 S4-1，SPEC §7）。

免费个人 Apple ID 签出的描述文件 7 天过期。这里在 Mac mini 上定期从 `main` 部署目录
重新构建并无线覆盖安装，让手机上的 App 一直可用。

状态落盘 `daemon/resign.json`，单实例靠 `daemon/resign.lock`。三个入口：

- `auto`：守护进程每 25 分钟、且已到续签窗口时拉起（`--app-active` 表示 App 2 分钟内有请求）；
- `run`：App 按钮 / 快捷指令经 `POST /api/v1/ios/resign` 拉起；
- `status` / `bootstrap` / `shortcut-token`：命令行查看、按本机缓存的描述文件初始化状态、
  给快捷指令重新生成 `resign_only` Token。

硬约束：
- 构建源固定为 `~/Developer/wados-maa-deploy/ios/WadosMAAiOS.xcodeproj`，部署目录必须停在
  干净的 `main` 上，绝不从 `dev` 或开发 worktree 构建；
- 构建前先把本机缓存的本 App 描述文件挪走（S0-1 实证：不挪 Xcode 会复用旧文件，有效期不后移），
  构建失败时挪回；
- 新描述文件的 `ExpirationDate` 必须严格晚于旧值，否则判失败、不安装、不改签名记录。
"""

from __future__ import annotations

import argparse
import fcntl
import json
import plistlib
import shutil
import socket
import subprocess
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol

from maa_common import (
    BEIJING,
    DAEMON_DIR,
    LOGS_DIR,
    atomic_write_json,
    ensure_private_dir,
    is_run_locked,
    load_json,
    now_beijing,
)

SCHEMA_VERSION = 1
DEPLOY_WORKTREE = Path.home() / "Developer" / "wados-maa-deploy"
PROJECT_PATH = DEPLOY_WORKTREE / "ios" / "WadosMAAiOS.xcodeproj"
SCHEME = "WadosMAAiOS"
BUNDLE_ID = "io.github.ffkiyo7.WadosMAAiOS"
DERIVED_DATA = Path.home() / "Developer" / "forks" / "wados-maa-build" / "auto-resign"
APP_RELATIVE = Path("Build") / "Products" / "Release-iphoneos" / "WadosMAAiOS.app"
PROFILES_DIR = Path.home() / "Library" / "Developer" / "Xcode" / "UserData" / "Provisioning Profiles"

STATE_PATH = DAEMON_DIR / "resign.json"
LOCK_PATH = DAEMON_DIR / "resign.lock"
DAEMON_CONFIG_PATH = DAEMON_DIR / "daemon.json"
LOG_DIR = LOGS_DIR / "ios-resign"
LOG_KEEP = 20

DUE_AFTER = timedelta(hours=120)
DUE_BEFORE_EXPIRY = timedelta(hours=48)
ALERT_AFTER = timedelta(hours=156)  # 第 6.5 天
ALERT_BEFORE_EXPIRY = timedelta(hours=12)
CHECK_INTERVAL = timedelta(minutes=25)
APP_IDLE_WINDOW = timedelta(minutes=2)

BUILD_TIMEOUT = 30 * 60
INSTALL_TIMEOUT = 5 * 60
PROBE_TIMEOUT = 30
LOCKDOWN_PORT = 62078

TRIGGERS = ("auto", "ios", "shortcut", "cli")
NOTIFY_ID = "ios-resign"

# xcodebuild 输出里说明 Xcode 账号要人处理的字样（Apple ID 过期、没登录、证书没了）。
ACCOUNT_FAILURE_MARKERS = (
    "no accounts",
    "no account for team",
    "unable to log in",
    "session has expired",
    "re-enter your password",
    "sign in to your account",
    "no signing certificate",
    "your account does not have",
    "account is not logged in",
)


class Runner(Protocol):
    def __call__(self, argv: list[str], *, timeout: float, cwd: Path | None = None) -> tuple[int, str]: ...


def run_command(argv: list[str], *, timeout: float, cwd: Path | None = None) -> tuple[int, str]:
    """跑一条外部命令，合并 stdout/stderr；超时返回 124。"""
    try:
        proc = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else str(exc.stdout or "")
        return 124, out + f"\n[超时 {int(timeout)} 秒]"
    except OSError as exc:
        return 127, f"{type(exc).__name__}: {exc}"
    return proc.returncode, proc.stdout.decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# 配置与状态
# ---------------------------------------------------------------------------


def load_resign_config(path: Path | None = None) -> dict[str, Any]:
    raw = load_json(path or DAEMON_CONFIG_PATH, {})
    raw = raw if isinstance(raw, dict) else {}
    return {
        "enabled": bool(raw.get("ios_resign_enabled", True)),
        "udid": str(raw.get("ios_device_udid") or "").strip(),
        "lan_ip": str(raw.get("ios_device_lan_ip") or "").strip(),
    }


def is_configured(cfg: Mapping[str, Any]) -> bool:
    return bool(cfg.get("enabled")) and bool(cfg.get("udid"))


def load_state(path: Path | None = None) -> dict[str, Any]:
    raw = load_json(path or STATE_PATH, {})
    return dict(raw) if isinstance(raw, dict) else {}


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=BEIJING)
    return parsed.astimezone(BEIJING)


def due_reason(state: Mapping[str, Any], now: datetime) -> str:
    """到续签窗口时返回原因，没到返回空串。没有签名记录一律算到期。"""
    signed = _parse_time(state.get("last_signed_at"))
    expires = _parse_time(state.get("expiration_date"))
    if signed is None and expires is None:
        return "还没有签名记录"
    if expires is not None and expires - now <= DUE_BEFORE_EXPIRY:
        return "离到期不足 48 小时"
    if signed is not None and now - signed >= DUE_AFTER:
        return "距上次签名满 5 天"
    return ""


def alert_due(state: Mapping[str, Any], now: datetime) -> bool:
    """第 6.5 天（或离到期不足 12 小时）仍没续上。"""
    signed = _parse_time(state.get("last_signed_at"))
    expires = _parse_time(state.get("expiration_date"))
    if expires is not None and expires - now <= ALERT_BEFORE_EXPIRY:
        return True
    return signed is not None and now - signed >= ALERT_AFTER


def public_status(state: Mapping[str, Any], now: datetime, *, running: bool) -> str:
    if running:
        return "running"
    if not due_reason(state, now):
        return "ok"
    return "failed" if state.get("last_result") == "failed" else "due"


def _save(state: dict[str, Any], path: Path, now: datetime, *, running: bool = False) -> dict[str, Any]:
    state["schema_version"] = SCHEMA_VERSION
    state["status"] = public_status(state, now, running=running)
    state["updated_at"] = now.isoformat()
    ensure_private_dir(path.parent)
    atomic_write_json(path, state)
    return state


# ---------------------------------------------------------------------------
# 描述文件
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Profile:
    path: Path
    uuid: str
    app_id: str
    created: datetime | None
    expires: datetime | None


def parse_profile(path: Path, runner: Runner = run_command) -> Profile | None:
    code, out = runner(["/usr/bin/security", "cms", "-D", "-i", str(path)], timeout=PROBE_TIMEOUT)
    if code != 0:
        return None
    start = out.find("<?xml")
    if start < 0:
        return None
    try:
        doc = plistlib.loads(out[start:].encode("utf-8"))
    except Exception:  # noqa: BLE001 — (c) 坏描述文件当作读不到，不让续签崩溃
        return None
    if not isinstance(doc, dict):
        return None
    raw_ents = doc.get("Entitlements")
    ents: dict[str, Any] = raw_ents if isinstance(raw_ents, dict) else {}

    def _dt(value: Any) -> datetime | None:
        if isinstance(value, datetime):
            aware = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
            return aware.astimezone(BEIJING)
        return None

    return Profile(
        path=path,
        uuid=str(doc.get("UUID") or ""),
        app_id=str(ents.get("application-identifier") or ""),
        created=_dt(doc.get("CreationDate")),
        expires=_dt(doc.get("ExpirationDate")),
    )


def cached_profiles(
    profiles_dir: Path = PROFILES_DIR,
    *,
    bundle_id: str = BUNDLE_ID,
    runner: Runner = run_command,
) -> list[Profile]:
    if not profiles_dir.is_dir():
        return []
    found: list[Profile] = []
    for item in sorted(profiles_dir.glob("*.mobileprovision")):
        prof = parse_profile(item, runner)
        if prof is not None and prof.app_id.endswith("." + bundle_id):
            found.append(prof)
    return found


def bootstrap_state(
    path: Path = STATE_PATH,
    *,
    now: datetime | None = None,
    profiles_dir: Path = PROFILES_DIR,
    runner: Runner = run_command,
) -> dict[str, Any]:
    """没有 `resign.json` 时，按本机缓存里最新的本 App 描述文件补一份签名记录。"""
    moment = (now or now_beijing()).astimezone(BEIJING)
    state = load_state(path)
    if state.get("last_signed_at"):
        return state
    profiles = [p for p in cached_profiles(profiles_dir, runner=runner) if p.expires is not None]
    if not profiles:
        return state
    newest = max(profiles, key=lambda p: p.expires or moment)
    state.update(
        {
            "last_signed_at": newest.created.isoformat() if newest.created else None,
            "expiration_date": newest.expires.isoformat() if newest.expires else None,
            "profile_uuid": newest.uuid,
            "last_result": "ok",
            "last_trigger": "bootstrap",
        }
    )
    return _save(state, path, moment)


# ---------------------------------------------------------------------------
# 守卫
# ---------------------------------------------------------------------------


def device_online(devices_doc: Any, udid: str) -> bool:
    """`devicectl list devices --json-output` 里这台手机已配对且当前能找到。"""
    try:
        devices = devices_doc["result"]["devices"]
    except (KeyError, TypeError):
        return False
    for dev in devices if isinstance(devices, list) else []:
        if not isinstance(dev, dict):
            continue
        raw_hw = dev.get("hardwareProperties")
        hw: dict[str, Any] = raw_hw if isinstance(raw_hw, dict) else {}
        if udid not in (dev.get("identifier"), hw.get("udid")):
            continue
        raw_conn = dev.get("connectionProperties")
        conn: dict[str, Any] = raw_conn if isinstance(raw_conn, dict) else {}
        return conn.get("pairingState") == "paired" and conn.get("tunnelState") not in (None, "unavailable")
    return False


def probe_device(udid: str, runner: Runner, scratch: Path) -> bool:
    out_path = scratch / "devices.json"
    code, _out = runner(
        ["/usr/bin/xcrun", "devicectl", "list", "devices", "--json-output", str(out_path)],
        timeout=PROBE_TIMEOUT,
    )
    if code != 0:
        return False
    try:
        doc = json.loads(out_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    finally:
        out_path.unlink(missing_ok=True)
    return device_online(doc, udid)


def lan_reachable(ip: str, runner: Runner = run_command) -> bool:
    """手机在家里局域网：先 ping，不回再试一下配对服务端口（锁屏时常不回 ICMP）。"""
    if not ip:
        return True
    code, _ = runner(["/sbin/ping", "-c", "1", "-t", "2", ip], timeout=5)
    if code == 0:
        return True
    try:
        with socket.create_connection((ip, LOCKDOWN_PORT), timeout=2):
            return True
    except OSError:
        return False


def check_deploy_worktree(worktree: Path, runner: Runner = run_command) -> str:
    """部署目录必须是干净的 `main`；不满足返回原因。"""
    if not (worktree / "ios" / "WadosMAAiOS.xcodeproj").is_dir():
        return f"找不到 {worktree}/ios/WadosMAAiOS.xcodeproj"
    code, out = runner(["/usr/bin/git", "-C", str(worktree), "rev-parse", "--abbrev-ref", "HEAD"], timeout=PROBE_TIMEOUT)
    if code != 0 or out.strip() != "main":
        return f"部署目录不在 main（当前 {out.strip() or '未知'}）"
    code, out = runner(
        ["/usr/bin/git", "-C", str(worktree), "status", "--porcelain", "--", "ios", "shared"],
        timeout=PROBE_TIMEOUT,
    )
    if code != 0 or out.strip():
        return "部署目录的 ios/ 或 shared/ 有未提交改动"
    return ""


def is_account_failure(log_text: str) -> bool:
    lowered = log_text.lower()
    return any(marker in lowered for marker in ACCOUNT_FAILURE_MARKERS)


def _try_lock(path: Path) -> Any:
    ensure_private_dir(path.parent)
    handle = path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def is_locked(path: Path | None = None) -> bool:
    target = path or LOCK_PATH
    if not target.exists():
        return False
    handle = _try_lock(target)
    if handle is None:
        return True
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    handle.close()
    return False


# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------


@dataclass
class Env:
    """一次续签用到的路径与外部依赖（单测全部替换）。"""

    state_path: Path = STATE_PATH
    lock_path: Path = LOCK_PATH
    config_path: Path = DAEMON_CONFIG_PATH
    log_dir: Path = LOG_DIR
    worktree: Path = DEPLOY_WORKTREE
    derived_data: Path = DERIVED_DATA
    profiles_dir: Path = PROFILES_DIR
    runner: Runner = run_command
    clock: Callable[[], datetime] = now_beijing
    run_lock_probe: Callable[[], bool] = is_run_locked
    notifier: Callable[..., bool] | None = None
    lan_probe: Callable[[str], bool] | None = None
    device_probe: Callable[[str], bool] | None = None

    def notify(self, title: str, body: str, *, level: str) -> bool:
        sender = self.notifier
        if sender is None:
            import maa_notify

            sender = maa_notify.notify
        return bool(
            sender(title, body, level=level, url="wadosmaa://resign", notification_id=NOTIFY_ID)
        )


class _Log:
    def __init__(self, directory: Path, stamp: str) -> None:
        ensure_private_dir(directory)
        self.path = directory / f"{stamp}.log"
        self.lines: list[str] = []
        self._fh = self.path.open("w", encoding="utf-8")
        olds = sorted(directory.glob("*.log"))
        for old in olds[:-LOG_KEEP]:
            old.unlink(missing_ok=True)

    def write(self, text: str) -> None:
        self._fh.write(text if text.endswith("\n") else text + "\n")
        self._fh.flush()
        self.lines.extend(line for line in text.splitlines() if line.strip())

    def summary(self, n: int = 6) -> str:
        return "\n".join(self.lines[-n:])

    def close(self) -> None:
        self._fh.close()


def _record_skip(state: dict[str, Any], env: Env, now: datetime, detail: str) -> dict[str, Any]:
    state["last_probe_at"] = now.isoformat()
    state["last_probe_detail"] = detail
    return _save(state, env.state_path, now)


def _maybe_alert(state: dict[str, Any], env: Env, now: datetime, *, reason: str, force: bool = False) -> None:
    """告警一天最多一次；`force` 用于 Apple ID / 有效期没后移这类要人处理的失败。"""
    if not force and not alert_due(state, now):
        return
    today = now.date().isoformat()
    if state.get("alerted_on") == today and state.get("alert_reason") == reason:
        return
    expires = _parse_time(state.get("expiration_date"))
    tail = f"，{expires.strftime('%m-%d %H:%M')} 到期" if expires else ""
    sent = env.notify(
        "iOS App 还没续签",
        f"{reason}{tail}。回家连上 Wi-Fi 后在 App 设置里点「立即续签」，或在 Mac 上重新登录 Xcode 账号。",
        level="timeSensitive",
    )
    if sent:
        state["alerted_on"] = today
        state["alert_reason"] = reason


def _restore(moved: list[tuple[Path, Path]]) -> None:
    for original, backup in moved:
        if backup.exists() and not original.exists():
            try:
                shutil.move(str(backup), str(original))
            except OSError:
                pass


def perform(env: Env, *, trigger: str, app_active: bool = False, force: bool = False) -> dict[str, Any]:
    """一次续签尝试；返回 `{ok, code, message}`，并始终更新 `resign.json`。"""
    now = env.clock().astimezone(BEIJING)
    cfg = load_resign_config(env.config_path)
    if not is_configured(cfg):
        return {"ok": False, "code": "not_configured", "message": "daemon.json 里还没配 iPhone 的 UDID。"}

    handle = _try_lock(env.lock_path)
    if handle is None:
        return {"ok": False, "code": "running", "message": "已经在续签了。"}
    try:
        state = load_state(env.state_path)
        if not state.get("last_signed_at") and not state.get("expiration_date"):
            state = bootstrap_state(env.state_path, now=now, profiles_dir=env.profiles_dir, runner=env.runner)
        reason = due_reason(state, now)
        if trigger == "auto" and not reason and not force:
            _save(state, env.state_path, now)
            return {"ok": True, "code": "not_due", "message": "还没到续签时间。"}

        # auto 的四个守卫：App 在用、在跑游戏、手机不在家、手机连不上。
        if trigger == "auto":
            skip = ""
            if app_active:
                skip = "App 正在使用"
            elif env.run_lock_probe():
                skip = "正在跑游戏"
            elif not (env.lan_probe or (lambda ip: lan_reachable(ip, env.runner)))(cfg["lan_ip"]):
                skip = "手机不在局域网"
            if skip:
                _maybe_alert(state, env, now, reason="一直没等到合适的时机")
                _record_skip(state, env, now, skip)
                return {"ok": False, "code": "skipped", "message": skip}
        elif env.run_lock_probe():
            return {"ok": False, "code": "run_locked", "message": "正在跑游戏，结束后会自动续签。"}

        return _build_and_install(state, env, cfg, now, trigger=trigger)
    finally:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        handle.close()


def _build_and_install(
    state: dict[str, Any],
    env: Env,
    cfg: Mapping[str, Any],
    now: datetime,
    *,
    trigger: str,
) -> dict[str, Any]:
    state["last_attempt_at"] = now.isoformat()
    state["last_trigger"] = trigger
    _save(state, env.state_path, now, running=True)
    log = _Log(env.log_dir, now.strftime("%Y%m%d-%H%M%S"))
    moved: list[tuple[Path, Path]] = []

    def finish(code: str, message: str, *, ok: bool, alert: bool = False, transient: bool = False) -> dict[str, Any]:
        moment = env.clock().astimezone(BEIJING)
        log.write(f"[{moment.isoformat()}] {code}: {message}")
        state["last_result"] = "ok" if ok else ("skipped" if transient else "failed")
        state["last_error"] = "" if ok else message
        state["log_summary"] = log.summary()
        state["log_path"] = str(log.path)
        if transient:
            state["last_probe_at"] = moment.isoformat()
            state["last_probe_detail"] = message
        if not ok:
            if alert:
                _maybe_alert(state, env, moment, reason=message, force=True)
            else:
                _maybe_alert(state, env, moment, reason="多次尝试都没成功")
        log.close()
        _save(state, env.state_path, moment)
        return {"ok": ok, "code": code, "message": message}

    try:
        problem = check_deploy_worktree(env.worktree, env.runner)
        if problem:
            return finish("worktree_invalid", problem, ok=False, alert=True)

        device_probe = env.device_probe or (lambda udid: probe_device(udid, env.runner, env.log_dir))
        if not device_probe(cfg["udid"]):
            return finish("device_offline", "找不到手机（不在家或没开 Wi-Fi）", ok=False, transient=True)

        old_profiles = cached_profiles(env.profiles_dir, runner=env.runner)
        old_expiry_candidates = [p.expires for p in old_profiles if p.expires is not None]
        recorded = _parse_time(state.get("expiration_date"))
        if recorded is not None:
            old_expiry_candidates.append(recorded)
        old_expiry = max(old_expiry_candidates) if old_expiry_candidates else None

        backup_dir = env.log_dir / "profiles-backup" / now.strftime("%Y%m%d-%H%M%S")
        for prof in old_profiles:
            ensure_private_dir(backup_dir)
            target = backup_dir / prof.path.name
            shutil.move(str(prof.path), str(target))
            moved.append((prof.path, target))
        log.write(f"挪走旧描述文件 {len(moved)} 个；旧到期 {old_expiry.isoformat() if old_expiry else '无'}")

        project = env.worktree / "ios" / "WadosMAAiOS.xcodeproj"
        build_argv = [
            "/usr/bin/xcodebuild",
            "-project", str(project),
            "-scheme", SCHEME,
            "-configuration", "Release",
            "-destination", "generic/platform=iOS",
            "-derivedDataPath", str(env.derived_data),
            "-allowProvisioningUpdates",
            "build",
        ]
        log.write("$ " + " ".join(build_argv))
        code, out = env.runner(build_argv, timeout=BUILD_TIMEOUT, cwd=env.worktree)
        log.write(out[-20000:])
        if code != 0:
            _restore(moved)
            if is_account_failure(out):
                return finish("account_failed", "Xcode 账号要重新登录", ok=False, alert=True)
            return finish("build_failed", f"构建失败（退出码 {code}）", ok=False)

        app_path = env.derived_data / APP_RELATIVE
        new_profile = parse_profile(app_path / "embedded.mobileprovision", env.runner)
        if new_profile is None or new_profile.expires is None:
            _restore(moved)
            return finish("profile_unreadable", "读不到新描述文件的有效期", ok=False, alert=True)
        log.write(f"新描述文件 {new_profile.uuid} 到期 {new_profile.expires.isoformat()}")
        if old_expiry is not None and new_profile.expires <= old_expiry:
            _restore(moved)
            return finish("not_extended", "新描述文件的有效期没有后移", ok=False, alert=True)

        install_argv = [
            "/usr/bin/xcrun", "devicectl", "device", "install", "app",
            "--device", cfg["udid"], str(app_path),
        ]
        log.write("$ " + " ".join(install_argv))
        code, out = env.runner(install_argv, timeout=INSTALL_TIMEOUT)
        log.write(out[-8000:])
        if code != 0:
            # 新描述文件已经有了，不挪回旧的；下个周期直接重装。
            return finish("install_failed", "无线安装没成功（手机可能锁屏或走开了）", ok=False, transient=True)

        moment = env.clock().astimezone(BEIJING)
        state["last_signed_at"] = moment.isoformat()
        state["expiration_date"] = new_profile.expires.isoformat()
        state["profile_uuid"] = new_profile.uuid
        state.pop("alerted_on", None)
        state.pop("alert_reason", None)
        result = finish("ok", "已续签", ok=True)
        env.notify(
            "iOS App 已自动续签",
            f"有效期至 {new_profile.expires.strftime('%m-%d %H:%M')}",
            level="passive",
        )
        return result
    except Exception as exc:  # noqa: BLE001 — (a) 续签进程顶层兜底：挪回描述文件、落盘失败原因
        _restore(moved)
        return finish("error", f"{type(exc).__name__}: {exc}", ok=False)


# ---------------------------------------------------------------------------
# 守护进程 / API 入口
# ---------------------------------------------------------------------------


def auto_should_spawn(
    state: Mapping[str, Any],
    cfg: Mapping[str, Any],
    now: datetime,
    last_check: datetime | None,
) -> bool:
    """守护进程每拍调用：配置好了、到窗口了、距上次检查满 25 分钟。"""
    if not is_configured(cfg):
        return False
    if last_check is not None and now - last_check < CHECK_INTERVAL:
        return False
    return bool(due_reason(state, now))


def spawn_argv(scripts_dir: Path, python_bin: str, *args: str) -> list[str]:
    return [python_bin, str(scripts_dir / "maa_ios_resign.py"), *args]


def default_spawn(argv: list[str]) -> Any:
    return subprocess.Popen(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def request_resign(
    *,
    if_due: bool,
    trigger: str,
    daemon_dir: Path,
    scripts_dir: Path,
    python_bin: str,
    now: datetime | None = None,
    spawner: Callable[[list[str]], Any] = default_spawn,
    run_lock_probe: Callable[[], bool] = is_run_locked,
) -> tuple[int, dict[str, Any]]:
    """`POST /api/v1/ios/resign`：判断后在后台拉起 `run`，立即返回。"""
    moment = (now or now_beijing()).astimezone(BEIJING)
    cfg = load_resign_config(daemon_dir / "daemon.json")
    state = load_state(daemon_dir / "resign.json")
    data = {
        "if_due": if_due,
        "configured": is_configured(cfg),
        "status": public_status(state, moment, running=is_locked(daemon_dir / "resign.lock")),
        "expiration_date": state.get("expiration_date"),
    }
    if not is_configured(cfg):
        return 501, {
            "ok": False,
            "code": "not_configured",
            "message": "Mac 上还没配好要续签的 iPhone。",
            "data": data,
        }
    if if_due and not due_reason(state, moment):
        return 200, {"ok": True, "code": "not_due", "message": "还没到续签时间。", "data": data}
    if data["status"] == "running":
        return 409, {"ok": False, "code": "running", "message": "已经在续签了。", "data": data}
    if run_lock_probe():
        return 409, {"ok": False, "code": "run_locked", "message": "正在跑游戏，结束后会自动续签。", "data": data}
    spawner(spawn_argv(scripts_dir, python_bin, "run", "--trigger", trigger))
    return 202, {"ok": True, "code": "started", "message": "开始续签。装新版时 App 会退出，几分钟后重新打开就行。", "data": data}


# ---------------------------------------------------------------------------
# 命令行
# ---------------------------------------------------------------------------


def _print(doc: Mapping[str, Any]) -> None:
    print(json.dumps(doc, ensure_ascii=False, indent=2, default=str))


def _shortcut_token(daemon_dir: Path) -> dict[str, Any]:
    import maa_tls

    token = maa_tls.generate_token()
    maa_tls.merge_secrets(daemon_dir / "secrets.json", {"resign_only_token_sha256": maa_tls.hash_token(token)})
    return {"ok": True, "resign_only_token": token, "note": "只显示这一次；旧的快捷指令 Token 已失效。"}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="iOS App 无线自动续签")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_auto = sub.add_parser("auto", help="守护进程定时调用")
    p_auto.add_argument("--app-active", action="store_true")
    p_run = sub.add_parser("run", help="立即续签（App 按钮 / 快捷指令）")
    p_run.add_argument("--trigger", choices=TRIGGERS, default="cli")
    sub.add_parser("status", help="看签名状态")
    sub.add_parser("bootstrap", help="按本机缓存的描述文件补签名记录")
    sub.add_parser("shortcut-token", help="给快捷指令重新生成 resign_only Token")
    args = parser.parse_args(argv)

    env = Env()
    if args.cmd == "auto":
        _print(perform(env, trigger="auto", app_active=args.app_active))
        return 0
    if args.cmd == "run":
        res = perform(env, trigger=args.trigger)
        _print(res)
        return 0 if res.get("ok") else 1
    if args.cmd == "status":
        state = load_state()
        moment = now_beijing()
        _print(
            {
                **state,
                "status": public_status(state, moment, running=is_locked()),
                "due_reason": due_reason(state, moment),
                "configured": is_configured(load_resign_config()),
            }
        )
        return 0
    if args.cmd == "bootstrap":
        _print(bootstrap_state())
        return 0
    if args.cmd == "shortcut-token":
        _print(_shortcut_token(DAEMON_DIR))
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
