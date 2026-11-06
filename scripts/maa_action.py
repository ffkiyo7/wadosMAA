#!/usr/bin/env python3
"""The only permitted mutation and dispatch entry point for the MAA plan."""

from __future__ import annotations

import fcntl
import json
import os
import re
import secrets
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import TYPE_CHECKING, Any, cast

if TYPE_CHECKING:
    from typing import TypeGuard  # 3.10+，只在注解里用（见 maa_common）

import maa_common
import maa_copilot
import maa_playcover
import maa_schedule
import maa_settings
from maa_common import (
    BUTTONS_PATH,
    DEFAULTS_PATH,
    DEFAULT_MANUAL_RUN_BLACKOUT_MINUTES,
    LAST_RUN_PATH,
    LAST_RUN_SCHEMA_VERSION,
    MANUAL_RUN_BUTTON_PREFIX,
    MANUAL_RUN_PATH,
    MANUAL_RUN_SCHEMA_VERSION,
    MANUAL_RUN_TTL,
    PLAN_PATH,
    PLAN_PHASES,
    PLAN_SCHEMA_VERSION,
    PHASE_NAMES,
    PLAN_SESSION_FIELDS,
    SCRIPTS_DIR,
    WATCH_PATH,
    Config,
    Plan,
    PlanFile,
    PlanPhase,
    SessionOverride,
    action_source,
    atomic_write_json,
    check_schema,
    discord_request,
    discord_token,
    effective_plan,
    is_plan_phase,
    is_run_locked,
    load_config,
    load_json,
    maa_subprocess_env,
    medicine_label,
    normalize_plan,
    now_beijing,
    plan_stage_label,
    require_executable,
    retire_discord_components,
    session_label,
    session_time,
    session_within,
    state_lock,
)


STAGE_PATTERN = re.compile(r"^[A-Za-z0-9]{1,8}-\d{1,2}$")
ACTIVITY_STAGE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,30}-\d{1,2}$")
# 场次的中文说法。只有这两个场次能被覆盖；`now` 是手动场，没有覆盖可写——
# 它的关来自选关卡（`manual_run.json`，PLAN_MANUAL_RUN.md M4），不进 `plan.json`。


def phase_label(phase: str, config: Config | None = None) -> str:
    """「早场（08:00）」：时间按 `config.session_schedule`，不再写死。"""
    cfg: Config = config if config is not None else load_config()
    hhmm = session_time(cfg, phase)
    name = PHASE_NAMES.get(phase, "本场")
    return f"{name}（{hhmm}）" if hhmm else name


def emit(ok: bool, message: str, data: dict[str, Any] | None = None) -> None:
    # Persistent button runner accepts at most 8192 bytes and parses only JSON.
    # 带 `data` 的回执只有 GUI 读（它读完整 stdout），不受这个上限；但 message 照样截。
    payload: dict[str, Any] = {"ok": ok, "message": message}
    raw = json.dumps(payload, ensure_ascii=False)
    if len(raw.encode("utf-8")) > 7900:
        payload["message"] = message[:1800] + "\n…（已截断）"
    if data is not None:
        payload["data"] = data
    print(json.dumps(payload, ensure_ascii=False))


