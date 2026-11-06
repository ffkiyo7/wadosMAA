#!/usr/bin/env python3
"""早晚场时间和 Hermes cron 的同步（K6）。

`config.session_schedule` 是场次时间的唯一来源；cron 只是它的执行者。这里只做三件事：

- 从 `$HERMES_HOME/cron/jobs.json` **只读**地认出四个场次任务（按脚本名 + 工作目录名
  `am` / `pm` 认，不写死任务 id——线上和开发副本的 id 一样，但重建任务后就不一样了）；
- 按 Hermes 的时区把「北京时间 HH:MM」换成 cron 表达式（计划卡提前 `PLAN_CARD_LEAD_MINUTES`）；
- 用 `hermes cron edit / pause / resume` 改任务。jobs.json 由 Hermes 自己加锁维护，这里**从不直接写它**。

`hermes` 认 `HERMES_HOME`（2026-11-06 核实：空目录下 `cron list` 为空，开发副本下列的是副本），
所以开发期带 `HERMES_HOME=<devhome>` 改的只是副本。
"""

from __future__ import annotations

import os
import re
import subprocess
from datetime import datetime, timedelta, tzinfo
from pathlib import Path
from typing import Any, Mapping
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from maa_common import (
    BEIJING,
    HERMES_HOME,
    PHASE_NAMES,
    PLAN_CARD_LEAD_MINUTES,
    PLAN_PHASES,
    load_json,
    now_beijing,
    session_schedule,
)

# 场次任务：脚本名 → 相对开跑时间的偏移（分钟）。
SESSION_SCRIPTS = {"maa_plan_card.py": -PLAN_CARD_LEAD_MINUTES, "maa_daily.py": 0}
SCRIPT_NAMES = {"maa_plan_card.py": "计划卡", "maa_daily.py": "日常"}
HERMES_TIMEOUT = 20
_TIMEZONE_LINE_RE = re.compile(r"^timezone:\s*['\"]?([A-Za-z0-9_+\-/]+)['\"]?\s*$", re.M)


def jobs_path() -> Path:
    return HERMES_HOME / "cron" / "jobs.json"


def hermes_timezone(home: Path | None = None) -> tzinfo:
    """Hermes 解释 cron 表达式用的时区，解析顺序照抄 `hermes_time`：

    `HERMES_TIMEZONE` → `$HERMES_HOME/config.yaml` 的 `timezone` → 本机时区。
    config.yaml 只用正则读顶层 `timezone:` 一行（stdlib 没有 yaml）。
    """
    names = [os.environ.get("HERMES_TIMEZONE", "").strip()]
    try:
        text = ((home or HERMES_HOME) / "config.yaml").read_text(encoding="utf-8")
    except OSError:
        text = ""
    match = _TIMEZONE_LINE_RE.search(text)
    names.append(match.group(1) if match else "")
    for name in names:
        if not name:
            continue
        try:
            return ZoneInfo(name)
        except (ZoneInfoNotFoundError, ValueError):
            continue
    local = datetime.now().astimezone().tzinfo
    return local if local is not None else BEIJING


def cron_expr(hhmm: str, offset_minutes: int, zone: tzinfo, at: datetime | None = None) -> str:
    """北京时间 `HH:MM` + 偏移 → Hermes 时区下的 `M H * * *`。"""
    hour, minute = (int(part) for part in hhmm.split(":"))
    day = (at or now_beijing()).astimezone(BEIJING)
    moment = day.replace(hour=hour, minute=minute, second=0, microsecond=0)
    local = (moment + timedelta(minutes=offset_minutes)).astimezone(zone)
    return f"{local.minute} {local.hour} * * *"


