#!/usr/bin/env python3
"""早晚场时间、仓库对表开关与内置调度器同步（Phase 1 S1-5，替代 `hermes cron`）。

职责：
1. `config.session_schedule` 是早晚场时间与开关的唯一真值，全程使用 `Asia/Shanghai` 北京时间；
2. `daemon/daemon.json` 的 `depot_enabled`（默认 `false`）控制 04:30 仓库对表；
3. 读取 `daemon/scheduler.json` 组合 `schedule_report()`，供 Mac GUI / iOS App / CLI 消费；
4. 配置变更时通过 `SIGHUP` + `daemon/reload.flag` 通知 `wados-maa-daemon` 立即热重载，
   不再调用 `hermes cron` CLI。
"""

from __future__ import annotations

import os
import signal
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Mapping

import maa_daemon
from maa_common import (
    BEIJING,
    DAEMON_DIR,
    PLAN_CARD_LEAD_MINUTES,
    PLAN_PHASES,
    atomic_write_json,
    atomic_write_text,
    ensure_private_dir,
    load_json,
    now_beijing,
    session_schedule,
    state_lock,
)

# 场次任务：脚本名 → 相对开跑时间的偏移（分钟）。
SESSION_SCRIPTS = {"maa_plan_card.py": -PLAN_CARD_LEAD_MINUTES, "maa_daily.py": 0}
SCRIPT_NAMES = {"maa_plan_card.py": "计划卡", "maa_daily.py": "日常"}


def scheduler_state_path() -> Path:
    return DAEMON_DIR / "scheduler.json"


def daemon_config_path() -> Path:
    return DAEMON_DIR / "daemon.json"


def daemon_pid_path() -> Path:
    return DAEMON_DIR / "daemon.pid"


def reload_flag_path() -> Path:
    return DAEMON_DIR / "reload.flag"


def _shift_hhmm(hhmm: str, offset_minutes: int, at: datetime | None = None) -> str:
    hour, minute = (int(part) for part in hhmm.split(":"))
    day = (at or now_beijing()).astimezone(BEIJING)
    shifted = day.replace(hour=hour, minute=minute, second=0, microsecond=0) + timedelta(
        minutes=offset_minutes
    )
    return f"{shifted.hour:02d}:{shifted.minute:02d}"


def _is_daemon_pid(pid: int) -> bool:
    try:
        result = subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    if result.returncode != 0:
        return False
    return any(Path(part).name == "maa_daemon.py" for part in result.stdout.strip().split())


def notify_daemon_reload() -> bool:
    """触发内置调度器热重载：落 `reload.flag` 并向已核对的 `maa_daemon.py` 发 `SIGHUP`。

    守护进程未运行时不报错，下次启动自然读取最新配置。返回是否成功发送了信号。
    """
    ensure_private_dir(DAEMON_DIR)
    atomic_write_text(reload_flag_path(), now_beijing().isoformat() + "\n", mode=0o600)
    pid_file = daemon_pid_path()
    if not pid_file.is_file():
        return False
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return False
    if pid <= 1 or not _is_daemon_pid(pid):
        return False
    try:
        os.kill(pid, signal.SIGHUP)
        return True
    except OSError:
        return False


def set_depot_enabled(enabled: bool) -> dict[str, Any]:
    """写 `daemon/daemon.json` 的 `depot_enabled` 并通知内置调度器热重载。"""
    path = daemon_config_path()
    with state_lock():
        cfg = maa_daemon.load_daemon_config(path)
        cfg["depot_enabled"] = bool(enabled)
        atomic_write_json(path, cfg)
    notify_daemon_reload()
    return cfg


def schedule_report(config: Mapping[str, Any], at: datetime | None = None) -> dict[str, Any]:
    """`schedule show` 的新返回结构（供 Mac GUI / iOS App 消费，不再依赖 Hermes cron）。"""
    moment = (at or now_beijing()).astimezone(BEIJING)
    daemon_cfg = maa_daemon.load_daemon_config(daemon_config_path())
    raw_state = load_json(scheduler_state_path(), {})
    state_jobs = raw_state.get("jobs") if isinstance(raw_state, dict) else {}
    if not isinstance(state_jobs, dict):
        state_jobs = {}

    depot_enabled = bool(daemon_cfg.get("depot_enabled", False))
    sched_path = str(scheduler_state_path())

    jobs_summary: dict[str, dict[str, Any]] = {}
    for key in maa_daemon.JOB_ORDER:
        raw_recorded = state_jobs.get(key)
        recorded: dict[str, Any] = raw_recorded if isinstance(raw_recorded, dict) else {}
        enabled, _cur = maa_daemon.today_slot_for(key, config, daemon_cfg, moment)
        nxt = maa_daemon.next_run_for(
            key, config, daemon_cfg, moment, str(recorded.get("last_slot") or "")
        )
        jobs_summary[key] = {
            "id": key,
            "enabled": enabled,
            "next_run_at": nxt.isoformat() if nxt is not None else None,
            "last_run_at": recorded.get("last_run_at"),
            "last_status": recorded.get("last_status"),
            "last_detail": recorded.get("last_detail"),
        }

    sessions: dict[str, Any] = {}
    for phase in PLAN_PHASES:
        slot = session_schedule(config)[phase]
        hhmm = str(slot["time"])
        enabled = bool(slot["enabled"])
        plan_time = _shift_hhmm(hhmm, -PLAN_CARD_LEAD_MINUTES, moment)
        tasks: dict[str, Any] = {}
        for script, job_key, expected_time in (
            ("maa_plan_card.py", f"plan_card_{phase}", plan_time),
            ("maa_daily.py", f"daily_{phase}", hhmm),
        ):
            job_info = jobs_summary[job_key]
            tasks[script] = {
                "id": job_key,
                "expr": expected_time,
                "expected_expr": expected_time,
                "enabled": enabled,
                "in_sync": True,
                "next_run_at": job_info["next_run_at"],
                "last_status": job_info["last_status"],
            }
        sessions[phase] = {
            "time": hhmm,
            "enabled": enabled,
            "plan_card_time": plan_time,
            "daily_time": hhmm,
            "cron": tasks,
        }

    return {
        "backend": "daemon",
        "timezone": "Asia/Shanghai",
        "depot_enabled": depot_enabled,
        "scheduler_path": sched_path,
        "jobs_path": sched_path,
        "sessions": sessions,
        "jobs": jobs_summary,
    }


def sync_phase(
    config: Mapping[str, Any],
    phase: str,
    hermes: str = "",
    *,
    toggle: bool = False,
    at: datetime | None = None,
) -> list[str]:
    """通知内置调度器按最新 `config.session_schedule` 热重载。

    保留 `hermes` / `toggle` 参数以兼容既有调用签名；不再调 `hermes cron` CLI。
    """
    del hermes, toggle
    slot = session_schedule(config)[phase]
    hhmm = str(slot["time"])
    plan_time = _shift_hhmm(hhmm, -PLAN_CARD_LEAD_MINUTES, at)
    reloaded = notify_daemon_reload()
    state_text = "开" if slot["enabled"] else "关"
    suffix = "（已通知守护进程重载）" if reloaded else "（守护进程未运行，启动后生效）"
    return [f"{phase} 计划卡 {plan_time} / 日常 {hhmm}（{state_text}）{suffix}"]