def _activity_output_allows(stage: str, config: Config) -> bool:
    configured = config.get("activity_stages", [])
    if isinstance(configured, list) and stage in {str(item) for item in configured}:
        return True
    if not ACTIVITY_STAGE_PATTERN.fullmatch(stage):
        return False
    maa_bin = str(config.get("maa_bin", "/opt/homebrew/bin/maa"))
    try:
        result = subprocess.run(
            [maa_bin, "activity", "Official"],
            capture_output=True,
            text=True,
            timeout=0.7,
            check=False,
            env=maa_subprocess_env(config),
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    output = f"{result.stdout}\n{result.stderr}"
    token = re.compile(
        rf"(?<![A-Za-z0-9_-]){re.escape(stage)}(?![A-Za-z0-9_-])"
    )
    return result.returncode == 0 and bool(token.search(output))


def valid_stage(stage: str, config: Config) -> bool:
    return stage == "" or bool(STAGE_PATTERN.fullmatch(stage)) or _activity_output_allows(stage, config)


def valid_phase(phase: str) -> TypeGuard[PlanPhase]:
    """场次只接受 `am` / `pm`。值由登记表的 `select_args` / `args` 写死，不从 Discord 直通。"""
    return is_plan_phase(phase)


def _today_override() -> PlanFile:
    """当天的场次表，已按白名单过滤。

    结构是 `{date, sessions: {am: {...}, pm: {...}}, updated_at}`。日期不是今天、
    或磁盘上还是旧的按天格式（顶层 `stage` / `skip`），一律重置成空——
    旧格式一天后自然失效，不为它写迁移（四期 1a）。
    每个场次只保留 `PLAN_SESSION_FIELDS` 里的字段，其中 `stage_source` 是闸门：
    掉了它，用户点一次「跳过」就会让当天的自动定关被当成手动选择冻住。
    """
    now = now_beijing()
    current = check_schema("plan.json", load_json(PLAN_PATH, {}), PLAN_SCHEMA_VERSION)
    sessions: Any = {}
    if isinstance(current, dict) and current.get("date") == now.date().isoformat():
        sessions = current.get("sessions")
    kept: dict[str, SessionOverride] = {}
    if isinstance(sessions, dict):
        for phase in PLAN_PHASES:
            override = sessions.get(phase)
            if isinstance(override, dict):
                kept[phase] = cast(SessionOverride, {
                    key: override[key]
                    for key in PLAN_SESSION_FIELDS
                    if key in override
                })
    return {"date": now.date().isoformat(), "sessions": kept}


def _save_override(phase: PlanPhase, key: str, value: Any, **extra: Any) -> Plan:
    now = now_beijing()
    with state_lock():
        plan = _today_override()
        # 字段名由调用方写死（stage / skip / fight），这里按普通 dict 写。
        session = cast("dict[str, Any]", plan["sessions"].setdefault(phase, {}))  # pyright: ignore[reportTypedDictNotRequiredAccess]  # _today_override() 一定带 sessions
        session[key] = value
        session.update(extra)
        session["source"] = action_source()
        session["updated_at"] = now.isoformat()
        plan["updated_at"] = now.isoformat()
        plan["schema_version"] = PLAN_SCHEMA_VERSION
        # There is deliberately no stone field in this write path.
        atomic_write_json(PLAN_PATH, plan)
    if action_source() == "gui":
        # K3：GUI 改了这一场的计划，Discord 上那张计划卡也要跟着变。PATCH 要建卡、
        # 可能算材料推荐，放进脱离会话的子进程，不占这条回执。
        _spawn_action(["plan", "refresh-card", phase])
    return effective_plan(phase=phase)


def _running_context() -> tuple[str, str]:
    state = check_schema(
        "last_run.json", load_json(LAST_RUN_PATH, {}), LAST_RUN_SCHEMA_VERSION, strict=False
    )
    if not isinstance(state, dict) or state.get("status") != "running":
        return "本场", "上次的本"
    phase = str(state.get("phase", "now"))
    phase_label = {"am": "早场", "pm": "晚场", "now": "手动场"}.get(phase, "本场")
    plan = state.get("plan", {})
    stage = plan_stage_label(plan if isinstance(plan, dict) else {})
    return phase_label, stage


def _confirmation(plan: Plan, was_running: bool, phase: PlanPhase) -> str:
    """一句回执：改的是**哪一场**、另一场不受影响、正在跑的那场不被打断。"""
    now = now_beijing()
    stage = plan_stage_label(plan)
    medicine = medicine_label(str(plan.get("medicine", "none")))
    label = phase_label(phase)
    other = "、".join(
        phase_label(other_phase) for other_phase in PLAN_PHASES if other_phase != phase
    )
    if plan.get("skip"):
        # 这条回执对 set-stage 和 skip-today 通用，所以跳过时也报一下这场记的关：
        # 用户改完关才发现本场是跳过的，总比到点没跑再来问强。
        target = (
            f"今天（{now.month}/{now.day}）的{label}已设为跳过"
            f"（本场记的关是 {stage}，恢复后生效）；"
            f"{other}不受影响，说「现在跑」也仍然可以手动开一场。"
        )
    elif not (plan.get("tasks") or {}).get("fight", True):
        target = (
            f"今天（{now.month}/{now.day}）的{label}不清理智（剿灭和刷理智都不打），"
            f"基建 / 公招 / 商店 / 领奖照常；{other}不受影响。"
        )
    else:
        target = (
            f"今天（{now.month}/{now.day}）的{label}刷 {stage}，{medicine}；"
            f"{other}不受影响。"
        )
    if was_running:
        running_label, running_stage = _running_context()
        return f"{running_label}正在跑 {running_stage}，不打断它；{target}"
    return target


def _reject_phase(phase: str) -> tuple[bool, str]:
    return False, f"场次只接受 am（早场）或 pm（晚场），收到 {phase[:20]!r}。"


def set_stage(stage: str, phase: str) -> tuple[bool, str]:
    if not valid_phase(phase):
        return _reject_phase(phase)
    config = load_config()
    if not valid_stage(stage, config):
        return (
            False,
            "关卡不在白名单：只接受常规关卡格式（如 CE-6、1-7）、空串（上次的本）"
            "或当前活动关。碎石设置永远不受支持。",
        )
    was_running = is_run_locked()
    # 标成 discord：当天这一场的自动定关不再覆盖它（`maa_plan_card.apply_auto_stage()`）。
    # 同时**清掉 drops 上限和后备关**：那两个是给缺口第一名算的，换了关就不成立了；
    # 手动选的关一律打到理智不足为止（四期步骤 3b）。
    plan = _save_override(
        phase,
        "stage",
        stage,
        stage_source="discord",
        farming_drops={},
        farming_fallback_stage="",
    )
    return True, _confirmation(plan, was_running, phase)


def set_medicine(value: str) -> tuple[bool, str]:
    del value
    return False, "理智规则已固定：普通理智药 0，只自动使用临期药，碎石 0。"


def skip_today(value: str, phase: str) -> tuple[bool, str]:
    if value not in {"on", "off"}:
        return False, "skip-today 只接受 on 或 off。"
    if not valid_phase(phase):
        return _reject_phase(phase)
    was_running = is_run_locked()
    plan = _save_override(phase, "skip", value == "on")
    return True, _confirmation(plan, was_running, phase)


def fight_today(value: str, phase: str) -> tuple[bool, str]:
    """`plan fight <on|off> <am|pm>`：今天这一场清不清理智（off = 只收菜）。"""
    if value not in {"on", "off"}:
        return False, "fight 只接受 on 或 off。"
    if not valid_phase(phase):
        return _reject_phase(phase)
    was_running = is_run_locked()
    plan = _save_override(phase, "fight", value == "on")
    return True, _confirmation(plan, was_running, phase)


def show_plan() -> tuple[bool, str]:
    """两场各念一遍：刷什么、关是谁定的、跳不跳。"""
    origins = {"auto": "按材料缺口自动定的", "discord": "你手动选的"}
    lines: list[str] = []
    for phase in PLAN_PHASES:
        plan = effective_plan(phase=phase)
        origin = origins.get(str(plan.get("stage_source") or ""), "默认关")
        status = "跳过" if plan.get("skip") else (
            "照常执行" if (plan.get("tasks") or {}).get("fight", True)
            else "不清理智，只收菜（基建 / 公招 / 商店 / 领奖）"
        )
        lines.append(
            f"· {phase_label(phase)}：{plan_stage_label(plan)}（{origin}）；{status}"
        )
    return (
        True,
        "今天的计划：\n"
        + "\n".join(lines)
        + f"\n理智药：{medicine_label('expiring')}；碎石：0。",
    )


# ---------------------------------------------------------------------------
# 手动场（「现在跑」）：先发选关卡，选了才派发，10 分钟不选作废（PLAN_MANUAL_RUN.md）
# ---------------------------------------------------------------------------

MANUAL_RUN_CARD_TITLE = "🎯 手动场选关"
MANUAL_RUN_PENDING_TEXT = "计算中…"


def manual_run_blackout_reason(
    config: Config, at: datetime | None = None
) -> str | None:
    """定时场优先（M10）：距下一场开着的定时场不足 N 分钟，手动场不发卡也不派发。

    与 `_copilot_blackout_reason()` 同构但另开配置键：手动日常一场约 14 分钟，
    加上卡片 10 分钟有效期，默认 30 比抄作业的 25 宽。0 = 关闭。
    """
    minutes = max(
        0,
        int(config.get("manual_run_blackout_minutes", DEFAULT_MANUAL_RUN_BLACKOUT_MINUTES)),
    )
    if minutes == 0:
        return None
    hit = session_within(config, minutes, at or now_beijing())
    if hit:
        return (
            f"距{session_label(config, hit[0])} 不足 {minutes} 分钟，定时场优先，"
            "请在日常结束后再手动跑。"
        )
    return None


def _load_manual_run() -> dict[str, Any]:
    state = check_schema(
        "manual_run.json", load_json(MANUAL_RUN_PATH, {}), MANUAL_RUN_SCHEMA_VERSION
    )
    return state if isinstance(state, dict) else {}


def _save_manual_run(state: dict[str, Any]) -> None:
    """写 `manual_run.json`，带上格式版本号。调用方持 `state_lock()`。"""
    state["schema_version"] = MANUAL_RUN_SCHEMA_VERSION
    atomic_write_json(MANUAL_RUN_PATH, state)


def _manual_run_custom_id(token: str) -> str:
    return f"{MANUAL_RUN_BUTTON_PREFIX}{token}:stage-select"


def _manual_run_components(
    choices: list[list[str]] | list[tuple[str, str, str]],
    token: str,
    recommended: str | None = None,
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """选关卡的一行下拉 + 它的登记项。

    选项与早晚场卡同源（`maa_plan_card._stage_choices()`，M2），但**没有 `default`**：
    这张卡的意义就是强制用户选（M1）。值仍是不透明 `choice:N`，argv 写死在登记表里
    （不变量 #8）。`recommended` 只影响 emoji（🎯 标缺口推荐，M8），不预选。
    """
    select_args: dict[str, list[str]] = {}
    options: list[dict[str, Any]] = []
    for index, (label, stage, description) in enumerate(choices):
        value = f"choice:{index}"
        options.append(
            {
                "label": str(label)[:100],
                "value": value,
                "description": str(description)[:100],
                "emoji": {"name": "🎯" if recommended is not None and stage == recommended else "▫️"},
            }
        )
        select_args[value] = ["run", "start", str(stage), token]
    custom_id = _manual_run_custom_id(token)
    rows = [
        {
            "type": 1,
            "components": [
                {
                    "type": 3,
                    "custom_id": custom_id,
                    "placeholder": "🎯 选这次手动场要刷的关（选中即开跑）",
                    "min_values": 1,
                    "max_values": 1,
                    "options": options,
                }
            ],
        }
    ]
    entries = {
        custom_id: {
            "kind": "exec",
            "script": "maa_action.py",
            "select_args": select_args,
        }
    }
    return rows, entries


def _manual_run_embed(
    state: dict[str, Any], *, footer: str = "", color: int = 0x5865F2
) -> dict[str, Any]:
    try:
        deadline = f"{datetime.fromisoformat(str(state.get('expires_at'))):%H:%M}"
    except (TypeError, ValueError):
        deadline = "10 分钟"
    recommendation = str(state.get("recommendation") or MANUAL_RUN_PENDING_TEXT)
    return {
        "title": MANUAL_RUN_CARD_TITLE,
        "description": (
            "从下拉选一关＝**立刻**开一场手动日常（基建 / 公招 / 商店 / 奖励照跑）。\n"
            f"不选的话 **{deadline}** 后这张卡作废，要跑得重新说「现在跑」。\n"
            "手动场不看早晚场卡上的选择；设了跳过也照跑；手动选的关不带掉落上限，打到理智不足为止。"
        ),
        "color": color,
        "fields": [{"name": "缺口推荐", "value": recommendation[:1024], "inline": False}],
        "footer": {"text": footer or f"{deadline} 前有效 · 定时场前 30 分钟内不接受"},
        "timestamp": str(state.get("created_at") or now_beijing().isoformat()),
    }


def _manual_run_message_patch(
    config: Config, state: dict[str, Any], payload: dict[str, Any]
) -> bool:
    channel_id = str(config.get("channel_id") or "")
    message_id = str(state.get("message_id") or "")
    if not channel_id.isdigit() or not message_id.isdigit():
        return False
    discord_request(
        discord_token(),
        "PATCH",
        f"/channels/{channel_id}/messages/{message_id}",
        payload,
    )
    return True


def _retire_manual_run(
    config: Config, status: str, footer: str
) -> dict[str, Any] | None:
    """把当前 `pending` 请求收成 `status`：状态 → 删登记 → 收卡片组件。

    返回收掉的请求（没有 pending 请求返回 None）。Discord PATCH 失败会抛，
    调用方决定是进回执尾巴还是吞掉——本地登记在抛之前已经删干净。
    """
    with state_lock():
        state = _load_manual_run()
        if state.get("status") != "pending":
            return None
        state["status"] = status
        state["updated_at"] = now_beijing().isoformat()
        _save_manual_run(state)
        registry = load_json(BUTTONS_PATH, {})
        if isinstance(registry, dict):
            for custom_id in [k for k in registry if k.startswith(MANUAL_RUN_BUTTON_PREFIX)]:
                registry.pop(custom_id)
            atomic_write_json(BUTTONS_PATH, registry)
    _manual_run_message_patch(
        config,
        state,
        {"embeds": [_manual_run_embed(state, footer=footer, color=0x99AAB5)], "components": []},
    )
    return state


def _spawn_action(args: list[str]) -> None:
    """派一个脱离会话的 `maa_action.py` 子进程（不受 Hermes exec 的 20s 限制）。"""
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), *args],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def _skipped_sessions_note() -> str:
    # 跳过是按场次的（D2），所以这里要逐场看，不能再说「今天设了跳过」。
    skipped = [
        phase_label(phase)
        for phase in PLAN_PHASES
        if effective_plan(phase=phase).get("skip")
    ]
    return f"（今天的{'、'.join(skipped)}设了跳过，手动场照跑）" if skipped else ""


