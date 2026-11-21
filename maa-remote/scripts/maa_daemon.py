#!/usr/bin/env python3
"""Wado's MAA 独立内置调度器与守护进程骨架（Phase 1 S1-5）。

职责（Phase 1）：
1. 6 条内置调度任务（全程 `Asia/Shanghai` 北京时间，零 UTC 换算）：
   - `plan_card_am`（`am.time - 10m`）
   - `daily_am`（`am.time`）
   - `plan_card_pm`（`pm.time - 10m`）
   - `daily_pm`（`pm.time`）
   - `depot`（`04:30`，受 `daemon/daemon.json` 的 `depot_enabled` 控制，默认 `false`）
   - `activity_watch`（每 15 分钟 `:00/:15/:30/:45`）
2. 同日 2 小时补跑硬规则：
   - 错过一次性日槽位时，必须同时满足：① 距计划时刻 ≤ 2 小时；② 同一北京自然日；
     ③ 未进入其他开启场次的 `manual_run_blackout_minutes` 保护窗；
   - 同场 `plan_card_*` 与 `daily_*` 均待补跑时严格串行（先 `plan_card_*` 后 `daily_*`）；
   - 超时/跨日/挤窗记 `missed`；`activity_watch` 只跑当前槽位，不补历史槽位。
3. 进程隔离与超时语义：
   - 子进程一律 `start_new_session=True`，重启守护进程绝不杀运行中业务进程；
   - 防重入以 `run.lock` / `activity_watch.lock` 为准；
   - 3600s（1 小时）硬超时仅适用于日常场（`daily_am` / `daily_pm` / `now`），绝不用于抄作业；
   - 日常超时先发 `SIGINT` 触发 #64 `interrupt_once()` 优雅收尾，宽限 90s 后才 `SIGKILL`。
4. 响应 `SIGHUP` 与 `daemon/reload.flag` 热重载配置与调度表。
"""

from __future__ import annotations

import fcntl
import json
import os
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Mapping

import maa_api
import maa_tls
from maa_common import (
    BEIJING,
    DAEMON_DIR,
    DEFAULT_MANUAL_RUN_BLACKOUT_MINUTES,
    PLAN_CARD_LEAD_MINUTES,
    RUN_LOCK_PATH,
    SCRIPTS_DIR,
    STATE_DIR,
    atomic_write_json,
    atomic_write_text,
    ensure_private_dir,
    is_run_locked,
    load_config,
    load_json,
    now_beijing,
    session_schedule,
)

SCHEDULER_STATE_PATH = DAEMON_DIR / "scheduler.json"
DAEMON_CONFIG_PATH = DAEMON_DIR / "daemon.json"
DAEMON_PID_PATH = DAEMON_DIR / "daemon.pid"
ACTIVE_TLS_PATH = DAEMON_DIR / "active_tls.json"
RELOAD_FLAG_PATH = DAEMON_DIR / "reload.flag"
WATCH_LOCK_PATH = STATE_DIR / "activity_watch.lock"

SCHEDULER_SCHEMA_VERSION = 1
CATCHUP_WINDOW = timedelta(hours=2)
DEPOT_TIME = (4, 30)
ACTIVITY_WATCH_INTERVAL_MINUTES = 15

# 硬超时仅适用于日常场（daily_am / daily_pm / now），绝不用于抄作业 worker。
DAILY_HARD_TIMEOUT_SECONDS = 3600
DAILY_TIMEOUT_GRACE_SECONDS = 90
DAILY_TIMEOUT_JOBS = frozenset({"daily_am", "daily_pm", "now"})
RUN_LOCKED_JOBS = frozenset({"plan_card_am", "daily_am", "plan_card_pm", "daily_pm", "depot"})

JOB_ORDER = (
    "plan_card_am",
    "daily_am",
    "plan_card_pm",
    "daily_pm",
    "depot",
    "activity_watch",
)