def session_jobs(path: Path | None = None) -> dict[tuple[str, str], dict[str, Any]]:
    """`{(场次, 脚本名): 任务}`。同一格认出两个任务就抛——宁可停下来也不改错任务。"""
    raw = load_json(path or jobs_path(), {})
    jobs = raw.get("jobs") if isinstance(raw, dict) else raw
    result: dict[tuple[str, str], dict[str, Any]] = {}
    if not isinstance(jobs, list):
        return result
    for job in jobs:
        if not isinstance(job, dict):
            continue
        script = Path(str(job.get("script") or "")).name
        phase = Path(str(job.get("workdir") or "")).name
        if script not in SESSION_SCRIPTS or phase not in PLAN_PHASES:
            continue
        if job.get("state") == "completed":
            continue
        key = (phase, script)
        if key in result:
            raise RuntimeError(
                f"cron 里有两个{PHASE_NAMES[phase]}{SCRIPT_NAMES[script]}任务"
                f"（{result[key].get('id')} / {job.get('id')}），不知道该改哪个"
            )
        result[key] = job
    return result


def job_enabled(job: Mapping[str, Any]) -> bool:
    return bool(job.get("enabled", True)) and job.get("state") != "paused"


def job_expr(job: Mapping[str, Any]) -> str:
    schedule = job.get("schedule")
    return str(schedule.get("expr") or "") if isinstance(schedule, dict) else ""


def schedule_report(config: Mapping[str, Any], at: datetime | None = None) -> dict[str, Any]:
    """`schedule show` 的数据：每场的配置时间、开关，和对应 cron 任务的现状 / 期望。"""
    zone = hermes_timezone()
    jobs = session_jobs()
    sessions: dict[str, Any] = {}
    for phase, slot in session_schedule(config).items():
        tasks: dict[str, Any] = {}
        for script, offset in SESSION_SCRIPTS.items():
            job = jobs.get((phase, script))
            expected = cron_expr(str(slot["time"]), offset, zone, at)
            tasks[script] = {
                "id": str(job.get("id") or "") if job else "",
                "expr": job_expr(job) if job else "",
                "expected_expr": expected,
                "enabled": job_enabled(job) if job else False,
                "in_sync": bool(job)
                and job_expr(job) == expected
                and job_enabled(job) == bool(slot["enabled"]),
            }
        sessions[phase] = {"time": slot["time"], "enabled": slot["enabled"], "cron": tasks}
    return {"timezone": str(zone), "jobs_path": str(jobs_path()), "sessions": sessions}


def hermes_env() -> dict[str, str]:
    env = dict(os.environ)
    env["HERMES_HOME"] = str(HERMES_HOME)
    return env


def run_hermes(hermes: str, args: list[str]) -> None:
    result = subprocess.run(
        [hermes, "cron", *args],
        capture_output=True,
        text=True,
        timeout=HERMES_TIMEOUT,
        check=False,
        env=hermes_env(),
        stdin=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise RuntimeError(
            f"hermes cron {' '.join(args)} 失败：{detail[-1][:200] if detail else result.returncode}"
        )


def sync_phase(
    config: Mapping[str, Any],
    phase: str,
    hermes: str,
    *,
    toggle: bool = False,
    at: datetime | None = None,
) -> list[str]:
    """把一场的两个任务对齐到配置：时间不对就 `edit --schedule`；`toggle` 时再按开关
    `pause` / `resume`。

    只有用户在 GUI 里**拨了开关**才动暂停状态：开发期 cron 是用户手动全停的，
    改个时间不能顺手把它们恢复。返回给人看的变更说明。
    """
    slot = session_schedule(config)[phase]
    zone = hermes_timezone()
    jobs = session_jobs()
    notes: list[str] = []
    for script, offset in SESSION_SCRIPTS.items():
        name = f"{PHASE_NAMES[phase]}{SCRIPT_NAMES[script]}"
        job = jobs.get((phase, script))
        if job is None:
            raise RuntimeError(f"cron 里找不到{name}任务（{jobs_path()}）")
        job_id = str(job.get("id") or "")
        expected = cron_expr(str(slot["time"]), offset, zone, at)
        if job_expr(job) != expected:
            run_hermes(hermes, ["edit", job_id, "--schedule", expected])
            notes.append(f"{name} → {expected}（{zone}）")
        if toggle and job_enabled(job) != bool(slot["enabled"]):
            run_hermes(hermes, ["resume" if slot["enabled"] else "pause", job_id])
            notes.append(f"{name}已{'恢复' if slot['enabled'] else '暂停'}")
    return notes