def run_now() -> tuple[bool, str]:
    """「现在跑」→ 发一张选关卡（M-b）。不开跑；开跑在 `run_start()`。"""
    from maa_plan_card import _stage_choices

    if is_run_locked():
        phase, stage = _running_context()
        return False, f"{phase}已经在跑 {stage}，没有重复启动。"
    config = load_config()
    reason = manual_run_blackout_reason(config)
    if reason:
        return False, f"⛔ {reason}"
    script = SCRIPTS_DIR / "maa_daily.py"
    if not script.is_file():
        return False, "maa_daily.py 尚未部署。"
    try:
        require_executable(config, "maa_bin", "/opt/homebrew/bin/maa", "maa-cli")
        maa_playcover.verify_game_installed(config)
    except RuntimeError as exc:
        return False, f"暂时不能运行：{exc}"
    channel_id = str(config.get("channel_id", "")).strip()
    if not channel_id.isdigit():
        return False, "config.json 中尚未配置 Discord channel_id。"

    warning = ""
    # 先收旧卡（状态 → 登记 → 组件），再写新登记、再发新卡（不变量 #14b）。
    try:
        _retire_manual_run(config, "superseded", "已被新的选关卡取代")
    except Exception as exc:  # noqa: BLE001 — (c) 收旧选关卡尽力而为，失败只附在回执里
        warning = f"；上一张选关卡收起失败：{type(exc).__name__}: {exc}"

    now = now_beijing()
    token = _new_search_token()
    choices = [list(choice) for choice in _stage_choices(effective_plan(phase="now"), config)]
    rows, entries = _manual_run_components(choices, token)
    state = {
        "token": token,
        "status": "pending",
        "stage": "",
        "choices": choices,
        "recommendation": "",
        "recommended_stage": "",
        "message_id": "",
        "created_at": now.isoformat(),
        "expires_at": (now + MANUAL_RUN_TTL).isoformat(),
        "updated_at": now.isoformat(),
    }
    with state_lock():
        registry = load_json(BUTTONS_PATH, {})
        if not isinstance(registry, dict):
            raise RuntimeError("共享按钮登记表格式错误")
        for custom_id in [k for k in registry if k.startswith(MANUAL_RUN_BUTTON_PREFIX)]:
            registry.pop(custom_id)
        registry.update(entries)
        atomic_write_json(BUTTONS_PATH, registry)
    message = discord_request(
        discord_token(),
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [_manual_run_embed(state)],
            "components": rows,
            "allowed_mentions": {"parse": []},
        },
    )
    state["message_id"] = str(message.get("id", "")) if isinstance(message, dict) else ""
    with state_lock():
        _save_manual_run(state)
    # 过期哨兵（M-d，尽力而为的 UI 清理）与缺口推荐补写（M-g，可能要查森空岛）
    # 都是脱离会话的子进程，不占这个 20s 进程。
    _spawn_action(["run", "expire", token, "--after", str(int(MANUAL_RUN_TTL.total_seconds()))])
    _spawn_action(["run", "recommend", token])
    deadline = f"{now + MANUAL_RUN_TTL:%H:%M}"
    return (
        True,
        f"🎯 已发手动场选关卡{_skipped_sessions_note()}，从下拉选一关即开跑；"
        f"{deadline} 前不选就作废{warning}。",
    )


def run_start(stage: str, token: str) -> tuple[bool, str]:
    """卡上选了关 → 校验 → 派发 `maa_daily.py now <token>`（M-c）。只由登记表触发。"""
    state = _load_manual_run()
    if (
        not maa_copilot.SEARCH_TOKEN_RE.fullmatch(token or "")
        or state.get("token") != token
        or state.get("status") != "pending"
    ):
        return False, "这张选关卡已失效，请再说一次「现在跑」。"
    config = load_config()
    now = now_beijing()
    try:
        expires_at = datetime.fromisoformat(str(state.get("expires_at")))
    except (TypeError, ValueError):
        expires_at = now - timedelta(seconds=1)
    if now > expires_at:
        # 硬闸门：哨兵晚到、adapter 重放、旧登记残留都拦在这里。
        warning = ""
        try:
            _retire_manual_run(config, "expired", "⌛ 已过期，重新说「现在跑」")
        except Exception as exc:  # noqa: BLE001 — (c) 过期卡收起尽力而为，失败只附在回执里
            warning = f"（卡片收起失败：{type(exc).__name__}: {exc}）"
        return False, f"⌛ 这张选关卡已过期（{expires_at:%H:%M}），请再说一次「现在跑」。{warning}"
    if not valid_stage(stage, config):
        return False, "关卡不在白名单：只接受常规关卡格式（如 CE-6、1-7）、空串（上次的本）或当前活动关。"
    if is_run_locked():
        phase, running = _running_context()
        return False, f"{phase}已经在跑 {running}，等它结束后再选（这张卡 {expires_at:%H:%M} 前有效）。"
    reason = manual_run_blackout_reason(config, now)
    if reason:
        return False, f"⛔ {reason}"
    script = SCRIPTS_DIR / "maa_daily.py"
    if not script.is_file():
        return False, "maa_daily.py 尚未部署。"
    try:
        require_executable(config, "maa_bin", "/opt/homebrew/bin/maa", "maa-cli")
        maa_playcover.verify_game_installed(config)
    except RuntimeError as exc:
        return False, f"暂时不能运行：{exc}"

    with state_lock():
        state = _load_manual_run()
        if state.get("token") != token or state.get("status") != "pending":
            return False, "这张选关卡已失效，请再说一次「现在跑」。"
        state["status"] = "dispatched"
        state["stage"] = stage
        state["dispatched_at"] = now.isoformat()
        state["updated_at"] = now.isoformat()
        _save_manual_run(state)
        registry = load_json(BUTTONS_PATH, {})
        if isinstance(registry, dict):
            for custom_id in [k for k in registry if k.startswith(MANUAL_RUN_BUTTON_PREFIX)]:
                registry.pop(custom_id)
            atomic_write_json(BUTTONS_PATH, registry)
    warning = ""
    try:
        _manual_run_message_patch(
            config,
            state,
            {
                "embeds": [
                    _manual_run_embed(
                        state, footer=f"▶️ 已选 {plan_stage_label(state)}，手动场已派发", color=0x57F287
                    )
                ],
                "components": [],
            },
        )
    except Exception as exc:  # noqa: BLE001 — (c) 收卡尽力而为，手动场照样派发，失败只附在回执里
        warning = f"；卡片收起失败：{type(exc).__name__}: {exc}"
    subprocess.Popen(
        [sys.executable, str(script), "now", token],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    return (
        True,
        f"▶️ 已派发手动场，刷 {plan_stage_label(state)}（不带掉落上限，打到理智不足为止）"
        f"{_skipped_sessions_note()}；开跑消息稍后出现在频道{warning}。",
    )


# 「这一次」的环节开关（K12）：`tasks.*` 五项加剿灭。只对这一场手动场生效，不进 plan.json。
LOCAL_RUN_SWITCHES = (*maa_common.DEFAULT_TASKS, "annihilation")


def _local_run_switches(raw: str) -> dict[str, bool]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"环节开关不是合法的 JSON：{exc.msg}") from exc
    if not isinstance(value, dict) or set(value) - set(LOCAL_RUN_SWITCHES):
        raise ValueError(f"环节开关只接受 {' / '.join(LOCAL_RUN_SWITCHES)}")
    if any(not isinstance(item, bool) for item in value.values()):
        raise ValueError("环节开关只能是 true / false")
    switches = {key: bool(value.get(key, True)) for key in LOCAL_RUN_SWITCHES}
    if not any(switches[key] for key in maa_common.DEFAULT_TASKS):
        raise ValueError("五个环节全关了，这一场什么都不做")
    return switches


def run_local(stage: str, raw_switches: str, *flags: str) -> tuple[bool, str, dict[str, Any]]:
    """Wado's MAA 的「开始」（K4 / K12）：不发选关卡，直接按 GUI 给的关和环节派发。

    走的是和选关卡同一条路：写 `manual_run.json`（`dispatched` + 这一次的 `tasks`）→
    `maa_daily.py now <token>`。所以照样持 `run.lock`、摆窗口、截图核验、发 Discord 开跑和战报；
    参数只对这一场生效，不进 `plan.json`（M4）。定时场优先照旧（M10）；`--force` 只跳过这一条，
    由 GUI 在用户确认后传，锁冲突永远不能强行。
    """
    force = "--force" in flags
    if set(flags) - {"--force"}:
        return False, "只认 --force 一个选项。", {}
    config = load_config()
    if not valid_stage(stage, config):
        return False, "关卡不在白名单：只接受常规关卡格式（如 CE-6、1-7）、空串（上次的本）或当前活动关。", {}
    try:
        switches = _local_run_switches(raw_switches)
    except ValueError as exc:
        return False, str(exc), {}
    if is_run_locked():
        phase, running = _running_context()
        return False, f"{phase}已经在跑 {running}，等它结束后再开。", {"blocked": "locked"}
    now = now_beijing()
    reason = manual_run_blackout_reason(config, now)
    if reason and not force:
        return False, f"⛔ {reason}", {"blocked": "blackout", "reason": reason}
    script = SCRIPTS_DIR / "maa_daily.py"
    if not script.is_file():
        return False, "maa_daily.py 尚未部署。", {}
    try:
        require_executable(config, "maa_bin", "/opt/homebrew/bin/maa", "maa-cli")
        maa_playcover.verify_game_installed(config)
    except RuntimeError as exc:
        return False, f"暂时不能运行：{exc}", {}
    warning = ""
    try:
        # Discord 上还挂着一张没选的选关卡：收掉，免得两边各派一场。
        _retire_manual_run(config, "superseded", "已被 Wado's MAA 的手动场取代")
    except Exception as exc:  # noqa: BLE001 — (c) 收卡尽力而为，本地状态已先改掉
        warning = f"；旧选关卡收起失败：{type(exc).__name__}: {exc}"
    token = _new_search_token()
    tasks = {key: switches[key] for key in maa_common.DEFAULT_TASKS}
    state: dict[str, Any] = {
        "token": token,
        "status": "dispatched",
        "stage": stage,
        "tasks": tasks,
        "annihilation": switches["annihilation"],
        "source": action_source(),
        "forced": bool(reason) and force,
        "created_at": now.isoformat(),
        "dispatched_at": now.isoformat(),
        "updated_at": now.isoformat(),
        "expires_at": (now + MANUAL_RUN_TTL).isoformat(),
    }
    with state_lock():
        _save_manual_run(state)
    subprocess.Popen(
        [sys.executable, str(script), "now", token],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )
    skipped = [TASK_NAMES[key] for key in maa_common.DEFAULT_TASKS if not tasks[key]]
    if not switches["annihilation"] and tasks["fight"]:
        skipped.append("剿灭")
    tail = f"，跳过{'、'.join(skipped)}" if skipped else ""
    forced = "（已确认在定时场前强行开跑）" if state["forced"] else ""
    return (
        True,
        f"▶️ 已派发手动场，刷 {plan_stage_label(state)}{tail}{forced}；"
        f"开跑消息稍后出现在 Discord{warning}。",
        {"token": token, "stage": stage, "tasks": tasks, "annihilation": switches["annihilation"]},
    )