def default_daemon_config() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "notify_backend": "none",
        "bark_base_url": "https://api.day.app",
        "bark_icon_url": "",
        "depot_enabled": False,
        "api_enabled": True,
        "api_host": "0.0.0.0",
        "api_port": 18170,
        "lan_ip": "192.168.50.2",
        "remote_url": "https://maa.luxraykit.com",
        "allowed_cidrs": list(maa_api.DEFAULT_ALLOWED_CIDRS),
        "tls_cert_path": "",
        "tls_key_path": "",
        "tls_handshake_timeout": maa_api.DEFAULT_HANDSHAKE_TIMEOUT,
        "tls_warn_days": maa_tls.DEFAULT_WARN_DAYS,
        "sse_keepalive_seconds": maa_api.DEFAULT_SSE_KEEPALIVE_SECONDS,
    }


def load_daemon_config(path: Path | None = None) -> dict[str, Any]:
    target = path or DAEMON_CONFIG_PATH
    raw = load_json(target, {})
    merged = default_daemon_config()
    if isinstance(raw, dict):
        merged.update(raw)
    merged["depot_enabled"] = bool(merged.get("depot_enabled", False))
    return merged


def is_watch_locked(lock_path: Path | None = None) -> bool:
    """探测 `activity_watch.lock` 是否正被占用（非阻塞）。"""
    path = lock_path or WATCH_LOCK_PATH
    if not path.exists():
        return False
    try:
        with path.open("a+", encoding="utf-8") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return False
    except OSError:
        return False


def _parse_hhmm(hhmm: str) -> tuple[int, int]:
    hour_s, minute_s = hhmm.split(":")
    return int(hour_s), int(minute_s)


def job_argv(job_key: str, *, scripts_dir: Path | None = None, python_bin: str | None = None) -> list[str]:
    scripts = scripts_dir or SCRIPTS_DIR
    py = python_bin or sys.executable
    mapping: dict[str, list[str]] = {
        "plan_card_am": [py, str(scripts / "maa_plan_card.py"), "am"],
        "daily_am": [py, str(scripts / "maa_daily.py"), "am"],
        "plan_card_pm": [py, str(scripts / "maa_plan_card.py"), "pm"],
        "daily_pm": [py, str(scripts / "maa_daily.py"), "pm"],
        "depot": [py, str(scripts / "maa_depot.py")],
        "activity_watch": [py, str(scripts / "maa_activity_watch.py")],
    }
    if job_key not in mapping:
        raise ValueError(f"未知调度任务：{job_key}")
    return mapping[job_key]