def run_expire(token: str, after: int = 0) -> tuple[bool, str]:
    """到期收卡（M-d）。幂等：不是这个 token 的 pending 请求、或还没到期，就什么都不做。"""
    if after > 0:
        time.sleep(after)
    state = _load_manual_run()
    if state.get("token") != token or state.get("status") != "pending":
        return True, "没有待过期的选关卡。"
    try:
        expires_at = datetime.fromisoformat(str(state.get("expires_at")))
    except (TypeError, ValueError):
        expires_at = now_beijing()
    if now_beijing() < expires_at:
        return True, f"选关卡 {expires_at:%H:%M} 才到期。"
    config = load_config()
    retired = _retire_manual_run(config, "expired", "⌛ 已过期，重新说「现在跑」")
    return True, "⌛ 选关卡已过期并收起。" if retired else "没有待过期的选关卡。"


def run_recommend(token: str) -> tuple[bool, str]:
    """缺口推荐补写（M-g）：算完 PATCH 卡片，只在请求仍 pending 时写回。

    只由 `run_now()` 派发的脱离会话子进程调用；计算链与 07:50 建卡相同（D5 口径）。
    """
    from maa_plan_card import auto_stage, current_farming_result, farming_note

    config = load_config()
    recommended = ""
    try:
        result = current_farming_result(effective_plan(phase="now"), config)
        recommended, why = auto_stage(result)
        note = farming_note(result)
        if recommended:
            text = f"**{recommended}**" + (f" · {why}" if why else "")
        else:
            text = f"推荐暂不可用（{why or '缺口算不出来'}）"
        if note:
            text = f"{text}\n{note}"
    except Exception as exc:  # noqa: BLE001 — (c) 推荐是旁路信息（森空岛 / 缺口计算，失败形态不定），失败写成「暂不可用」
        text = f"推荐暂不可用（{type(exc).__name__}: {exc}）"
    with state_lock():
        state = _load_manual_run()
        if state.get("token") != token or state.get("status") != "pending":
            return True, "选关卡已不在等待中，推荐不再写回。"
        state["recommendation"] = text[:1000]
        state["recommended_stage"] = recommended
        state["updated_at"] = now_beijing().isoformat()
        _save_manual_run(state)
    raw_choices = state.get("choices")
    choices = raw_choices if isinstance(raw_choices, list) else []
    rows, _entries = _manual_run_components(choices, token, recommended or None)
    _manual_run_message_patch(
        config, state, {"embeds": [_manual_run_embed(state)], "components": rows}
    )
    return True, f"缺口推荐已写回：{recommended or '暂不可用'}。"


def log_tail() -> tuple[bool, str]:
    state = check_schema(
        "last_run.json", load_json(LAST_RUN_PATH, {}), LAST_RUN_SCHEMA_VERSION, strict=False
    )
    if not isinstance(state, dict) or not state.get("status"):
        return True, "📋 还没有 MAA 执行结果。"
    summary = str(state.get("summary", "")).strip()
    # Existing state may have been produced by the pre-translation runner.
    # Rebuild it from the local log without ever exposing raw CLI lines.
    if not summary.startswith("🌟 总体："):
        log_path = Path(str(state.get("log", "")))
        if log_path.is_file():
            from maa_daily import extract_summary

            raw = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
            plan = state.get("plan", {})
            summary = extract_summary(
                raw,
                [],
                plan=cast(Plan, plan) if isinstance(plan, dict) else {},
                ok=state.get("status") == "success",
            )
    if not summary:
        summary = "🌟 总体：暂无可解析的执行明细"
    finished = str(state.get("finished_at", "")).replace("T", " ")[:19]
    when = f"（{finished}）" if finished else ""
    return True, f"📋 最近一次结果{when}\n{summary}"


# ---------------------------------------------------------------------------
# Copilot (prts.plus 抄作业) — all under 20s, real work goes to the worker
# ---------------------------------------------------------------------------

def valid_copilot_stage(
    name: str, config: Config
) -> tuple[str, str] | None:
    """Exact lookup in the local stage index; never guess aliases."""
    index = maa_copilot.load_stage_index(config)
    return maa_copilot.resolve_copilot_stage(name, index)


def _new_search_token() -> str:
    return secrets.token_hex(6)


def _search_path(token: str) -> Path:
    return maa_copilot.SEARCHES_DIR / f"{token}.json"


def _load_search(token: str) -> dict[str, Any] | None:
    if not maa_copilot.SEARCH_TOKEN_RE.fullmatch(token or ""):
        return None
    state = load_json(_search_path(token), None)
    return state if isinstance(state, dict) else None


def _mark_search_dispatch_failed(token: str, message: str) -> None:
    with state_lock():
        state = _load_search(token)
        if state is None or state.get("status") != "pending":
            return
        state["status"] = "failed"
        state["error"] = message[:400]
        state["finished_at"] = now_beijing().isoformat()
        atomic_write_json(_search_path(token), state)


def _invalidate_search_card(token: str, config: Config) -> str:
    changed, message_id = maa_copilot.supersede_search(token)
    if not changed:
        return ""
    try:
        retire_discord_components(config, message_id)
    except Exception as exc:  # noqa: BLE001 — (c) 登记已先作废，收按钮失败只附在回执里
        return f"；旧卡按钮收起失败但已不能执行：{type(exc).__name__}: {exc}"
    return ""


def _copilot_blackout_reason(config: Config, at: datetime | None = None) -> str | None:
    """Refuse to start a copilot run close to the next scheduled daily run."""
    minutes = max(0, int(config.get("copilot_blackout_minutes", 25)))
    if minutes == 0:
        return None
    hit = session_within(config, minutes, at or now_beijing())
    if hit:
        return (
            f"距{session_label(config, hit[0])} 不足 {minutes} 分钟，"
            "为避免互斥抢占，请在日常结束后再抄作业。"
        )
    return None


# Depot 的独立 cron 在北京时间 04:30 触发，到期时会持 run.lock 数分钟
# （不变量 #23）。自动作业避开这个窗口，免得两边互相抢锁、谁也跑不成。
DEPOT_WINDOW_START_MINUTES = 4 * 60 + 20
DEPOT_WINDOW_END_MINUTES = 5 * 60


DEFAULT_MIN_LEAD_MINUTES = 40


def min_lead_reason(config: Config, at: datetime | None = None) -> str | None:
    """距下一场日常还够不够**开新的一关**（四期 2c 的时间预算）。

    与 `copilot_blackout_minutes` 是两条不同的闸门：blackout 管「能不能开这一轮」，
    这条管「一轮里还能不能再开一关」——一关十来分钟，撞上早晚场会让日常
    抢不到锁。默认 40 分钟，比 blackout（25）宽，因为它要覆盖整关而不只是启动。
    watcher 派发前查一次（省得派出去立刻收尾），worker 每关开始前再查一次。
    """
    minutes = max(0, int(config.get("auto_copilot_min_lead_minutes", DEFAULT_MIN_LEAD_MINUTES)))
    if minutes == 0:
        return None
    hit = session_within(config, minutes, at or now_beijing())
    if hit:
        return (
            f"距{session_label(config, hit[0])} 不足 {minutes} 分钟，本轮到此收尾，"
            "剩下的关留给下一轮。"
        )
    return None


def depot_window_reason(at: datetime | None = None) -> str | None:
    moment = at or now_beijing()
    minutes = moment.hour * 60 + moment.minute
    if DEPOT_WINDOW_START_MINUTES <= minutes < DEPOT_WINDOW_END_MINUTES:
        return "处于 Depot 对表窗口（北京时间 04:20–05:00），不与它抢 run.lock。"
    return None


def dispatch_blocker(
    config: Config, scheduled_at: str, at: datetime | None = None
) -> str:
    """还不能派发的原因；可以派发返回空串。**每一条都要能说出口**（护栏 4）。

    自动与手动共用这**一份**实现（不变量 #13）：watcher 每 tick 派发前查一次，
    手动 `start_copilot_search()` 写 `pending` 之前查一次、`cmd_search()` 搜完
    派发之前再查一次（搜索要跑 5~20s，可能刚好跨进 blackout）。
    """
    moment = at or now_beijing()
    if scheduled_at:
        try:
            ready = datetime.fromisoformat(scheduled_at)
        except ValueError:
            ready = moment
        if moment < ready:
            return f"等理智恢复到 {ready:%m-%d %H:%M}"
    for reason in (
        _copilot_blackout_reason(config),
        depot_window_reason(moment),
        min_lead_reason(config, moment),
    ):
        if reason:
            return reason
    if is_run_locked():
        return "另一场 MAA 正在运行（run.lock 被占）"
    online, detail = maa_playcover.game_is_online(config)
    if online:
        return f"明日方舟正在运行：{detail}"
    return ""


def publish_round(
    token: str,
    entries: list[dict[str, Any]],
    config: Config,
    *,
    title: str,
    scheduled_at: str = "",
    note: str = "",
    pause_button: bool = False,
) -> str:
    """发一张「已排程」卡并登记它的按钮（「取消本轮」，自动轮另有「暂停自动作业」），返回 message_id。

    顺序与抄作业卡一致（不变量 #14b）：先删这一 token 的旧登记，再 merge 写新登记。
    """
    embed, components, registry = maa_copilot.build_scheduled_card(
        token, entries, title=title, scheduled_at=scheduled_at, note=note,
        pause_button=pause_button,
    )
    message = discord_request(
        discord_token(),
        "POST",
        f"/channels/{config.get('channel_id', '')}/messages",
        {"embeds": [embed], "components": components,
         "allowed_mentions": {"parse": []}},
    )
    message_id = str(message.get("id", "")) if isinstance(message, dict) else ""
    if not message_id.isdigit():
        raise RuntimeError("Discord 发卡响应缺少消息编号")
    with state_lock():
        buttons = load_json(BUTTONS_PATH, {})
        if not isinstance(buttons, dict):
            raise RuntimeError("共享按钮登记表格式错误")
        maa_copilot.prune_search_buttons(token, buttons)
        buttons.update(registry)
        atomic_write_json(BUTTONS_PATH, buttons)
    return message_id


def dispatch_batch(token: str) -> None:
    """把一轮交给 worker 的 `run-batch`。调用方先把状态原子改成 `queued`。

    手动（`copilot find` → 搜索 worker）与自动（watcher）**共用这一条派发口**，
    执行链因此只有一条（D14）。
    """
    worker = SCRIPTS_DIR / "maa_copilot_worker.py"
    if not worker.is_file():
        raise RuntimeError("maa_copilot_worker.py 尚未部署")
    subprocess.Popen(
        [sys.executable, str(worker), "run-batch", token],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        close_fds=True,
    )


def new_round_token() -> str:
    return _new_search_token()


MAX_FIND_ARGS = 12
AREA_CODE_RE = re.compile(r"^(?P<area>[A-Za-z0-9]+(?:-[A-Za-z]+)?)-(?P<num>\d+)$")


def _area_codes(area: str, index: dict[str, Any]) -> list[str]:
    """`YW-EX` → `YW-EX-1 … YW-EX-8`（按编号排）。只认索引里真有的代号，不猜。"""
    area = str(area or "").strip()[:40]
    codes = []
    for code in (index.get("codes") or {}):
        match = AREA_CODE_RE.fullmatch(str(code))
        if match and match.group("area") == area:
            codes.append((int(match.group("num")), str(code)))
    return [code for _num, code in sorted(codes)]


def _expand_copilot_targets(
    names: list[str], config: Config, prefix: str, activity_key: str
) -> tuple[list[dict[str, Any]], str, str]:
    """手动参数 → `(targets, 拒绝理由, 提示)`；targets 是 `{stage, stage_id, modes}`。

    - 关卡代号：照原样排，已通的关也重打（「再打一遍 SR-6」）。
    - 区域代号（`YW-EX`、`YW`）：展开成这个区域的所有关，**跳过账本里已通的模式**，
      上游导航不到的关丢掉并写进提示。一轮里连着打，游戏只开一次。
    """
    import maa_clearing

    checker = maa_copilot.copilot_nav_checker(config, prefix)
    targets: list[dict[str, Any]] = []
    notes: list[str] = []
    seen: set[str] = set()
    for name in names:
        resolved = valid_copilot_stage(name, config)
        if resolved is not None:
            stage_id, code = resolved
            if code in seen:
                continue
            supported, detail = checker(code)
            if not supported:
                where = "这一关" if len(names) == 1 else code
                return [], f"导航不到{where}，无法抄作业：{detail}", ""
            seen.add(code)
            targets.append({"stage": code, "stage_id": stage_id,
                            "modes": list(maa_clearing.required_modes(code, prefix, config))})
            continue
        index = maa_copilot.load_stage_index(config)
        area = _area_codes(name, index)
        if area and activity_key:
            ledger = maa_copilot.load_ledger(maa_copilot.ledger_path(activity_key))
            ledger_stages = (ledger or {}).get("stages") or {}
        else:
            ledger_stages = {}
        if not area:
            return [], (
                f"关卡 {str(name)[:40]} 不在本地关卡索引里；只接受当期活动关、主线、资源关，"
                "或活动区域（如 YW-EX）。"
            ), ""
        for code in area:
            if code in seen:
                continue
            seen.add(code)
            done = ledger_stages.get(code) if isinstance(ledger_stages, dict) else None
            modes = [
                mode for mode in maa_clearing.required_modes(code, prefix, config)
                if not (isinstance(done, dict) and done.get(mode))
            ]
            if not modes:
                continue
            supported, detail = checker(code)
            if not supported:
                notes.append(f"{code}：{detail}")
                continue
            targets.append({"stage": code, "stage_id": index["codes"][code], "modes": modes})
    if not targets:
        if notes:
            return [], "导航不到这些关，无法抄作业：" + "；".join(notes)[:300], ""
        return [], "这些关账本里都已经通关了，没有要打的。", ""
    return targets, "", ("；跳过 " + "；".join(notes))[:300] if notes else ""


def start_copilot_search(stage: str, *more: str) -> tuple[bool, str, str | None]:
    """手动抄作业：写一份 `pending` 搜索并派后台 worker（<20s，不变量 #6）。

    可以一次给多关或一个区域（`YW-EX`），它们排进**同一轮**：游戏只开一次，
    活动关按解锁链连着打（`_run_activity_round()`）。

    模式按 D7 定：当期活动关普通 + 突袭，资源本 / 主线只有普通。
    **`config.copilot_raid_switch_task` 为空时突袭功能整体关闭**，活动关也只排普通。
    """
    config = load_config()
    activity_key = str(load_json(WATCH_PATH, {}).get("activity_key") or "")
    prefix = maa_copilot._activity_prefix(activity_key)
    targets, refusal, skip_note = _expand_copilot_targets(
        [stage, *more], config, prefix, activity_key
    )
    if refusal:
        return False, refusal, None
    first = targets[0]
    stage_id, code = first["stage_id"], first["stage"]
    in_activity = [bool(prefix and t["stage"].startswith(f"{prefix}-")) for t in targets]
    if len(set(in_activity)) > 1:
        return False, "当期活动关和资源本 / 主线不能排在同一轮，请分开选。", None
    worker = SCRIPTS_DIR / "maa_copilot_worker.py"
    if not worker.is_file():
        return False, "maa_copilot_worker.py 尚未部署。", None
    # 不变量 #13：手动路径同样过闸门，且**在写 `pending` 之前**——被挡就什么都不写、
    # 不派 worker，也不排程（手动轮没人替你重试，排下去只会烂在那里）。
    blocker = dispatch_blocker(config, "", now_beijing())
    if blocker:
        return False, f"{blocker}；请日常 / 对表结束后再点。", None
    # 突袭开关为空时 `required_modes()` 只会给出 `["normal"]`——手动路径同样不许排突袭。
    modes = first["modes"]
    token = _new_search_token()
    maa_copilot.ensure_private_dirs()
    state = {
        "token": token,
        "status": "pending",
        "stage": code,
        "stage_id": stage_id,
        "modes": modes,
        # 一轮多关：worker 逐关匹配作业，按顺序排进同一轮（`stage` / `stage_id` /
        # `modes` 仍是第一关，给只认单关的读者用）。
        "targets": targets,
        "entries": [],
        "message_id": None,
        "created_at": now_beijing().isoformat(),
        "expires_at": (now_beijing() + maa_copilot.SEARCH_TTL).isoformat(),
        "source": "discord",
        # 手动关也带 activity_key：执行前的活动复核靠它判「活动还在不在」。
        # 非活动关（资源本 / 主线）拿到的是空串，那一段复核整个跳过。
        "activity_key": activity_key if prefix and code.startswith(f"{prefix}-") else "",
    }
    atomic_write_json(_search_path(token), state)
    try:
        subprocess.Popen(
            [sys.executable, str(worker), "search", token],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        detail = f"搜索进程派发失败：{type(exc).__name__}: {exc}"
        _mark_search_dispatch_failed(token, detail)
        return False, detail, None
    if len(targets) == 1:
        mode_text = "普通 + 突袭" if len(modes) > 1 else "普通"
        label = f"{code}（{mode_text}）"
    else:
        label = f"{len(targets)} 关（{code} … {targets[-1]['stage']}，同一轮连打）"
    return (
        True,
        f"🔍 正在为 {label}匹配作业；搜到就直接开跑，结果发到频道{skip_note}。",
        token,
    )


def copilot_find(stage: str, *more: str) -> tuple[bool, str]:
    ok, message, _token = start_copilot_search(stage, *more)
    return ok, message


MARK_MODE_ARGS = {"normal": ("normal",), "raid": ("raid",), "all": ("normal", "raid")}


def _ledger_target(stage: str) -> tuple[str, str, str, Config] | str:
    """`(关卡代号, 活动 key, 活动前缀, config)`，或一句拒绝理由。

    活动 key 的取法与 `start_copilot_search()` 完全一致：当期活动关落活动账本，
    非活动关（主线 / 资源本）落 `ledger-standalone.json`。取错文件就等于写进
    一本没人读的账。
    """
    config = load_config()
    resolved = valid_copilot_stage(stage, config)
    if resolved is None:
        return f"关卡 {stage[:40]} 不在本地关卡索引里；只接受当期活动关、主线或资源关。"
    _stage_id, code = resolved
    activity_key = str(load_json(WATCH_PATH, {}).get("activity_key") or "")
    prefix = maa_copilot._activity_prefix(activity_key)
    if not (prefix and code.startswith(f"{prefix}-")):
        activity_key = ""
    return code, activity_key, prefix, config


def copilot_mark_cleared(stage: str, mode_arg: str = "") -> tuple[bool, str]:
    """「SR-7 我自己打过了」→ 写进账本，自动排轮从此跳过这一关。

    不传模式时按 D7 取这一关**要打的模式**（突袭功能关着就只有普通）；
    `normal` / `raid` / `all` 可以指定。只补空位，重复标记幂等。
    """
    target = _ledger_target(stage)
    if isinstance(target, str):
        return False, target
    code, activity_key, prefix, config = target
    import maa_clearing

    mode_key = str(mode_arg or "").strip().lower()
    if mode_key and mode_key not in MARK_MODE_ARGS:
        return False, "模式只接受 normal / raid / all，不传则按当前规则取这一关要打的模式。"
    modes = MARK_MODE_ARGS.get(mode_key) or maa_clearing.required_modes(code, prefix, config)
    with state_lock():
        ledger, _note = maa_copilot.ensure_ledger(activity_key)
        marked = maa_copilot.mark_stage_cleared(ledger, code, modes)
        if marked:
            maa_copilot.save_ledger(ledger, maa_copilot.ledger_path(activity_key))
    labels = "、".join(
        maa_clearing.entry_label(maa_clearing.make_entry(code, mode)) for mode in marked
    )
    if not marked:
        return True, f"ℹ️ {code} 账本里已经记着通关了，没有改动。"
    return True, (
        f"✅ 已把 {labels} 记为手动通关；自动抄作业不再排这一关，"
        f"抄作业卡上会显示 ✅ 已通。标错了可用 `copilot unmark {code}` 撤销。"
    )


def copilot_unmark(stage: str) -> tuple[bool, str]:
    """撤销某关的通关记账（普通 + 突袭），下一轮自动排轮会重新考虑它。"""
    target = _ledger_target(stage)
    if isinstance(target, str):
        return False, target
    code, activity_key, _prefix, _config = target
    with state_lock():
        ledger = maa_copilot.load_ledger(maa_copilot.ledger_path(activity_key))
        cleared = maa_copilot.unmark_stage_cleared(ledger, code) if ledger else []
        if cleared and ledger:
            maa_copilot.save_ledger(ledger, maa_copilot.ledger_path(activity_key))
    if not cleared:
        return True, f"ℹ️ {code} 账本里本来就没有通关记录，没有改动。"
    return True, f"↩️ 已撤销 {code} 的通关记账（{'、'.join(cleared)}）；下一轮自动排轮会重新考虑它。"


def _copilot_card_components(
    options: list[tuple[str, str, str]],
) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    """抄作业卡的一行下拉 + 它的登记项。值仍是不透明编号（不变量 #8）。"""
    if not options:
        # Discord 拒绝零选项的下拉；没有可抄的关就只发一览，不发控件。
        return [], {}
    select_args: dict[str, list[str]] = {}
    select_options: list[dict[str, Any]] = []
    for index, (label, stage, description) in enumerate(options):
        value = f"choice:{index}"
        select_options.append(
            {
                "label": label[:100],
                "value": value,
                "description": description[:100],
                "emoji": {"name": "🤖"},
            }
        )
        select_args[value] = ["copilot", "find", stage]
    custom_id = f"{maa_copilot.CARD_BUTTON_PREFIX}stage-select"
    rows = [
        {
            "type": 1,
            "components": [
                {
                    "type": 3,
                    "custom_id": custom_id,
                    "placeholder": "🤖 选一关，选中即开始搜作业",
                    "min_values": 1,
                    "max_values": 1,
                    "options": select_options,
                }
            ],
        }
    ]
    entries = {
        custom_id: {
            "kind": "exec",
            "script": "maa_action.py",
            "select_args": select_args,
        }
    }
    return rows, entries


def copilot_card() -> tuple[bool, str]:
    """发一张「现在能抄的关」卡（D6 的卡片部分）。

    只读本地数据、一次 Discord POST，因此可以在动作脚本里同步做完，
    不必派 worker（不变量 #6 的 20s 预算够）。
    """
    from maa_plan_card import copilot_card_view

    config = load_config()
    channel_id = str(config.get("channel_id", "")).strip()
    if not channel_id.isdigit():
        return False, "config.json 中尚未配置 Discord channel_id。"
    embed, options = copilot_card_view(config)
    rows, entries = _copilot_card_components(options)

    maa_copilot.ensure_private_dirs()
    previous = load_json(maa_copilot.CARD_PATH, {})
    warning = ""
    # 先收旧卡：组件 PATCH 空 → 删旧登记 → 再写新登记。反过来做会出现
    # 「旧卡还挂着按钮、登记已经指向新卡」的一段窗口。
    try:
        retire_discord_components(
            config, previous.get("message_id") if isinstance(previous, dict) else None
        )
    except Exception as exc:  # noqa: BLE001 — (c) 收上一张卡的按钮尽力而为，失败只附在回执里
        warning = f"；上一张卡的按钮收起失败：{type(exc).__name__}: {exc}"
    with state_lock():
        registry = load_json(BUTTONS_PATH, {})
        if not isinstance(registry, dict):
            raise RuntimeError("共享按钮登记表格式错误")
        for custom_id in [
            key
            for key in registry
            if key.startswith(maa_copilot.CARD_BUTTON_PREFIX)
        ]:
            registry.pop(custom_id)
        registry.update(entries)
        atomic_write_json(BUTTONS_PATH, registry)

    message = discord_request(
        discord_token(),
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [embed],
            "components": rows,
            "allowed_mentions": {"parse": []},
        },
    )
    atomic_write_json(
        maa_copilot.CARD_PATH,
        {
            "message_id": str(message.get("id", "")) if isinstance(message, dict) else "",
            "posted_at": now_beijing().isoformat(),
        },
    )
    if not options:
        return True, f"🤖 抄作业卡已发；当前没有上游写了导航定义的关可抄{warning}。"
    return True, f"🤖 抄作业卡已发，共 {len(options)} 关可选{warning}。"