def today_slot_for(
    job_key: str,
    config: Mapping[str, Any],
    daemon_cfg: Mapping[str, Any],
    now: datetime,
) -> tuple[bool, datetime | None]:
    """返回 `(是否启用, 当天或当前周期的计划时刻)`（全部北京时区）。"""
    moment = now.astimezone(BEIJING)
    schedule = session_schedule(config)
    if job_key in ("plan_card_am", "daily_am"):
        slot = schedule["am"]
        enabled = bool(slot["enabled"])
        hour, minute = _parse_hhmm(str(slot["time"]))
        target = moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if job_key == "plan_card_am":
            target -= timedelta(minutes=PLAN_CARD_LEAD_MINUTES)
        return enabled, target
    if job_key in ("plan_card_pm", "daily_pm"):
        slot = schedule["pm"]
        enabled = bool(slot["enabled"])
        hour, minute = _parse_hhmm(str(slot["time"]))
        target = moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if job_key == "plan_card_pm":
            target -= timedelta(minutes=PLAN_CARD_LEAD_MINUTES)
        return enabled, target
    if job_key == "depot":
        enabled = bool(daemon_cfg.get("depot_enabled", False))
        target = moment.replace(hour=DEPOT_TIME[0], minute=DEPOT_TIME[1], second=0, microsecond=0)
        return enabled, target
    if job_key == "activity_watch":
        floored = (moment.minute // ACTIVITY_WATCH_INTERVAL_MINUTES) * ACTIVITY_WATCH_INTERVAL_MINUTES
        target = moment.replace(minute=floored, second=0, microsecond=0)
        return True, target
    raise ValueError(f"未知调度任务：{job_key}")


def next_run_for(
    job_key: str,
    config: Mapping[str, Any],
    daemon_cfg: Mapping[str, Any],
    now: datetime,
    last_slot: str = "",
) -> datetime | None:
    """计算下一次计划触发时间（供 `scheduler.json` 和 `schedule show` 展示）。"""
    moment = now.astimezone(BEIJING)
    enabled, current = today_slot_for(job_key, config, daemon_cfg, moment)
    if not enabled or current is None:
        return None
    if job_key == "activity_watch":
        current_key = current.strftime("%Y-%m-%dT%H:%M")
        if last_slot == current_key or moment > current:
            return current + timedelta(minutes=ACTIVITY_WATCH_INTERVAL_MINUTES)
        return current
    current_key = current.strftime("%Y-%m-%dT%H:%M")
    if moment <= current and last_slot != current_key:
        return current
    # 下一个自然日的同一槽位
    tomorrow = (moment + timedelta(days=1)).replace(hour=12, minute=0, second=0, microsecond=0)
    _en, nxt = today_slot_for(job_key, config, daemon_cfg, tomorrow)
    return nxt


def _in_other_session_blackout(job_key: str, config: Mapping[str, Any], now: datetime) -> bool:
    """是否已进入「另一场」的 `manual_run_blackout_minutes` 保护窗口。"""
    moment = now.astimezone(BEIJING)
    blackout = max(0, int(config.get("manual_run_blackout_minutes", DEFAULT_MANUAL_RUN_BLACKOUT_MINUTES)))
    if blackout <= 0:
        return False
    own_phase = "am" if job_key.endswith("_am") else "pm" if job_key.endswith("_pm") else ""
    schedule = session_schedule(config)
    for phase, slot in schedule.items():
        if phase == own_phase or not slot.get("enabled"):
            continue
        hour, minute = _parse_hhmm(str(slot["time"]))
        target = moment.replace(hour=hour, minute=minute, second=0, microsecond=0)
        if target < moment:
            target += timedelta(days=1)
        delta_minutes = (target - moment).total_seconds() / 60.0
        if 0 <= delta_minutes <= blackout:
            return True
    return False


def evaluate_catchup(
    job_key: str,
    scheduled: datetime,
    now: datetime,
    config: Mapping[str, Any],
) -> tuple[str, str]:
    """评估已过点的一次性日槽位：返回 `("run"|"missed", 原因)`。

    三条硬规则：
    1. 距计划时刻 ≤ 2 小时；
    2. 同一北京自然日（`now.date() == scheduled.date()`）；
    3. 未进入其他开启场次的 `manual_run_blackout_minutes` 保护窗。
    """
    moment = now.astimezone(BEIJING)
    sched = scheduled.astimezone(BEIJING)
    if moment.date() != sched.date():
        return "missed", "跨北京自然日，不补跑"
    elapsed = moment - sched
    if elapsed < timedelta(0):
        return "wait", ""
    if elapsed > CATCHUP_WINDOW:
        return "missed", f"已错过超过 {int(CATCHUP_WINDOW.total_seconds() // 3600)} 小时，不补跑"
    if _in_other_session_blackout(job_key, config, moment):
        return "missed", "已进入下一场保护窗口，不补跑"
    if elapsed > timedelta(minutes=1):
        return "run", f"同日补跑（迟到 {int(elapsed.total_seconds() // 60)} 分钟）"
    return "run", "准点触发"


@dataclass
class TrackedProcess:
    job_key: str
    slot_key: str
    proc: Any
    started_at: datetime
    sigint_sent_at: datetime | None = None
    killed: bool = False


@dataclass
class SchedulerState:
    jobs: dict[str, dict[str, Any]] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> SchedulerState:
        raw = load_json(path, {})
        jobs = raw.get("jobs") if isinstance(raw, dict) else {}
        return cls(jobs=dict(jobs) if isinstance(jobs, dict) else {})

    def entry(self, job_key: str) -> dict[str, Any]:
        return self.jobs.setdefault(job_key, {})

    def save(
        self,
        path: Path,
        config: Mapping[str, Any],
        daemon_cfg: Mapping[str, Any],
        now: datetime,
    ) -> None:
        out_jobs: dict[str, dict[str, Any]] = {}
        for key in JOB_ORDER:
            item = dict(self.jobs.get(key) or {})
            enabled, _cur = today_slot_for(key, config, daemon_cfg, now)
            nxt = next_run_for(key, config, daemon_cfg, now, str(item.get("last_slot") or ""))
            item["enabled"] = enabled
            item["next_run_at"] = nxt.isoformat() if nxt is not None else None
            out_jobs[key] = item
        doc = {
            "schema_version": SCHEDULER_SCHEMA_VERSION,
            "timezone": "Asia/Shanghai",
            "updated_at": now.astimezone(BEIJING).isoformat(),
            "depot_enabled": bool(daemon_cfg.get("depot_enabled", False)),
            "jobs": out_jobs,
        }
        atomic_write_json(path, doc)


class DaemonScheduler:
    """内置调度器与子进程生命周期管理器（纯 stdlib，支持完全离线单测）。"""

    def __init__(
        self,
        *,
        state_path: Path | None = None,
        daemon_config_path: Path | None = None,
        scripts_dir: Path | None = None,
        python_bin: str | None = None,
        clock: Callable[[], datetime] = now_beijing,
        config_loader: Callable[[], Mapping[str, Any]] = load_config,
        run_lock_probe: Callable[[], bool] = is_run_locked,
        watch_lock_probe: Callable[[], bool] = is_watch_locked,
        spawner: Callable[[list[str]], Any] | None = None,
        signaler: Callable[[int, int], None] = os.kill,
    ) -> None:
        self.state_path = state_path or SCHEDULER_STATE_PATH
        self.daemon_config_path = daemon_config_path or DAEMON_CONFIG_PATH
        self.scripts_dir = scripts_dir or SCRIPTS_DIR
        self.python_bin = python_bin or sys.executable
        self.clock = clock
        self.config_loader = config_loader
        self.run_lock_probe = run_lock_probe
        self.watch_lock_probe = watch_lock_probe
        self.spawner = spawner or self._default_spawn
        self.signaler = signaler
        self.state = SchedulerState.load(self.state_path)
        self.active: dict[str, TrackedProcess] = {}

    @staticmethod
    def _default_spawn(argv: list[str]) -> subprocess.Popen[bytes]:
        # 所有业务子进程脱离守护进程会话，确保重启守护进程不杀运行中任务（#62）。
        return subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )

    def _poll_active(self, now: datetime) -> None:
        for job_key in list(self.active):
            tracked = self.active[job_key]
            code = tracked.proc.poll()
            if code is not None:
                entry = self.state.entry(job_key)
                entry["last_finished_at"] = now.isoformat()
                entry["last_exit_code"] = int(code)
                if tracked.sigint_sent_at is not None:
                    entry["last_status"] = "timeout"
                    entry["last_detail"] = "日常超时已停止"
                else:
                    entry["last_status"] = "ok" if code == 0 else "failed"
                    entry["last_detail"] = "" if code == 0 else f"退出码 {code}"
                self.active.pop(job_key, None)
                continue

            # 1 小时硬超时仅适用于日常场，绝不用于抄作业或其他任务。
            if job_key not in DAILY_TIMEOUT_JOBS:
                continue
            elapsed = (now - tracked.started_at).total_seconds()
            if tracked.sigint_sent_at is None and elapsed >= DAILY_HARD_TIMEOUT_SECONDS:
                tracked.sigint_sent_at = now
                try:
                    self.signaler(tracked.proc.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
                entry = self.state.entry(job_key)
                entry["last_status"] = "timeout_stopping"
                entry["last_detail"] = f"已达 {DAILY_HARD_TIMEOUT_SECONDS}s 上限，已发 SIGINT 优雅收尾"
            elif (
                tracked.sigint_sent_at is not None
                and not tracked.killed
                and (now - tracked.sigint_sent_at).total_seconds() >= DAILY_TIMEOUT_GRACE_SECONDS
            ):
                tracked.killed = True
                try:
                    self.signaler(tracked.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                entry = self.state.entry(job_key)
                entry["last_status"] = "timeout_killed"
                entry["last_detail"] = f"宽限 {DAILY_TIMEOUT_GRACE_SECONDS}s 后未退出，已 SIGKILL"

    def _is_busy_for(self, job_key: str) -> bool:
        if job_key in self.active:
            return True
        if job_key == "activity_watch":
            return self.watch_lock_probe()
        if job_key in RUN_LOCKED_JOBS:
            # 只要已有同组任务被守护进程跟踪或在外部持有 run.lock，绝不重入。
            if any(k in RUN_LOCKED_JOBS for k in self.active):
                return True
            return self.run_lock_probe()
        return False

    def _dispatch(self, job_key: str, slot_key: str, reason: str, now: datetime) -> None:
        argv = job_argv(job_key, scripts_dir=self.scripts_dir, python_bin=self.python_bin)
        proc = self.spawner(argv)
        self.active[job_key] = TrackedProcess(
            job_key=job_key,
            slot_key=slot_key,
            proc=proc,
            started_at=now,
        )
        entry = self.state.entry(job_key)
        entry["last_slot"] = slot_key
        entry["last_run_at"] = now.isoformat()
        entry["last_status"] = "running"
        entry["last_detail"] = reason
        entry["pid"] = getattr(proc, "pid", None)

    def tick(self) -> list[str]:
        """执行一拍调度，返回本拍新启动的任务 key 列表。"""
        now = self.clock().astimezone(BEIJING)
        config = self.config_loader()
        daemon_cfg = load_daemon_config(self.daemon_config_path)

        self._poll_active(now)
        launched: list[str] = []

        # 1. 先检查一次性日槽位（按 JOB_ORDER：确保同场 plan_card_* 严格排在 daily_* 之前）。
        pending_plan_cards: set[str] = set()
        for job_key in ("plan_card_am", "daily_am", "plan_card_pm", "daily_pm", "depot"):
            enabled, scheduled = today_slot_for(job_key, config, daemon_cfg, now)
            if not enabled or scheduled is None:
                continue
            slot_key = scheduled.strftime("%Y-%m-%dT%H:%M")
            entry = self.state.entry(job_key)
            if entry.get("last_slot") == slot_key:
                continue
            if now < scheduled:
                continue
            decision, reason = evaluate_catchup(job_key, scheduled, now, config)
            if decision == "missed":
                entry["last_slot"] = slot_key
                entry["last_status"] = "missed"
                entry["last_detail"] = reason
                entry["missed_at"] = now.isoformat()
                continue
            if decision != "run":
                continue

            # 同场串行约束：plan_card_* 正在跑或本拍刚待跑，daily_* 必须等待。
            if job_key == "daily_am" and (
                "plan_card_am" in pending_plan_cards or "plan_card_am" in self.active
            ):
                continue
            if job_key == "daily_pm" and (
                "plan_card_pm" in pending_plan_cards or "plan_card_pm" in self.active
            ):
                continue

            if self._is_busy_for(job_key):
                if job_key in ("plan_card_am", "plan_card_pm"):
                    pending_plan_cards.add(job_key)
                continue

            self._dispatch(job_key, slot_key, reason, now)
            launched.append(job_key)
            if job_key in ("plan_card_am", "plan_card_pm"):
                pending_plan_cards.add(job_key)

        # 2. 周期任务 activity_watch：只跑当前 15 分钟槽位，不补历史槽位。
        enabled, watch_slot = today_slot_for("activity_watch", config, daemon_cfg, now)
        if enabled and watch_slot is not None:
            watch_key = watch_slot.strftime("%Y-%m-%dT%H:%M")
            entry = self.state.entry("activity_watch")
            if entry.get("last_slot") != watch_key and not self._is_busy_for("activity_watch"):
                self._dispatch("activity_watch", watch_key, "周期触发", now)
                launched.append("activity_watch")

        self.state.save(self.state_path, config, daemon_cfg, now)
        return launched

    def reload(self) -> None:
        """热重载：立即按最新配置刷新 `scheduler.json` 中的下次触发时间。"""
        now = self.clock().astimezone(BEIJING)
        config = self.config_loader()
        daemon_cfg = load_daemon_config(self.daemon_config_path)
        self.state.save(self.state_path, config, daemon_cfg, now)


def _resolve_tls_paths(daemon_cfg: Mapping[str, Any]) -> tuple[Path, Path]:
    raw_cert = str(daemon_cfg.get("tls_cert_path") or "").strip()
    raw_key = str(daemon_cfg.get("tls_key_path") or "").strip()
    cert_path = Path(raw_cert).expanduser() if raw_cert else DAEMON_DIR / "tls" / "cert.pem"
    key_path = Path(raw_key).expanduser() if raw_key else DAEMON_DIR / "tls" / "key.pem"
    return cert_path, key_path


def _write_active_tls(info: Mapping[str, Any] | None) -> None:
    if not info:
        return
    doc = {"schema_version": 1, "pid": os.getpid(), **dict(info)}
    atomic_write_json(ACTIVE_TLS_PATH, doc)
    os.chmod(ACTIVE_TLS_PATH, 0o600)


def _clear_active_tls_if_mine() -> None:
    try:
        raw = load_json(ACTIVE_TLS_PATH, {})
        if isinstance(raw, dict) and raw.get("pid") == os.getpid():
            ACTIVE_TLS_PATH.unlink(missing_ok=True)
    except OSError:
        pass


class AsyncCertMonitor:
    """非阻塞后台 TLS 到期巡检器：防止网络推送超时阻塞调度主循环，且同一时刻最多跑一轮。"""

    def __init__(self, checker: Callable[..., dict[str, Any]] = maa_tls.check_cert_expiry_and_notify) -> None:
        self._checker = checker
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None

    def trigger(
        self,
        cert_path: Path,
        state_path: Path,
        *,
        warn_days: int,
        served_info: Mapping[str, Any] | None = None,
    ) -> bool:
        with self._lock:
            if self._running:
                return False
            self._running = True

        def _worker() -> None:
            try:
                self._checker(
                    cert_path,
                    state_path,
                    warn_days=warn_days,
                    served_info=served_info,
                )
            except Exception as exc:  # noqa: BLE001 — (c) 后台 TLS 巡检异常不阻断调度主循环
                print(f"tls cert check failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            finally:
                with self._lock:
                    self._running = False

        t = threading.Thread(target=_worker, name="wados-tls-check", daemon=True)
        self._thread = t
        t.start()
        return True

    def wait(self, timeout: float = 2.0) -> None:
        t = self._thread
        if t is not None and t.ident is not None:
            t.join(timeout=timeout)


def run_forever(*, poll_interval: float = 10.0, enable_api: bool = True) -> int:
    ensure_private_dir(DAEMON_DIR)
    atomic_write_text(DAEMON_PID_PATH, f"{os.getpid()}\n", mode=0o600)
    scheduler = DaemonScheduler()
    cert_monitor = AsyncCertMonitor()
    stop_flag = False
    reload_flag = False
    api_server: maa_api.SafeTLSThreadingHTTPServer | None = None
    api_thread: threading.Thread | None = None

    def _on_stop(_signum: int, _frame: object) -> None:
        nonlocal stop_flag
        stop_flag = True

    def _on_reload(_signum: int, _frame: object) -> None:
        nonlocal reload_flag
        reload_flag = True

    signal.signal(signal.SIGTERM, _on_stop)
    signal.signal(signal.SIGINT, _on_stop)
    signal.signal(signal.SIGHUP, _on_reload)

    daemon_cfg = load_daemon_config(DAEMON_CONFIG_PATH)
    cert_path, key_path = _resolve_tls_paths(daemon_cfg)
    if enable_api and bool(daemon_cfg.get("api_enabled", True)):
        if cert_path.is_file() and key_path.is_file():
            try:
                allowed = daemon_cfg.get("allowed_cidrs")
                allowed_cidrs = (
                    tuple(str(item) for item in allowed)
                    if isinstance(allowed, list) and allowed
                    else maa_api.DEFAULT_ALLOWED_CIDRS
                )
                ctx = maa_api.APIContext.from_default_paths(
                    allowed_cidrs=allowed_cidrs,
                    handshake_timeout=float(daemon_cfg.get("tls_handshake_timeout", maa_api.DEFAULT_HANDSHAKE_TIMEOUT)),
                    sse_keepalive_seconds=float(
                        daemon_cfg.get("sse_keepalive_seconds", maa_api.DEFAULT_SSE_KEEPALIVE_SECONDS)
                    ),
                    on_schedule_reload=scheduler.reload,
                )
                api_host = str(daemon_cfg.get("api_host") or "0.0.0.0")
                api_port = int(daemon_cfg.get("api_port") or 18170)
                api_server = maa_api.create_server(
                    api_host,
                    api_port,
                    ctx,
                    cert_path=cert_path,
                    key_path=key_path,
                )
                api_thread = threading.Thread(
                    target=api_server.serve_forever,
                    name="wados-maa-api",
                    daemon=True,
                )
                api_thread.start()
                _write_active_tls(api_server.get_active_cert_info())
                print(
                    f"wados-maa-api listening on https://{api_host}:{api_port} cert={cert_path}",
                    flush=True,
                )
            except Exception as exc:  # noqa: BLE001 — (a) API 启动异常不阻断内置调度器运行
                print(
                    f"wados-maa-api failed to start: {type(exc).__name__}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                api_server = None
        else:
            print(
                f"wados-maa-api skipped: TLS cert/key not found ({cert_path}); run daemon/init_daemon.py first",
                file=sys.stderr,
                flush=True,
            )

    print(
        f"wados-maa-daemon started pid={os.getpid()} lock={RUN_LOCK_PATH}",
        flush=True,
    )
    try:
        while not stop_flag:
            if reload_flag or RELOAD_FLAG_PATH.is_file():
                reload_flag = False
                try:
                    RELOAD_FLAG_PATH.unlink(missing_ok=True)
                except OSError:
                    pass
                try:
                    scheduler.reload()
                    if api_server is not None:
                        cur_cfg = load_daemon_config(DAEMON_CONFIG_PATH)
                        cur_cert, cur_key = _resolve_tls_paths(cur_cfg)
                        if cur_cert.is_file() and cur_key.is_file():
                            meta = api_server.reload_tls(cur_cert, cur_key)
                            _write_active_tls(meta)
                            print(f"wados-maa-api reloaded TLS spki={meta.get('spki_sha256')}", flush=True)
                        api_server.sse_hub.notify_changed()
                    print("wados-maa-daemon reloaded schedule", flush=True)
                except Exception as exc:  # noqa: BLE001 — (a) 守护进程顶层兜底，重载异常不退出
                    print(f"reload failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            try:
                scheduler.tick()
            except Exception as exc:  # noqa: BLE001 — (a) 守护进程顶层兜底，单拍异常不退出
                print(f"scheduler tick failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            try:
                cur_cfg = load_daemon_config(DAEMON_CONFIG_PATH)
                cur_cert, _cur_key = _resolve_tls_paths(cur_cfg)
                served_info = api_server.get_active_cert_info() if api_server is not None else None
                if served_info is not None or cur_cert.is_file():
                    cert_monitor.trigger(
                        cur_cert,
                        DAEMON_DIR / "tls_check.json",
                        warn_days=int(cur_cfg.get("tls_warn_days", maa_tls.DEFAULT_WARN_DAYS)),
                        served_info=served_info,
                    )
            except Exception as exc:  # noqa: BLE001 — (c) 每日 TLS 到期巡检派发异常不阻断调度循环
                print(f"tls cert check dispatch failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            # 短步进睡眠，保证 SIGHUP/SIGTERM 1 秒内响应。
            deadline = time.monotonic() + max(1.0, poll_interval)
            while not stop_flag and not reload_flag and time.monotonic() < deadline:
                if RELOAD_FLAG_PATH.is_file():
                    break
                time.sleep(min(1.0, max(0.1, deadline - time.monotonic())))
    finally:
        if api_server is not None:
            try:
                api_server.shutdown()
                api_server.server_close()
            except Exception as exc:  # noqa: BLE001 — (b) 关闭 API 服务端清理路径
                print(f"api shutdown warning: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        if api_thread is not None:
            api_thread.join(timeout=3.0)
        _clear_active_tls_if_mine()
        # 优雅退出守护进程时绝不杀运行中的业务子进程（已 start_new_session=True）。
        try:
            if DAEMON_PID_PATH.is_file() and DAEMON_PID_PATH.read_text(encoding="utf-8").strip() == str(os.getpid()):
                DAEMON_PID_PATH.unlink(missing_ok=True)
        except OSError:
            pass
        print("wados-maa-daemon stopped", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--once"]:
        scheduler = DaemonScheduler()
        launched = scheduler.tick()
        print(json.dumps({"ok": True, "launched": launched}, ensure_ascii=False))
        return 0
    if args == ["--no-api"]:
        return run_forever(enable_api=False)
    return run_forever()


if __name__ == "__main__":
    raise SystemExit(main())