# ---------------------------------------------------------------------------
# 场次时间与 cron（K6）—— 只给 Wado's MAA 用，不进 Discord 登记表
# ---------------------------------------------------------------------------


def _hermes_bin(config: Config) -> str:
    return require_executable(
        config, "hermes_bin", str(Path.home() / ".local" / "bin" / "hermes"), "hermes"
    )


def _schedule_text(report: dict[str, Any]) -> str:
    lines = []
    for phase, item in report["sessions"].items():
        state = "开" if item["enabled"] else "关"
        drift = [
            f"{maa_schedule.SCRIPT_NAMES[script]} cron 是 {task['expr'] or '（找不到）'}"
            f"{'' if task['enabled'] else '（暂停）'}"
            for script, task in item["cron"].items()
            if not task["in_sync"]
        ]
        tail = f"；与配置不一致：{'、'.join(drift)}" if drift else ""
        lines.append(f"· {PHASE_NAMES[phase]} {item['time']}（{state}）{tail}")
    return "场次时间：\n" + "\n".join(lines)


def schedule_show() -> tuple[bool, str, dict[str, Any]]:
    report = maa_schedule.schedule_report(load_config())
    return True, _schedule_text(report), report


def _schedule_write(
    phase: str, *, time_value: str | None = None, enabled: bool | None = None
) -> tuple[bool, str, dict[str, Any]]:
    if not valid_phase(phase):
        ok, message = _reject_phase(phase)
        return ok, message, {}
    config = load_config()
    current = maa_common.session_schedule(config)
    slot = dict(current[phase])
    if time_value is not None:
        slot["time"] = time_value
    if enabled is not None:
        slot["enabled"] = enabled
    try:
        updated = maa_common.validate_session_schedule({**current, phase: slot})
    except ValueError as exc:
        return False, str(exc), {}
    if updated == current and config.get("session_schedule") == updated:
        changed_config = config
    else:
        changed_config = maa_common.update_config({"session_schedule": updated}, action_source())
    label = maa_common.session_label(changed_config, phase)
    try:
        notes = maa_schedule.sync_phase(
            changed_config, phase, _hermes_bin(changed_config), toggle=enabled is not None
        )
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        report = maa_schedule.schedule_report(changed_config)
        return False, f"{label}已写进配置，但 cron 没同步上：{exc}。修好后点「同步 cron」。", report
    report = maa_schedule.schedule_report(changed_config)
    state = "开" if updated[phase]["enabled"] else "关"
    synced = f"cron：{'；'.join(notes)}" if notes else "cron 本来就是这个时间"
    return True, f"{label}（{state}）已保存；{synced}。", report


def schedule_set(phase: str, value: str) -> tuple[bool, str, dict[str, Any]]:
    return _schedule_write(phase, time_value=value)


def schedule_toggle(phase: str, enabled: bool) -> tuple[bool, str, dict[str, Any]]:
    return _schedule_write(phase, enabled=enabled)


def schedule_sync() -> tuple[bool, str, dict[str, Any]]:
    """只把 cron 的**时间**对齐到配置，不碰暂停状态。"""
    config = load_config()
    hermes = _hermes_bin(config)
    notes: list[str] = []
    for phase in PLAN_PHASES:
        notes.extend(maa_schedule.sync_phase(config, phase, hermes))
    report = maa_schedule.schedule_report(config)
    return True, ("cron 已同步：" + "；".join(notes)) if notes else "cron 和配置一致。", report


# ---------------------------------------------------------------------------
# 抄作业预览（K13）—— 只给 Wado's MAA 用：先搜、给人看全部候选，点「确认开打」才派发
# ---------------------------------------------------------------------------

PREVIEW_CANDIDATE_LIMIT = 60


def _preview_path(token: str) -> Path:
    return maa_copilot.PREVIEWS_DIR / f"{token}.json"


def _prune_previews(now: datetime) -> None:
    for path in maa_copilot.PREVIEWS_DIR.glob("*.json"):
        state = load_json(path, {})
        try:
            expires = datetime.fromisoformat(str(state.get("expires_at")))
        except (AttributeError, TypeError, ValueError):
            expires = now - timedelta(seconds=1)
        if now > expires:
            path.unlink(missing_ok=True)


def copilot_preview(stage: str) -> tuple[bool, str, dict[str, Any]]:
    """`copilot preview <关>`：只搜不派发，返回全部候选（是否完全满足、缺什么）和一个 token。

    搜索要 5～20 秒，**只给 GUI 用**，不进 Discord 的 20 秒回执路径（不变量 #6）。森空岛刷新
    失败照旧直接报错，不降级（不变量 #18）；只有完全满足的作业能被选（`maa_copilot.is_perfect`）。
    """
    from maa_copilot_worker import _stage_cost  # 理智查表只有一份实现（不变量 #45）

    config = load_config()
    activity_key = str(load_json(WATCH_PATH, {}).get("activity_key") or "")
    prefix = maa_copilot._activity_prefix(activity_key)
    targets, refusal, _ = _expand_copilot_targets([stage], config, prefix, activity_key)
    if refusal:
        return False, refusal, {}
    if len(targets) != 1:
        return False, "预览一次只看一关，请选具体的关卡而不是区域。", {}
    target = targets[0]
    code, stage_id = target["stage"], target["stage_id"]
    now = now_beijing()
    maa_copilot.ensure_private_dirs()
    with maa_copilot.SEARCH_LOCK_PATH.open("a+", encoding="utf-8") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False, "已有另一项作业正在匹配，请稍后再试。", {}
        import maa_skland

        try:
            maa_skland.refresh_roster()
        except Exception as exc:  # noqa: BLE001 — (a) 转译：任何失败都包成回执，不降级
            return False, f"森空岛练度与理智刷新失败，不降级预览：{type(exc).__name__}: {exc}", {}
        roster = maa_copilot.load_roster()
        candidates = maa_copilot.search_copilots(
            stage_id, code, config, roster, limit=1000, use_cache=False
        )
        cost = _stage_cost(stage_id, code, config)
    shown = candidates[:PREVIEW_CANDIDATE_LIMIT]
    perfect = [int(c["id"]) for c in candidates if maa_copilot.is_perfect(c)]
    best = perfect[0] if perfect else None
    token = _new_search_token()
    blocker = dispatch_blocker(config, "", now_beijing())
    state = {
        "token": token,
        "status": "previewed",
        "stage": code,
        "stage_id": stage_id,
        "modes": target["modes"],
        "sanity_cost": cost,
        "activity_key": activity_key if prefix and code.startswith(f"{prefix}-") else "",
        "candidates": [c for c in candidates if int(c["id"]) in perfect][:PREVIEW_CANDIDATE_LIMIT],
        "best_id": best,
        "created_at": now.isoformat(),
        "expires_at": (now + maa_copilot.PREVIEW_TTL).isoformat(),
    }
    _prune_previews(now)
    atomic_write_json(_preview_path(token), state)
    os.chmod(_preview_path(token), 0o600)
    data = {
        "token": token,
        "stage": code,
        "modes": target["modes"],
        "sanity_cost": cost,
        "best_id": best,
        "blocker": blocker,
        "expires_at": state["expires_at"],
        "total": len(candidates),
        "candidates": [
            {**{k: c.get(k) for k in ("id", "title", "uploader", "ratio", "gaps", "soft_gaps",
                                      "views", "rating_ratio", "minimum_required")},
             "perfect": maa_copilot.is_perfect(c)}
            for c in shown
        ],
    }
    if best is None:
        head = f"{code} 搜到 {len(candidates)} 份作业，没有完全满足练度的，不能开打。"
    else:
        head = f"{code} 搜到 {len(candidates)} 份作业，{len(perfect)} 份完全满足，已选中最优的一份。"
    return True, head + (f"\n现在不能派发：{blocker}" if blocker else ""), data


def copilot_go(token: str, chosen: str = "") -> tuple[bool, str, dict[str, Any]]:
    """`copilot go <token> [作业 id]`：按预览里选中的**完全满足**的那份派发（K13）。

    过同一个闸门 `dispatch_blocker()`；被挡什么都不写。派发走手动轮的同一条路：
    发「已排程」卡（Discord 上能「取消本轮」）→ `queued` → `dispatch_batch()`。
    """
    if not maa_copilot.SEARCH_TOKEN_RE.fullmatch(token or ""):
        return False, "预览 token 不对。", {}
    preview = load_json(_preview_path(token), {})
    if not isinstance(preview, dict) or preview.get("status") != "previewed":
        return False, "这次预览已失效（用过了或过期），请重新预览。", {}
    now = now_beijing()
    try:
        expires = datetime.fromisoformat(str(preview.get("expires_at")))
    except (TypeError, ValueError):
        expires = now - timedelta(seconds=1)
    if now > expires:
        _preview_path(token).unlink(missing_ok=True)
        return False, "这次预览已过期，请重新预览（作业和练度都可能变了）。", {}
    pool = {int(c["id"]): c for c in preview.get("candidates") or [] if isinstance(c, dict)}
    wanted = int(chosen) if chosen.isdigit() else preview.get("best_id")
    candidate = pool.get(int(wanted)) if isinstance(wanted, int) else None
    if candidate is None or not maa_copilot.is_perfect(candidate):
        return False, "只能选完全满足练度、没有任何缺口的作业。", {}
    cost = preview.get("sanity_cost")
    if not isinstance(cost, int):
        return False, f"{preview.get('stage')} 的理智消耗查不到，拒绝执行。", {}
    config = load_config()
    blocker = dispatch_blocker(config, "", now)
    if blocker:
        return False, f"{blocker}；请日常 / 对表结束后再点。", {"blocked": blocker}
    if not (SCRIPTS_DIR / "maa_copilot_worker.py").is_file():
        return False, "maa_copilot_worker.py 尚未部署。", {}
    code = str(preview["stage"])
    entries = [
        {"stage": code, "stage_id": preview["stage_id"], "mode": mode,
         "candidate": candidate, "sanity_cost": cost}
        for mode in preview.get("modes") or ["normal"]
    ]
    search = _new_search_token()
    maa_copilot.ensure_private_dirs()
    message_id = publish_round(
        search, entries, config, title=f"🤖 已排程：{code}",
        note=f"Wado's MAA 预览后确认开打：作业 {candidate['id']}「{candidate.get('title', '')}」。",
    )
    state = {
        "token": search,
        "status": "queued",
        "stage": code,
        "stage_id": preview["stage_id"],
        "modes": preview.get("modes") or ["normal"],
        "targets": [{"stage": code, "stage_id": preview["stage_id"],
                     "modes": preview.get("modes") or ["normal"]}],
        "entries": entries,
        "message_id": message_id,
        "created_at": now.isoformat(),
        "expires_at": (now + maa_copilot.SEARCH_TTL).isoformat(),
        "execution_requested_at": now.isoformat(),
        "source": action_source(),
        "activity_key": preview.get("activity_key") or "",
    }
    atomic_write_json(_search_path(search), state)
    preview["status"] = "dispatched"
    preview["search_token"] = search
    atomic_write_json(_preview_path(token), preview)
    dispatch_batch(search)
    return (
        True,
        f"▶️ 已派发 {code}（作业 {candidate['id']}），Discord 上有「已排程」卡，可以取消本轮。",
        {"token": search, "stage": code, "candidate_id": candidate["id"]},
    )


# ---------------------------------------------------------------------------
# 配置与持久默认值（K3 / K5）—— 只给 Wado's MAA 用
# ---------------------------------------------------------------------------


def config_get() -> tuple[bool, str, dict[str, Any]]:
    data = maa_settings.snapshot(load_config())
    return True, f"可改的配置共 {len(data['fields'])} 项。", data


def config_patch(raw: str) -> tuple[bool, str, dict[str, Any]]:
    """`config patch <JSON 对象>`：一次改多项，全部合规才写。"""
    try:
        updates = json.loads(raw)
    except json.JSONDecodeError as exc:
        return False, f"不是合法的 JSON：{exc.msg}", {}
    if not isinstance(updates, dict):
        return False, "要传一个 JSON 对象：{键: 值}", {}
    try:
        clean = maa_settings.validate_many(updates)
    except ValueError as exc:
        return False, str(exc), {}
    config = maa_common.update_config(clean, action_source())
    labels = "、".join(maa_settings.BY_KEY[key].label for key in clean)
    return True, f"已保存：{labels}。下一场日常生效，正在跑的不受影响。", maa_settings.snapshot(config)


def config_set(key: str, raw: str) -> tuple[bool, str, dict[str, Any]]:
    """`config set <键> <JSON 值>`。"""
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        return False, f"值不是合法的 JSON：{exc.msg}", {}
    return config_patch(json.dumps({key: value}, ensure_ascii=False))


def _defaults_snapshot() -> dict[str, Any]:
    raw = load_json(DEFAULTS_PATH, {})
    plan = normalize_plan(raw if isinstance(raw, dict) else {})
    meta = raw if isinstance(raw, dict) else {}
    return {
        "stage": plan.get("stage", ""),
        "tasks": plan.get("tasks", {}),
        "source": str(meta.get("source") or ""),
        "updated_at": str(meta.get("updated_at") or ""),
    }


def defaults_show() -> tuple[bool, str, dict[str, Any]]:
    data = _defaults_snapshot()
    return True, f"持久默认：刷 {data['stage'] or '上次的本'}。", data


def defaults_set(field: str, *values: str) -> tuple[bool, str, dict[str, Any]]:
    """`defaults set stage <关卡>` / `defaults set task <fight|infrast|recruit|mall|award> <on|off>`。

    `defaults.json` 是每天都生效的底子（今天的覆盖在 `plan.json`）。药和碎石不在这里：
    `normalize_plan()` 每次都强制 expiring / 0（不变量 #1 / #2）。
    """
    config = load_config()
    raw = load_json(DEFAULTS_PATH, {})
    current: dict[str, Any] = dict(normalize_plan(raw if isinstance(raw, dict) else {}))
    if field == "stage" and len(values) == 1:
        stage = values[0]
        if not valid_stage(stage, config):
            return False, f"关卡格式不对：{stage[:20]!r}", {}
        current["stage"] = stage
        what = f"默认关改成 {stage or '上次的本'}"
    elif (
        field == "task"
        and len(values) == 2
        and values[0] in maa_common.DEFAULT_TASKS
        and values[1] in ("on", "off")
    ):
        tasks: dict[str, bool] = dict(current.get("tasks") or {})
        tasks[values[0]] = values[1] == "on"
        current["tasks"] = tasks
        what = f"默认{TASK_NAMES.get(values[0], values[0])}{'开' if values[1] == 'on' else '关'}"
    else:
        return False, (
            "只支持 defaults set stage <关卡> 或 "
            "defaults set task <fight|infrast|recruit|mall|award> <on|off>。"
        ), {}
    now = now_beijing()
    with state_lock():
        written = dict(normalize_plan(current))
        written.pop("skip", None)
        written.update({"source": action_source(), "updated_at": now.isoformat()})
        atomic_write_json(DEFAULTS_PATH, written)
    return True, f"{what}；今天没被覆盖的场次从下一场起生效。", _defaults_snapshot()


TASK_NAMES = {"fight": "清理智", "infrast": "基建", "recruit": "公招", "mall": "信用商店", "award": "领奖"}


def copilot_auto(value: str) -> tuple[bool, str]:
    """`copilot auto off|on|status`：暂停 / 恢复 watcher 的自动作业。

    暂停时顺手作废还没开打的那一轮；已经在打的一轮**不中断当前这一关**
    （打到一半掐掉会白花理智），worker 每关开打前看开关，下一关就停。
    手动 `copilot find` 不受影响。
    """
    value = value.strip().lower()
    if value == "status":
        paused = maa_copilot.auto_pause_state()
        if paused:
            return True, f"⏸️ 自动作业已暂停（{str(paused.get('paused_at') or '')[:16]} 起）。"
        return True, "▶️ 自动作业运行中。"
    if value not in {"on", "off"}:
        return False, "用法：copilot auto <on|off|status>"
    if value == "on":
        maa_copilot.set_auto_paused(False)
        # 「今天开打前失败到上限」的停排也一并解除：用户说恢复，就是修好了。
        watch = load_json(WATCH_PATH, {})
        if isinstance(watch, dict) and watch.pop("prefight_failures", None) is not None:
            watch.pop("blocked_reason", None)
            atomic_write_json(WATCH_PATH, watch)
        return True, "▶️ 已恢复自动作业，下一次活动监控（≤15 分钟）重新排轮。"
    maa_copilot.set_auto_paused(True)
    watch = load_json(WATCH_PATH, {})
    token = str(watch.get("batch_token") or "") if isinstance(watch, dict) else ""
    note = ""
    if token:
        search = _load_search(token) or {}
        status = str(search.get("status") or "")
        if status in {"scheduled", "queued"}:
            changed, message_id = maa_copilot.supersede_search(token)
            if changed:
                try:
                    retire_discord_components(load_config(), message_id)
                except Exception as exc:  # noqa: BLE001 — (c) 旧卡按钮已失效，收不掉只附在回执里
                    note = f"（旧卡按钮收起失败但已失效：{type(exc).__name__}）"
                note = "已作废还没开打的一轮" + note + "。"
        elif status == "executing":
            note = "当前这一关打完就停，不会再开下一关。"
    return True, (
        "⏸️ 已暂停自动作业。" + note
        + "恢复：说「恢复自动作业」或 `copilot auto on`。"
    )


def copilot_cancel(token: str) -> tuple[bool, str]:
    config = load_config()
    message_id: Any = None
    with state_lock():
        state = _load_search(token)
        if state is None:
            return False, "找不到这次搜索。"
        if state.get("status") not in maa_copilot.CANCELABLE_STATUSES:
            return False, "本次作业已经失效、开始或结束，不能再取消。"
        state["status"] = "canceled"
        state["canceled_at"] = now_beijing().isoformat()
        message_id = state.get("message_id")
        atomic_write_json(_search_path(token), state)
        registry = load_json(BUTTONS_PATH, {})
        if not isinstance(registry, dict):
            raise RuntimeError("共享按钮登记表格式错误")
        maa_copilot.prune_search_buttons(token, registry)
        atomic_write_json(BUTTONS_PATH, registry)
    try:
        retire_discord_components(config, message_id)
    except Exception as exc:  # noqa: BLE001 — (c) 已取消，收按钮失败只附在回执里
        return (
            True,
            "❌ 已取消；旧卡按钮收起失败但已经不能执行："
            f"{type(exc).__name__}: {exc}",
        )
    return True, "❌ 已取消，相关按钮已清理。"


def copilot_status(token: str) -> tuple[bool, str]:
    state = _load_search(token)
    if state is None:
        return False, "找不到这次搜索（可能已过期）。"
    status = str(state.get("status", ""))
    entries = state.get("entries") or []
    if status == "running":
        return True, "⏳ 还在匹配作业，稍等片刻。"
    if status == "failed":
        return True, f"❌ 未开始：{state.get('error', '未知原因')}"
    if status == "scheduled":
        when = str(state.get("scheduled_at") or "") or "条件满足后立刻开跑"
        return True, f"⏳ 已排程 {len(entries)} 项，预计 {when}。"
    if status == "queued":
        return True, "⏳ 已派发，正在抢锁与开机。"
    if status == "executing":
        return True, f"▶️ 正在执行本轮 {len(entries)} 项。"
    if status == "executed":
        return True, "✅ 本轮已经执行完成，战报在频道里。"
    if status == "execution_failed":
        return True, "❌ 本轮已执行但未全部通过，不会自动重跑；战报里有逐关结果。"
    if status in {"canceled", "superseded"}:
        return True, "⛔ 这一轮已经失效。"
    return True, "⏳ 等待匹配……"


def plan_refresh_card(phase: PlanPhase) -> tuple[bool, str, dict[str, Any]]:
    from maa_plan_card import refresh_card

    return True, refresh_card(phase), {}


def dispatch_gui(argv: list[str]) -> tuple[bool, str, dict[str, Any]] | None:
    """只给 Wado's MAA 用的命令：回执多带一个 `data`（结构化结果）。

    这些命令**不进 Discord 登记表**，也不在技能的命令清单里；不是这类命令返回 None。
    """
    if argv == ["config", "get"]:
        return config_get()
    if argv[:2] == ["config", "set"] and len(argv) == 4:
        return config_set(argv[2], argv[3])
    if argv[:2] == ["config", "patch"] and len(argv) == 3:
        return config_patch(argv[2])
    if argv == ["defaults", "show"]:
        return defaults_show()
    if argv[:2] == ["defaults", "set"] and len(argv) in (4, 5):
        return defaults_set(argv[2], *argv[3:])
    if argv[:2] == ["plan", "refresh-card"] and len(argv) == 3 and valid_phase(argv[2]):
        return plan_refresh_card(argv[2])
    if argv[:2] == ["copilot", "preview"] and len(argv) == 3:
        return copilot_preview(argv[2])
    if argv[:2] == ["copilot", "go"] and len(argv) in (3, 4):
        return copilot_go(argv[2], argv[3] if len(argv) == 4 else "")
    if argv[:2] == ["run", "local"] and 4 <= len(argv) <= 5:
        return run_local(argv[2], argv[3], *argv[4:])
    if argv == ["schedule", "show"]:
        return schedule_show()
    if argv[:2] == ["schedule", "set"] and len(argv) == 4:
        return schedule_set(argv[2], argv[3])
    if argv[:2] in (["schedule", "enable"], ["schedule", "disable"]) and len(argv) == 3:
        return schedule_toggle(argv[2], argv[1] == "enable")
    if argv == ["schedule", "sync"]:
        return schedule_sync()
    return None


def dispatch(argv: list[str]) -> tuple[bool, str]:
    if argv[:2] == ["plan", "set-stage"] and len(argv) == 4:
        return set_stage(argv[2], argv[3])
    if argv[:2] == ["plan", "fight"] and len(argv) == 4:
        return fight_today(argv[2], argv[3])
    if argv[:2] == ["plan", "skip-today"] and len(argv) == 4:
        return skip_today(argv[2], argv[3])
    if argv == ["plan", "show"]:
        return show_plan()
    if argv == ["run", "now"]:
        return run_now()
    if argv[:2] == ["run", "start"] and len(argv) == 4:
        return run_start(argv[2], argv[3])
    if argv[:2] == ["run", "expire"] and len(argv) == 3:
        return run_expire(argv[2])
    if (
        argv[:2] == ["run", "expire"]
        and len(argv) == 5
        and argv[3] == "--after"
        and argv[4].isdigit()
    ):
        return run_expire(argv[2], int(argv[4]))
    if argv[:2] == ["run", "recommend"] and len(argv) == 3:
        return run_recommend(argv[2])
    if argv == ["log", "tail"]:
        return log_tail()
    if argv == ["copilot", "card"]:
        return copilot_card()
    if argv[:2] == ["copilot", "find"] and 3 <= len(argv) <= 2 + MAX_FIND_ARGS:
        return copilot_find(*argv[2:])
    if argv[:2] == ["copilot", "cancel"] and len(argv) == 3:
        return copilot_cancel(argv[2])
    if argv[:2] == ["copilot", "status"] and len(argv) == 3:
        return copilot_status(argv[2])
    if argv[:2] == ["copilot", "mark-cleared"] and len(argv) in (3, 4):
        return copilot_mark_cleared(argv[2], argv[3] if len(argv) == 4 else "")
    if argv[:2] == ["copilot", "unmark"] and len(argv) == 3:
        return copilot_unmark(argv[2])
    if argv[:2] == ["copilot", "auto"] and len(argv) == 3:
        return copilot_auto(argv[2])
    return False, (
        "不支持的动作；只允许 plan set-stage <关卡> <am|pm>、"
        "plan skip-today <on|off> <am|pm>、plan fight <on|off> <am|pm>、plan show、run now、run start <关卡> <token>、"
        "run expire <token> [--after 秒]、run recommend <token>、log tail、"
        "copilot card/find/cancel/status/mark-cleared/unmark、copilot auto <on|off|status>。"
    )


def main(argv: list[str]) -> int:
    try:
        gui = dispatch_gui(argv[1:])
        if gui is not None:
            ok, message, data = gui
        else:
            (ok, message), data = dispatch(argv[1:]), None
    except Exception as exc:  # noqa: BLE001 — (a) 进程顶层：任何失败都要变成 ok=false 回执交给技能
        emit(False, f"操作失败：{type(exc).__name__}: {exc}")
        return 1
    emit(ok, message, data)
    return 0 if ok else 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
