#!/usr/bin/env python3
"""Run one complete MAA daily session and stream its progress to Discord."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, TextIO, cast

import maa_depot
import maa_notify
import maa_playcover
from maa_upstream import hard_block as upstream_hard_block
from maa_common import (
    ACTION_SOURCES,
    BEIJING,
    DEFAULT_TASKS,
    LAST_RUN_PATH,
    LAST_RUN_SCHEMA_VERSION,
    MAA_CONFIG_DIR,
    MANUAL_RUN_PATH,
    MANUAL_RUN_SCHEMA_VERSION,
    RUNS_DIR,
    SAFE_ITEM_ID_RE,
    SAFE_MALL_ITEM_RE,
    SCRIPTS_DIR,
    CANCEL_EXIT_CODE,
    CANCELLED_NOTE,
    Config,
    LastRun,
    Phase,
    Plan,
    atomic_write_json,
    atomic_write_text,
    check_schema,
    append_run_index,
    cleanup_run_files,
    create_thread,
    discord_request,
    discord_token,
    discord_upload,
    effective_plan,
    interrupt_once,
    is_phase,
    is_plan_phase,
    load_config,
    load_json,
    maa_subprocess_env,
    make_run_id,
    medicine_label,
    merge_last_run,
    now_beijing,
    plan_stage_label,
    report_game_busy as common_report_game_busy,
    require_executable,
    lock_holder_text,
    run_lock,
    run_lock_holder,
    state_lock,
)


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
# 信用商店 `buy_first` / `blacklist` 的物品名白名单（四期步骤 5）。这两个列表来自
# `config.json`，会**原样变成 TOML 字符串**交给 MaaCore 去 OCR 比对，所以渲染器
# 只接受「中日文字 + 拉丁字母 + 数字 + 少数分隔符」，长度 ≤ 20。校验不过的项
# **静默丢弃**：一个写歪的物品名不该让整场日常渲染不出来（D-2 的教训）。
# 　-鿿 = CJK 标点 + 假名 + 汉字；· / ・ 是「技能概要·卷1」的中点。
PHASE_LABELS = {"am": "早", "pm": "晚", "now": "手动"}
# Only the cron-driven phases defer to a running game. `now` is the user
# saying "run it right now" and must never be probe-skipped (PLAN_NAV_GATE B-1).
AUTO_PHASES = frozenset({"am", "pm"})
TASK_STEPS = (
    ("StartUp", "🚀", "登录与首登领取", "正在登录并处理首登弹窗"),
    ("Annihilation", "☄️", "每日剿灭", "正在用代理卡全权委托清剿灭"),
    ("Fight", "⚔️", "刷理智", "正在刷理智"),
    # 第二个刷理智块（四期步骤 3b）：第一个块刷够 `drops` 上限就停，剩下的理智
    # 交给它。**key 故意不叫 `Fight`**——`_task_state()` 认不出命名段时会退回
    # `"<key> Completed"` 这条通配，两个块共用 `Fight` 会让没跑过的第二块被判成完成。
    ("Fight2", "⚔️", "刷理智·续", "正在刷第二个关"),
    ("Infrast", "🏭", "基建换班", "正在根据干员心情自动排班"),
    ("Recruit", "🎫", "公开招募", "正在处理公开招募"),
    ("Mall", "🛒", "信用商店", "正在领取信用并购买物资"),
    ("Award", "🎁", "领取奖励", "正在领取日常、周常与全部邮件奖励"),
    ("Custom", "🏠", "返回主界面", "正在返回游戏主界面，准备截图"),
)

# MAA 的 QuickSwitch 是子程序：点完小房子里的首页图标后，只能靠 next 里的 `#back`
# 回到调用方来确认成功，而 `#back` 取的是任务名第一个 `@` 之前的前缀。裸写
# "QuickSwitch@ToHome" 时前缀是并不存在的 "QuickSwitch"，`#back` 被静默丢弃
# （日志里 to_be_recognized 只剩 4 项，json 里是 5 项），于是画面已经回到主页却没有
# 任何任务能判定成功，空转到 20 次重试耗尽报 Custom Error——2026-08-02、08-03 两个
# 早场都是这样红的。加上 "Home@" 前缀后 `#back` → "Home"（action = Stop），认出主页
# 立即成功收尾。这里手工展开 MAA 自己用的
# ["Home@QuickSwitch@ToHome#next", "Home@ReturnButtons#next"]，因为顶层 task_names 是
# 原样交给 ProcessTask 的，不走 next 列表那套 `#` 展开。
HOME_TASK_NAMES = [
    "Home",
    "Home@QuickSwitch@ToHome@Entry",
    "Home@QuickSwitch@ToHome@Open",
    "Home@ReturnButton",
    "Home@FromStageSN",
    "Home@FromAnnihilation",
]
# 主页面独有的入口，用本机 Vision OCR（ocrbox）核对截图确实停在主页。每个入口认中文或
# 英文副标题之一（英文不分大小写），按**入口**计数：联动界面主题会把中文换成花字，
# OCR 读成碎字（2026-11-04 三丽鸥主题下「终端」→「TERMiN」、「采购中心」→「…葉购中心」，
# 旧的 8 个词只命中 3 个，好好的主页被判红），英文副标题却还在。
# 「任务」「干员」不收：任务列表页满屏都是这两个词；那一页也有「好友」，所以要过半才算数。
HOME_MARKERS = (
    ("终端", "TERMIN"),
    ("编队", "SQUADS", "SOUADS"),
    ("采购中心", "STORE"),
    ("公开招募", "RECRUIT"),
    ("干员寻访", "HEADHUNT"),
    ("基建", "BASE"),
    ("好友", "FRIENDS"),
    ("档案", "ARCHIVES"),
    ("理智", "SANITY"),
)
HOME_MARKER_MIN = 5

# 代理指挥失误时游戏结算页写「本场战斗已视为单次作战结算，未进行作战的理智已返还」，
# 并把返还的理智画成一个道具图标。MaaCore 照单全收，于是日志里出现
# `Drops: 理智 × 105`、汇总成 `total drops: 理智 × 315`。理智永远不可能是关卡掉落，
# 所以掉落项里出现「理智」= 这一批代理失败、理智原路退回、一关没打成。
# 2026-08-07 早场 TO-9 连着 4 批都栽在这里，MaaCore 仍判 Fight Completed，
# 战报因此写成「✅ 完成（16 次；掉落 理智 ×315）」——见 DEV_GUIDE §11.13。
SANITY_REFUND_ITEM = "理智"
# maa run 被熔断中止时的返回码，跟超时的 124、人工中止的 130 区分开。
PROXY_BREAK_CODE = 125
# MaaCore 连接阶段就失败的标记。PlayCover 下 MaaCore 直连游戏进程里的 MaaTools
# （127.0.0.1:1717）：游戏刚拉起时端口可能还没监听，或者游戏窗口被台前调度收进
# 侧边栏、SCRN 回 0 字节 → 报 ConnectFailed / ScreencapFailed。maa-cli 不看 connect
# 的返回值，照样 Assistant::start()，maa run 很快退出。此时一个键都没点过，先把窗口
# 摆回台前再重开一趟是安全的。
CONNECT_FAILURE_MARKERS = (
    "TouchModeNotAvailable",
    "ConnectFailed",
    "Connect failed",
    "ScreencapFailed",
)
# PlayCover 下截图从头到尾一帧都没拿到时，MaaCore 照样把每条任务链跑成 Error 并打印
# `AllTasksCompleted`（2026-11-08 早场）。日志里**只有**这些行时，那句收尾话不算「有任务
# 跑完」——一帧画面都没有，不可能点过任何东西。出现任何一行别的输出就照旧不重开。
NO_FRAME_LINE_RES = tuple(
    re.compile(pattern)
    for pattern in (
        r"Updating hot update files\.\.\.",
        r"Hot update completed successfully",
        r"Detected connection with PlayTools",
        r"Using platform diff resource: \S+",
        r"Game is already running!",
        r"\w+ (Start|Error)",
        r"AllTasksCompleted",
        r"Summary",
        r"-+",
        r"\[[^\]]+\] \d{2}:\d{2}:\d{2} - \d{2}:\d{2}:\d{2} \([^)]*\) Error",
        r"Error: Some error occurred during running task!",
    )
)
# 跑到一半截图失败、摆窗后写进日志的那行说明的开头（也是 NO_FRAME 白名单里唯一的自家行）。
SCREENCAP_SETTLE_NOTE = "截图失败，已尝试把游戏窗口摆回台前。"
# `run_maa_resilient()` 放弃重开时说明里的固定词，调用方据此判断「游戏画面一直拿不到」。
CONNECT_GAVE_UP = "仍未连上"
SCREEN_LOST_SKIP_NOTE = "游戏画面一直拿不到，补跑跳过。"
# maa-cli 认出掉线弹窗（`OfflineConfirm`：「获取网络配置失败，请重新登录」等）时打的行。
# MaaCore v6.22 起 StartUp 以外的任务撞上它就 `Stop`，被停的任务照样报 Completed；
# StartUp 点确认 6 次后也报 Completed（2026-11-09 早场）。点确认不会让游戏重新拉网络
# 配置，只有重启游戏进程才会。
GAME_OFFLINE_MARKER = "GameOffline"
# `run_maa_resilient()` 放弃「没登录上」重开时说明里的固定词，调用方据此跳过补跑。
OFFLINE_GAVE_UP = "仍未登录上"
OFFLINE_SKIP_NOTE = "游戏一直没登录上，补跑跳过。"
# 重启游戏本身要的时间（TERM 退出约 30s + 拉起 + 等 MaaTools），算预算时一并扣掉。
RESTART_ALLOWANCE_SECONDS = 90
# 重启前的连通性探测：只说明「连得上」，连上了却拿不到配置（11-09 就是这样）照样显示通，
# 只当排障线索写进运行日志，不当闸门。
CONF_PROBE_URL = "https://ak-conf.hypergryph.com/"
CONF_PROBE_TIMEOUT = 5
# 跑到一半游戏进程退出或换了一个（不变量 #68）：MaaCore 连的旧进程没了、不会重连，
# 我们停掉 maa run 时写这个返回码。
GAME_EXITED_CODE = 126
# 停掉那一趟时写进日志的说明开头；战报、失败原因和次数统计都按它认。
GAME_EXITED_NOTE = "游戏中途退出"
# `run_maa_resilient()` 放弃「游戏中途退出」重开时说明里的固定词，调用方据此跳过补跑。
GAME_EXIT_GAVE_UP = "不再重开"
GAME_EXIT_SKIP_NOTE = "游戏中途退出、没能接着跑完，补跑跳过。"
# 这几个返回码是本脚本自己写上去的，不是「没连上」——重开一趟只会重复同一件事。
SELF_ASSIGNED_CODES = (124, PROXY_BREAK_CODE, GAME_EXITED_CODE, 130)
# 进度消息的编辑节流，同时也是熔断的采样间隔——扫一遍全部日志行不便宜，
# 不能放进 0.25 秒的主循环里跑。
PROGRESS_INTERVAL_SECONDS = 5
# 跑到一半截图失败时，两次「把游戏窗口摆回台前」之间至少隔这么久。
SCREENCAP_SETTLE_INTERVAL = 30
# maa run 的最短存活时间：配置写歪了也不能让整条链条秒退。
MIN_RUN_TIMEOUT_SECONDS = 60
# 国服日刷新 04:00。剿灭按游戏日只进一次，避免早晚场各刷一轮。
CN_GAME_DAY_RESET = timedelta(hours=4)
# 周合成玉上限。开跑前按森空岛 `campaign.reward` 判本周是否已满（`attach_annihilation()`），
# 已满就不进剿灭；没读到时照常进，由 MaaCore 自己停。
ANNIHILATION_WEEKLY_ORUNDUM = 1800
# maa-cli 最终汇总用任务名；旧日志仍是「每周剿灭」。
ANNIHILATION_TASK_NAMES = ("每日剿灭", "每周剿灭")
# 两个刷理智块的任务名。渲染器、战报解析、掉落回写三处**共用这一份**，
# 名字改了不会有哪一处偷偷对不上。
FARMING_TASK_NAMES = ("刷理智", "刷理智·续")


MANUAL_TOKEN_RE = re.compile(r"^[0-9a-f]{12}$")


def manual_token_from_argv(argv: list[str]) -> str:
    """`maa_daily.py now <token>` 的 token（`PLAN_MANUAL_RUN.md` M-e）；其余形式返回空串。"""
    if len(argv) == 3 and argv[1] == "now" and MANUAL_TOKEN_RE.fullmatch(argv[2] or ""):
        return argv[2]
    return ""


def select_phase(argv: list[str], at: datetime | None = None, cwd: Path | None = None) -> Phase:
    # `is_phase()` 与 `PHASE_LABELS` 的键是同一组（am / pm / now）。
    if len(argv) == 2 and is_phase(argv[1]):
        return argv[1]
    if manual_token_from_argv(argv):
        return "now"
    if len(argv) > 1:
        raise ValueError("场次只接受 am、pm 或 now（now 后可跟一个选关请求 token）")
    marker = (cwd or Path.cwd()).name.lower()
    if is_plan_phase(marker):
        return marker
    hour = (at or now_beijing()).hour
    if 7 <= hour < 14:
        return "am"
    if 20 <= hour or hour < 2:
        return "pm"
    return "now"


def cn_game_day(at: datetime | None = None) -> str:
    """Official-server calendar date: resets at 04:00 Beijing time."""
    moment = at or now_beijing()
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=BEIJING)
    return (moment.astimezone(BEIJING) - CN_GAME_DAY_RESET).date().isoformat()


def should_run_annihilation(
    plan: Plan,
    at: datetime | None = None,
    last_run: LastRun | dict[str, Any] | None = None,
) -> bool:
    """Include annihilation in this run: fight is on, and not yet done this game day."""
    if not bool(plan.get("tasks", {}).get("fight", True)):
        return False
    state = last_run if isinstance(last_run, dict) else {}
    return str(state.get("annihilation_game_day") or "") != cn_game_day(at)


def cn_game_week(at: datetime | None = None) -> str:
    """国服周刷新（周一 04:00）所在周的周一日期；剿灭合成玉上限按它记。"""
    day = datetime.fromisoformat(cn_game_day(at)).date()
    return (day - timedelta(days=day.weekday())).isoformat()


def annihilation_weekly_full(
    roster: dict[str, Any] | None, at: datetime | None = None
) -> tuple[int, int] | None:
    """森空岛快照显示**本周**剿灭合成玉已满时返回 `(current, total)`，否则 None。

    快照是上一周的、字段缺失或坏掉一律 None（照常打）：同一周里 current 只增不减，
    旧快照只会少判「已满」，不会把没打满的一周错判成跳过。
    """
    weekly = (roster or {}).get("annihilation_weekly")
    if not isinstance(weekly, dict):
        return None
    try:
        current = int(weekly["current"])
        total = int(weekly["total"])
        fetched = datetime.fromtimestamp(int(weekly["server_current_at"]), BEIJING)
    except (KeyError, TypeError, ValueError, OverflowError, OSError):
        return None
    if total <= 0 or current < total:
        return None
    if cn_game_week(fetched) != cn_game_week(at):
        return None
    return current, total


def attach_annihilation(
    plan: Plan,
    at: datetime | None = None,
    last_run: LastRun | dict[str, Any] | None = None,
    roster: dict[str, Any] | None = None,
) -> Plan:
    """Return a per-run plan copy with the once-per-game-day annihilation flag.

    `roster` 不传时读森空岛快照（`roster.json`，不读 OperBox 后备——那份没有剿灭进度）。
    本周已满就摘掉剿灭并带上 `annihilation_skip_reason`；读不到一律照常打。
    """
    if not should_run_annihilation(plan, at, last_run):
        return {**plan, "annihilation": False}
    if roster is None:
        try:
            import maa_copilot

            loaded = load_json(maa_copilot.ROSTER_PATH, None)
        except (ValueError, OSError):
            loaded = None
        roster = loaded if isinstance(loaded, dict) else {}
    full = annihilation_weekly_full(roster, at)
    if full is None:
        return {**plan, "annihilation": True}
    return {
        **plan,
        "annihilation": False,
        "annihilation_skip_reason": f"本周剿灭合成玉已满（{full[0]}/{full[1]}），本场跳过",
    }


def attach_sanity_yield(
    plan: Plan,
    config: Config,
    at: datetime | None = None,
) -> Plan:
    """理智不够刷默认关时把「刷理智」让出来，保留剿灭（四期 D11）。

    自动抄作业跑完常常把理智打到个位数，这时候再开一个 Fight 只会空转一次
    连战识别。判据只有一条：**估算理智 < 默认关的 `apCost`**。

    **估不出来一律照常刷**（森空岛不可用、关卡不在 `stages.json`、状态文件坏掉）——
    宁可多刷一场，也不能因为读不出数就一整天什么都不打（不变量 #26 的精神）。
    """
    try:
        import maa_copilot

        stage = str(plan.get("stage") or "")
        index = maa_copilot.load_stage_index(config)
        resolved = maa_copilot.resolve_copilot_stage(stage, index)
        cost = (
            maa_copilot.stage_sanity_cost(resolved[0], resolved[1], config)
            if resolved
            else None
        )
        roster = maa_copilot.load_roster()
        snapshot = (roster or {}).get("sanity")
        sanity = maa_copilot.estimated_sanity(
            snapshot if isinstance(snapshot, dict) else {}, at
        )
        if cost is None or sanity is None or sanity >= cost:
            return {**plan, "farming": True}
        return {
            **plan,
            "farming": False,
            "farming_skip_reason": (
                f"理智 {sanity} 不足以刷 {stage}（需 {cost}），本场跳过刷理智；"
                "剿灭 / 基建 / 公招 / 商店 / 领奖照常。"
            ),
        }
    except Exception as exc:  # noqa: BLE001 — (c) 估不出理智一律照常刷（不变量 #26）
        print(
            f"理智让路判定失败，本场照常刷理智：{type(exc).__name__}: {exc}",
            flush=True,
        )
        return {**plan, "farming": True}


def annihilation_consumed(lines: list[str]) -> bool:
    """True when today's annihilation slot was used and must not run again today.

    Named maa-cli summaries and Annihilation Start are the hard signals. If
    StartUp already completed, the next task in the rendered chain is
    annihilation, so later sessions in the same game day must not retry it.
    """
    if any(f"[{name}]" in line for line in lines for name in ANNIHILATION_TASK_NAMES):
        return True
    if any("Annihilation Start" in line or "Fight Annihilation" in line for line in lines):
        return True
    return _task_state(lines, "StartUp", "登录与首登领取") == "completed"


def _toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _toml_bool(value: Any) -> str:
    """配置里的布尔开关 → TOML 字面量。非布尔（写歪了）一律按 false。"""
    return "true" if value is True else "false"


def _drops_table(value: Any) -> str:
    """`{itemId: 数量}` → MaaCore Fight 的 `drops` 内联表；没上限就返回空串。

    `drops` 是上游参数「刷到这么多个就停」。数量来自材料缺口（四期步骤 3a），
    冷启动或缺口 ≤ 0 时 `farming_drops` 本来就是空的，这里也就不写这一行。
    itemId 在 `maa_common.normalize_plan()` 里已经过 `SAFE_ITEM_ID_RE`，
    这里再挡一次——渲染器不接受没校验过的表键。
    """
    if not isinstance(value, dict) or not value:
        return ""
    pairs: list[str] = []
    for item_id, quantity in sorted(value.items()):
        try:
            count = int(quantity)
        except (TypeError, ValueError):
            continue
        if count <= 0 or not SAFE_ITEM_ID_RE.match(str(item_id)):
            continue
        pairs.append(f"{_toml_string(str(item_id))} = {count}")
    return "{ " + ", ".join(pairs) + " }" if pairs else ""


def _mall_item_list(value: Any) -> str:
    """`config` 里的物品名列表 → TOML 数组；**过不了白名单的项直接丢掉**。

    这两个列表（`mall_buy_first` / `mall_blacklist`）会原样进任务文件交给 MaaCore
    去 OCR 比对，所以渲染器不接受没校验过的字符串（DEV_GUIDE §8 不变量 #51）。
    """
    if not isinstance(value, list):
        return "[]"
    names = [
        str(item)
        for item in value
        if isinstance(item, str) and SAFE_MALL_ITEM_RE.match(item)
    ]
    return "[" + ", ".join(_toml_string(name) for name in names) + "]"


def _report_lines(config: Config) -> str:
    """掉落匿名上报（一图流 / 企鹅物流）。总开关 `report_drops`，默认开。

    ID 一律留空 = 匿名上报，不带任何账号标识；数据回馈的正是本项目自己
    在用的那两个掉落源（四期步骤 3）。
    """
    if not bool(config.get("report_drops", True)):
        return ""
    return (
        "report_to_penguin = true\n"
        # 两个 ID 的协议默认就是空串（上游 `integration.md`）。这里**显式写出来**：
        # 匿名是这条功能的前提，不能让它取决于「默认值将来会不会变」。
        'penguin_id = ""\n'
        "report_to_yituliu = true\n"
        'yituliu_id = ""\n'
    )


def _fight_block(
    name: str,
    stage: str,
    config: Config,
    medicine_days: int,
    *,
    drops: str,
) -> str:
    """一个 Fight 块。剿灭与两个刷理智块**共用这一份**，硬编码字面量只写一次。"""
    return (
        "[[tasks]]\n"
        f"name = {_toml_string(name)}\n"
        'type = "Fight"\n'
        "[tasks.params]\n"
        f"stage = {_toml_string(stage)}\n"
        "medicine = 0\n"
        f"medicine_expire_days = {max(0, medicine_days)}\n"
        # This literal is not derived from any state or user input.
        "stone = 0\n"
        # Let MaaCore select the largest series currently affordable in
        # the connected client instead of forcing a fixed multiplier.
        "series = 0\n"
        f"times = {int(config.get('fight_times', 2147483647))}\n"
        + (f"drops = {drops}\n" if drops else "")
        + 'server = "CN"\n'
        'client_type = "Official"\n'
        + _report_lines(config)
    )


def render_daily_toml(plan: Plan, config: Config) -> str:
    """Render the exact immutable plan used for this run; no CloseDown task.

    `tasks.fight` is the master switch for both Fight blocks. Below it the two
    blocks have **independent** switches, because理智让路（四期 D11）要在
    摘掉刷理智的同时保留剿灭：

      plan["annihilation"] — 每日剿灭（游戏日一次，由 attach_annihilation 记帐）
      plan["farming"]      — 刷理智（理智不够刷默认关时摘掉；周上限 1800 合成玉的
                             剿灭是代理卡驱动的，摘掉纯亏，所以它不跟着走）
    """
    tasks = plan.get("tasks", {})
    blocks = [
        "[[tasks]]\n"
        'name = "启动国服"\n'
        'type = "StartUp"\n'
        "[tasks.params]\n"
        'client_type = "Official"\n'
        "start_game_enabled = true\n"
    ]
    if tasks.get("fight", True):
        # Fixed safety policy: never use ordinary medicine or Originite Prime;
        # only consume medicine MaaCore identifies as expiring soon.
        medicine_days = max(1, int(config.get("medicine_expire_days", 2)))
        # Default True so the deploy seed and isolated renderer tests still
        # include annihilation. execute() sets the flag from last_run.
        if plan.get("annihilation", True):
            # Fight(Annihilation) turns on 全权委托 and consumes a PRTS
            # 代理指挥卡. MaaCore stops when the weekly 1800 orundum cap is
            # reached (todo gone / cards refused).
            blocks.append(
                _fight_block(
                    "每日剿灭", "Annihilation", config, medicine_days, drops=""
                )
            )
        # Independent switch: 理智让路 removes ONLY this block.
        # Default True so the deploy seed and isolated renderer tests keep it.
        if plan.get("farming", True) and plan.get("fallback_run"):
            # 后备补跑（`fallback_fight_plan()`）：主关的 Fight 一颗理智没花就 Error 了，
            # 这一趟只打后备关。块名用第二块的名字，战报里自然落在「刷理智·续」那一行，
            # 不带 drops——它本来就是拿来把剩余理智花完的。
            blocks.append(
                _fight_block(
                    FARMING_TASK_NAMES[1], str(plan.get("stage", "")), config, medicine_days, drops=""
                )
            )
        elif plan.get("farming", True):
            drops = _drops_table(plan.get("farming_drops"))
            blocks.append(
                _fight_block(
                    FARMING_TASK_NAMES[0],
                    str(plan.get("stage", "")),
                    config,
                    medicine_days,
                    drops=drops,
                )
            )
            # 刷够 `drops` 上限之后 MaaCore 就停了，本场剩下的理智不能白扔：
            # 再渲染一个 Fight 块打第二名的关，**不带 drops**，打到理智不足为止。
            # 没有上限时第一个块本来就会打到理智不足，第二块也就没有意义。
            spare = str(plan.get("farming_fallback_stage") or "")
            if drops and spare:
                blocks.append(
                    _fight_block(
                        FARMING_TASK_NAMES[1], spare, config, medicine_days, drops=""
                    )
                )
    if tasks.get("infrast", True):
        blocks.append(
            "[[tasks]]\n"
            'name = "基建换班"\n'
            'type = "Infrast"\n'
            "[tasks.params]\n"
            # Let MaaCore calculate efficient assignments from the operators
            # and morale currently visible in every shiftable base facility.
            "mode = 0\n"
            'facility = ["Mfg", "Trade", "Power", "Control", "Reception", "Office", "Dorm"]\n'
            'drones = "_NotUse"\n'
            "threshold = 0.3\n"
            "replenish = false\n"
            "dorm_trust_enabled = false\n"
        )
    if tasks.get("recruit", True):
        blocks.append(
            "[[tasks]]\n"
            'name = "公开招募"\n'
            'type = "Recruit"\n'
            "[tasks.params]\n"
            "refresh = true\n"
            "select = [4, 5, 6]\n"
            "confirm = [3, 4, 5, 6]\n"
            f"times = {int(config.get('recruit_times', 4))}\n"
            "set_time = true\n"
            "expedite = false\n"
            'server = "CN"\n'
        )
    if tasks.get("mall", True):
        blocks.append(
            "[[tasks]]\n"
            'name = "信用商店"\n'
            'type = "Mall"\n'
            "[tasks.params]\n"
            "visit_friends = true\n"
            "shopping = true\n"
            "force_shopping_if_credit_full = false\n"
            "credit_fight = false\n"
            # 四期步骤 5：优先买 / 黑名单 / 信用溢出与打折的开关都从配置读。
            # 两个列表过 `SAFE_MALL_ITEM_RE` 白名单，默认空 = 完全沿用旧行为。
            f"buy_first = {_mall_item_list(config.get('mall_buy_first'))}\n"
            f"blacklist = {_mall_item_list(config.get('mall_blacklist'))}\n"
            "reserve_max_credit = "
            f"{_toml_bool(config.get('mall_reserve_max_credit', False))}\n"
            "only_buy_discount = "
            f"{_toml_bool(config.get('mall_only_buy_discount', False))}\n"
        )
    if tasks.get("award", True):
        blocks.append(
            "[[tasks]]\n"
            'name = "领取奖励"\n'
            'type = "Award"\n'
            "[tasks.params]\n"
            "award = true\n"
            "mail = true\n"
            "recruit = false\n"
            # 四期步骤 5：三个「顺手领」开关从配置读，默认全 false（与改造前一致）。
            f"orundum = {_toml_bool(config.get('award_orundum', False))}\n"
            f"mining = {_toml_bool(config.get('award_mining', False))}\n"
            "specialaccess = "
            f"{_toml_bool(config.get('award_specialaccess', False))}\n"
        )
    blocks.append(
        "[[tasks]]\n"
        'name = "返回主界面"\n'
        'type = "Custom"\n'
        "[tasks.params]\n"
        f"task_names = {json.dumps(HOME_TASK_NAMES, ensure_ascii=False)}\n"
    )
    return "\n".join(blocks)


def _format_duration(seconds: float) -> str:
    total = max(0, int(seconds))
    minutes, secs = divmod(total, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {secs}s"
    if minutes:
        return f"{minutes}m {secs}s"
    return f"{secs}s"


def _clean_line(line: str, limit: int = 150) -> str:
    line = ANSI_RE.sub("", line).rstrip().replace("```", "``\u200b`")
    return line if len(line) <= limit else line[: limit - 1] + "…"


def _task_display_names(key: str, label: str) -> tuple[str, ...]:
    if key == "Annihilation":
        return ANNIHILATION_TASK_NAMES
    return (label,)


def farming_sections(lines: list[str]) -> list[str]:
    """两个刷理智块的 maa-cli 汇总段拼在一起（掉落要合并统计，四期步骤 3b）。"""
    section: list[str] = []
    for name in FARMING_TASK_NAMES:
        for part in _named_task_sections(lines, name):
            section += part
    return section


def _task_state(lines: list[str], key: str, label: str) -> str:
    # maa-cli uses the configured task name in its final ``[name]`` summary.
    # Prefer that exact result when multiple tasks share one MaaCore type (the
    # daily annihilation and ordinary farming are both Fight tasks).
    names = _task_display_names(key, label)
    named = [line for line in lines if any(f"[{name}]" in line for name in names)]
    if named:
        if any("Completed" in line for line in named):
            return "completed"
        if any("Stopped" in line or "Error" in line for line in named):
            return "failed"
        return "running"
    if any(
        f"{key} Completed" in line
        or any(f"[{name}]" in line and "Completed" in line for name in names)
        for line in lines
    ):
        return "completed"
    if any(f"{key} Stopped" in line or f"{key} Error" in line for line in lines):
        return "failed"
    if any(f"{key} Start" in line or any(f"[{name}]" in line for name in names) for line in lines):
        return "running"
    return "pending"


def _last_match(lines: list[str], pattern: str) -> re.Match[str] | None:
    compiled = re.compile(pattern, re.IGNORECASE)
    result = None
    for line in lines:
        match = compiled.search(line)
        if match:
            result = match
    return result


def _named_task_sections(lines: list[str], label: str) -> list[list[str]]:
    """每一趟 maa-cli 收尾汇总里 `[label]` 那一段（不含后面的任务）。

    游戏中途退出后接着跑（#68）时同一条链会在两趟汇总里各出现一次，次数和掉落要合起来算。
    一段到下一个 `[名字]` 行或 maa-cli 的分隔线为止。
    """
    sections: list[list[str]] = []
    current: list[str] | None = None
    for line in lines:
        if current is not None and (re.match(r"^\[[^]]+\]", line) or re.fullmatch(r"-{3,}", line.strip())):
            current = None
        if current is None and f"[{label}]" in line:
            current = []
            sections.append(current)
        if current is not None:
            current.append(line)
    return sections


def _named_task_section(lines: list[str], label: str) -> list[str]:
    """Return the first maa-cli final-summary section, excluding later tasks."""
    sections = _named_task_sections(lines, label)
    return sections[0] if sections else []


def _fight_times(lines: list[str]) -> int:
    # Final summaries normally include a stage code (``Fight CE-6 6 times``);
    # older fixture/log shapes omitted it.  Accept both before falling back to
    # streaming Mission-started events.
    summary = _last_match(lines, r"\bFight(?:\s+\S+)?\s+(\d+)\s+times\b")
    if summary:
        return int(summary.group(1))
    return sum(
        int(match.group(1))
        for line in lines
        if (match := re.search(r"Mission started\s*\((\d+)\s+times", line, re.I))
    )


def _expiring_medicine_used(lines: list[str]) -> int:
    summary = _last_match(lines, r"used\s+\d+\s+medicine\s*\((\d+)\s+expiring\)")
    if summary:
        return int(summary.group(1))
    return sum(
        int(match.group(1))
        for line in lines
        if (match := re.search(r"Use\s+(\d+)\s+expiring medicine", line, re.I))
    )


def _parse_drop_items(raw: str) -> list[tuple[str, int]]:
    """Parse one Drops payload into (item, quantity); JSON first, plain text as fallback."""
    parsed: Any = None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        pass
    pairs: list[tuple[str, int]] = []
    if isinstance(parsed, dict):
        pairs = [
            (str(name), int(quantity))
            for name, quantity in parsed.items()
            if isinstance(quantity, (int, float))
        ]
    elif isinstance(parsed, list):
        for item in parsed:
            if not isinstance(item, dict):
                continue
            name = item.get("itemName") or item.get("name")
            quantity = item.get("quantity") or item.get("count")
            if name and isinstance(quantity, (int, float)):
                pairs.append((str(name), int(quantity)))
    if not pairs:
        pairs = [
            (name.strip(" \"'{}[]"), int(quantity))
            for name, quantity in re.findall(
                r"([A-Za-z一-鿿][A-Za-z0-9一-鿿· _-]{0,30})\s*(?:[:x×])\s*(\d+)",
                raw,
            )
        ]
    return [(name, quantity) for name, quantity in pairs if name and quantity]


def _drop_batches(
    lines: list[str],
) -> tuple[list[list[tuple[str, int]]], list[list[tuple[str, int]]]]:
    """Split Drops events into per-batch results and maa-cli's final total lines."""
    batches: list[list[tuple[str, int]]] = []
    totals: list[list[tuple[str, int]]] = []
    for line in lines:
        marker = re.search(r"(?:total\s+)?Drops:\s*(.+)$", line, re.I)
        if not marker:
            continue
        items = _parse_drop_items(marker.group(1).strip())
        if not items:
            continue
        if re.search(r"total\s+Drops:", line, re.I):
            totals.append(items)
        else:
            batches.append(items)
    return batches, totals


def _sanity_refund(items: list[tuple[str, int]]) -> int:
    return sum(quantity for name, quantity in items if name == SANITY_REFUND_ITEM)


def _drop_pairs(lines: list[str]) -> list[tuple[str, int]]:
    batches, totals = _drop_batches(lines)
    aggregate: dict[str, int] = {}
    # maa-cli can emit per-batch Drops events and one final total. Prefer the
    # latter when present so a result is never double-counted.
    for items in totals or batches:
        for name, quantity in items:
            # 返还的理智不是掉落，见 SANITY_REFUND_ITEM。
            if name == SANITY_REFUND_ITEM:
                continue
            aggregate[name] = aggregate.get(name, 0) + quantity
    return list(aggregate.items())[:8]


def proxy_failures(lines: list[str]) -> tuple[int, int, int]:
    """代理指挥失误统计：(失误批次, 累计返还理智, 末尾连续失误批次)。

    「末尾连续」供熔断使用——有真掉落的批次会把连续计数清零，只有一直失败才中止。
    """
    batches, totals = _drop_batches(lines)
    if not batches:
        # 没有逐批事件（只拿到 maa-cli 汇总行）时退回汇总；批次数不可知，按 1 计。
        refunded = sum(_sanity_refund(items) for items in totals)
        return (1, refunded, 1) if refunded else (0, 0, 0)
    failed = 0
    refunded = 0
    streak = 0
    for items in batches:
        batch_refund = _sanity_refund(items)
        if batch_refund:
            failed += 1
            refunded += batch_refund
            streak += 1
        else:
            streak = 0
    return failed, refunded, streak


def fight_wiped_out(lines: list[str]) -> tuple[int, int]:
    """全部批次都是代理失误（一关没打成）时返回 (批次, 返还理智)，否则 (0, 0)。"""
    failed, refunded, _streak = proxy_failures(lines)
    if failed and not _drop_pairs(lines):
        return failed, refunded
    return 0, 0


def game_exit_count(lines: list[str]) -> int:
    """`run_maa()` 认出游戏中途退出、停掉 maa run 的次数（每次写一行 `GAME_EXITED_NOTE（…`）。"""
    return sum(1 for line in lines if line.strip().startswith(f"{GAME_EXITED_NOTE}（"))


def never_saw_the_game(lines: list[str]) -> bool:
    """整份日志只有截图失败、任务起止和收尾汇总（`NO_FRAME_LINE_RES`），没有一行别的。"""
    for raw in lines:
        line = raw.strip()
        if not line or line in CONNECT_FAILURE_MARKERS or line.startswith(SCREENCAP_SETTLE_NOTE):
            continue
        if not any(pattern.fullmatch(line) for pattern in NO_FRAME_LINE_RES):
            return False
    return True


def connect_failed(lines: list[str], return_code: int) -> str:
    """连接阶段就死了（一个键都没点过）时返回命中的标记，否则空串。

    三个条件缺一不可：非零且不是我们自己写的返回码、日志里有连接失败标记、没有
    任何一条任务链跑到 Completed。第三条是安全闸门——只要有任务真跑过，就不能拿
    「重开一趟」当补救，那会重复已经做完的事。`AllTasksCompleted` 也算跑过，除非
    整份日志一帧画面都没拿到（`never_saw_the_game()`）。
    """
    if return_code == 0 or return_code in SELF_ASSIGNED_CODES:
        return ""
    task_keys = tuple(key for key, *_ in TASK_STEPS)
    for line in lines:
        if any(f"{key} Completed" in line for key in task_keys):
            return ""
    if any("AllTasksCompleted" in line for line in lines) and not never_saw_the_game(lines):
        return ""
    for line in lines:
        for marker in CONNECT_FAILURE_MARKERS:
            if marker in line:
                return marker
    return ""


# maa-cli 流式输出里一条任务链的起止行：`Fight Start` / `Mall Completed` / `Recruit Error`。
_TASK_EVENT_RE = re.compile(r"(\w+) (Start|Completed|Error|Stopped)")
# maa-cli 收尾汇总里每条任务链的首行：`[信用商店] 08:02:29 - 08:02:34 (4s) Completed`。
_SUMMARY_HEAD_RE = re.compile(r"\[([^\]]+)\] \d{2}:\d{2}:\d{2} - ")
# 汇总里的任务名（`daily.toml` 的 `name`）→ `TASK_STEPS` 的 key。
_TASK_KEY_BY_NAME = {
    "启动国服": "StartUp",
    **{name: "Annihilation" for name in ANNIHILATION_TASK_NAMES},
    **{label: key for key, _emoji, label, _running in TASK_STEPS if key not in ("StartUp", "Annihilation")},
}
# 流式输出里能直接对上 key 的 MaaCore 任务类型；Fight 有剿灭和两个刷理智块，对不上。
_UNAMBIGUOUS_TASK_TYPES = frozenset({"StartUp", "Infrast", "Recruit", "Mall", "Award", "Custom"})


def _stream_segments(lines: list[str]) -> list[tuple[str, list[str]]]:
    """按 `<Task> Start` … `<Task> Completed|Error|Stopped` 切出每条任务链的流式段。"""
    segments: list[tuple[str, list[str]]] = []
    current: tuple[str, list[str]] | None = None
    for raw in lines:
        line = raw.strip()
        event = _TASK_EVENT_RE.fullmatch(line)
        if event and event.group(2) == "Start":
            current = (event.group(1), [])
            segments.append(current)
        elif current is not None:
            if event and event.group(1) == current[0]:
                current = None
            else:
                current[1].append(line)
    return segments


def offline_tasks(lines: list[str]) -> set[str]:
    """撞上掉线弹窗、被 MaaCore 停掉的任务（`TASK_STEPS` 的 key），不管它报没报 Completed。

    流式段按顺序和收尾汇总的 `[名字]` 配对；条数对不上（超时、被掐，没有汇总）时只认
    `_UNAMBIGUOUS_TASK_TYPES`。StartUp 不算：它会点确认重连，撞过弹窗也可能登录成功，
    登没登录上由 `never_logged_in()` 判。
    """
    segments = _stream_segments(lines)
    names = [match.group(1) for line in lines if (match := _SUMMARY_HEAD_RE.match(line.strip()))]
    if len(names) == len(segments):
        keys = [_TASK_KEY_BY_NAME.get(name, "") for name in names]
    else:
        keys = [kind if kind in _UNAMBIGUOUS_TASK_TYPES else "" for kind, _body in segments]
    return {
        key
        for key, (_kind, body) in zip(keys, segments)
        if key and key != "StartUp" and GAME_OFFLINE_MARKER in body
    }


def _made_progress(lines: list[str]) -> bool:
    """日志里有没有任何一件真做成的事：作战批次、掉落、进过基建设施、公招。"""
    return bool(
        _fight_times(lines)
        or _drop_pairs(lines)
        or any("EnterFacility" in line or "RecruitTagsRefreshed" in line for line in lines)
        or _last_match(lines, r"Recruited\s+\d+\s+times")
    )


def _offline_keys(lines: list[str]) -> set[str]:
    """战报要判红的掉线任务：`offline_tasks()`，没登录上时再加 StartUp。"""
    keys = offline_tasks(lines)
    if never_logged_in(lines):
        keys.add("StartUp")
    return keys


def _offline_reason(key: str) -> str:
    return "没登录上，获取网络配置失败" if key == "StartUp" else "游戏掉线"


def never_logged_in(lines: list[str]) -> bool:
    """这一趟从头到尾没登录上（2026-11-09 早场：「获取网络配置失败，请重新登录」）。

    三条缺一不可：StartUp 段里撞过掉线弹窗；StartUp 之后的第一条任务链也撞上它
    （StartUp 点确认用完次数仍停在弹窗上）；日志里没有任何真实进展。第三条是安全
    闸门——判据万一被新版输出骗了，有一点进展就不整场重跑，免得重复做完的事。
    """
    segments = _stream_segments(lines)
    index = next((i for i, (kind, _body) in enumerate(segments) if kind == "StartUp"), None)
    if index is None or index + 1 >= len(segments):
        return False
    if GAME_OFFLINE_MARKER not in segments[index][1]:
        return False
    if GAME_OFFLINE_MARKER not in segments[index + 1][1]:
        return False
    return not _made_progress(lines)


def conf_probe() -> str:
    """直连探一下鹰角的配置服务器，返回一行给运行日志看的结果。永不抛。"""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    host = CONF_PROBE_URL.split("/")[2]
    started = time.monotonic()
    try:
        with opener.open(CONF_PROBE_URL, timeout=CONF_PROBE_TIMEOUT) as response:
            status = f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        status = f"HTTP {exc.code}"
    except Exception as exc:  # noqa: BLE001 — (c) 只是排障线索，什么错都不能拖垮重开
        status = f"连不上（{type(exc).__name__}: {str(exc)[:120]}）"
    return f"连通性探测：{host} {status}，{time.monotonic() - started:.1f}s"


def progress_content(
    lines: list[str],
    *,
    plan: Plan | None = None,
    final: str | None = None,
) -> str:
    clean = [_clean_line(line, 300) for line in lines if line.strip()]
    heading = final or "🌱 MAA 正在执行"
    status_lines: list[str] = []
    offline = _offline_keys(clean)
    for key, emoji, label, running_text in TASK_STEPS:
        state = _task_state(clean, key, label)
        if key in offline and state != "running":
            status_lines.append(f"❌ {emoji} {label}：未完成（{_offline_reason(key)}）")
        elif state == "completed":
            status_lines.append(f"✅ {emoji} {label}：完成")
        elif state == "failed":
            status_lines.append(f"❌ {emoji} {label}：未完成")
        elif state == "running":
            detail = running_text
            if key == "Fight" and plan is not None:
                detail = f"正在刷 {plan_stage_label(plan)}，自动选择最大连战次数"
            elif key == "Fight2" and plan is not None:
                spare = str(plan.get("farming_fallback_stage") or "")
                detail = f"正在刷 {spare or '第二个关'}，用掉刷够缺口后剩下的理智"
            status_lines.append(f"⏳ {emoji} {detail}")

    sanity = _last_match(clean, r"Current sanity:\s*(\d+)\s*/\s*(\d+)")
    if sanity and _task_state(clean, "Fight", "刷理智") != "pending":
        status_lines.append(f"🧠 当前理智：{sanity.group(1)}/{sanity.group(2)}")
    proxy_batches, refunded, _streak = proxy_failures(clean)
    fight_times = _fight_times(clean)
    if fight_times and not fight_wiped_out(clean)[0]:
        status_lines.append(f"🔁 已完成作战：{fight_times} 次")
    if proxy_batches:
        status_lines.append(f"⚠️ 代理指挥失误 {proxy_batches} 批，理智已返还 ×{refunded}")
    refresh = _last_match(clean, r"RecruitTagsRefreshed:\s*(\d+)\s+times")
    if refresh:
        status_lines.append(f"🔄 公招已刷新：{refresh.group(1)} 次")
    if not status_lines:
        status_lines.append("⏳ 正在连接游戏并准备任务…")
    return (heading + "\n" + "\n".join(status_lines))[:1990]


# ---- 本场进度文件 `runs/<场>.progress.json`（DEV_GUIDE §12.3，不变量 #65） ----
# 和 Discord 进度消息同一个 5 秒循环、同一套解析（`_task_state` / `_offline_keys` /
# `_fight_times` / `_drop_pairs`），GUI 只渲染它。字段只增不改语义；写失败只打一行 stderr。
PROGRESS_SCHEMA_VERSION = 1
# (key, 界面上的词, 对应的 TASK_STEPS key)。顺序就是执行顺序。
PROGRESS_STEPS: tuple[tuple[str, str, tuple[str, ...]], ...] = (
    ("startup", "启动游戏", ("StartUp",)),
    ("annihilation", "剿灭", ("Annihilation",)),
    ("fight", "刷理智", ("Fight", "Fight2")),
    ("infrast", "基建", ("Infrast",)),
    ("recruit", "公招", ("Recruit",)),
    ("mall", "商店", ("Mall",)),
    ("award", "领奖", ("Award",)),
)
# 恢复动作的说明（`notes[].text`）。界面原样显示，受 tests/test_ui_copy.py 的禁用词守门。
PROGRESS_NOTES = {
    "stage_manager": "已临时关掉台前调度，跑完再打开",
    "window": "游戏窗口没摆好，照常开始",
    "screen_lost": "游戏画面丢了，已把游戏窗口摆回来",
    "connect_retry": "游戏画面没拿到，{wait}后摆好窗口再试（{n}/{limit}）",
    "connect_gave_up": "游戏画面一直拿不到，不再重试",
    "offline_retry": "游戏没登录上，{wait}后重启（{n}/{limit}）",
    "offline_gave_up": "游戏一直没登录上，不再重启",
    "game_exited": "游戏中途退出了，重开后接着跑（{n}/{limit}）",
    "game_exit_gave_up": "游戏又退出了，不再重开",
    "proxy_break": "代理指挥连着失误 {n} 次，先停下刷理智",
    "salvage": "补跑基建、公招、商店和领奖",
    "fallback": "{stage} 没打成，改刷后备关 {spare}",
    "no_time": "剩下的时间不够，不再补跑",
    "timeout": "超时了，已停下",
    "cancelled": "已按你的要求停下",
}
# 算 ETA 时最多看最近这么多份旧进度文件。
PROGRESS_HISTORY_FILES = 20
_PROGRESS_STATE = {"completed": "done", "failed": "failed", "running": "running", "pending": "pending"}
_TASK_LABELS = {key: label for key, _emoji, label, _running in TASK_STEPS}


def _wait_text(seconds: int) -> str:
    return f"{seconds // 60} 分钟" if seconds >= 60 else f"{seconds} 秒"


def progress_path_for(log_path: Path) -> Path:
    """`runs/<场>.log` → `runs/<场>.progress.json`（和日志、快照同名）。"""
    return log_path.with_name(log_path.stem + ".progress.json")


def _stage_ap_cost(stage: str, config: Config) -> int | None:
    import maa_copilot

    index = maa_copilot.load_stage_index(config)
    resolved = maa_copilot.resolve_copilot_stage(stage, index)
    return maa_copilot.stage_sanity_cost(resolved[0], resolved[1], config) if resolved else None


def _fight_stream_states(lines: list[str]) -> list[str]:
    """这一趟流式输出里每个 Fight 段的状态（还没有收尾汇总时用来分剿灭和刷理智）。"""
    states: list[str] = []
    for raw in lines:
        event = _TASK_EVENT_RE.fullmatch(raw.strip())
        if not event or event.group(1) != "Fight":
            continue
        if event.group(2) == "Start":
            states.append("running")
        elif states:
            states[-1] = "done" if event.group(2) == "Completed" else "failed"
    return states


def progress_history(runs_dir: Path, exclude: Path) -> dict[str, float]:
    """以前各场进度文件里每一步的耗时中位数（秒）。读不到就是空。"""
    import statistics

    samples: dict[str, list[float]] = {}
    try:
        files = sorted(runs_dir.glob("*.progress.json"))
    except OSError:
        return {}
    for path in [p for p in files if p != exclude][-PROGRESS_HISTORY_FILES:]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            for step in data.get("steps") or []:
                if step.get("state") != "done" or not step.get("started_at") or not step.get("finished_at"):
                    continue
                seconds = (
                    datetime.fromisoformat(step["finished_at"]) - datetime.fromisoformat(step["started_at"])
                ).total_seconds()
                if seconds >= 0:
                    samples.setdefault(str(step.get("key")), []).append(seconds)
        except Exception:  # noqa: BLE001 — (c) 旧文件坏了就不算它，ETA 只是参考
            continue
    return {key: statistics.median(values) for key, values in samples.items()}


class RunProgressFile:
    """一场的进度文件。所有方法永不抛（不变量 #65）：写不进去只打一行 stderr，跑场照常。

    `kind` 先只有 `daily`；抄作业以后写 `copilot`，`steps` 换成一关一格即可，其余字段不变。
    """

    def __init__(
        self,
        path: Path,
        *,
        phase: str,
        plan: Plan,
        config: Config,
        started: datetime,
        kind: str = "daily",
        run_id: str = "",
    ) -> None:
        self.path = path
        self.phase = phase
        self.plan = plan
        self.config = config
        self.started = started
        self.kind = kind
        self.run_id = run_id or make_run_id(phase, started)
        self.status = "running"
        self.final = False
        self.booting = False
        self.notes: list[dict[str, str]] = []
        # 每种说明出现过几次：场次索引（#66）的重试 / 摆窗次数、超时、补跑从这里取。
        self.counts: dict[str, int] = {}
        self.states: dict[str, str] = {key: "pending" for key, *_ in PROGRESS_STEPS}
        self.times: dict[str, dict[str, str | None]] = {
            key: {"started_at": None, "finished_at": None} for key, *_ in PROGRESS_STEPS
        }
        self.fight: dict[str, Any] = {"done": 0, "estimate": None, "sanity": None, "ap_cost": None, "drops": []}
        self._ap_cost: int | None = None
        self._ap_cost_known = False
        self._warned = False
        try:
            self.history = progress_history(path.parent, path)
        except Exception:  # noqa: BLE001 — (c) 没历史就不给 ETA
            self.history = {}
        self.write()

    # -- 计划里有哪些事 --
    def planned(self, key: str) -> bool:
        tasks = self.plan.get("tasks") or {}
        if key == "startup":
            return True
        if key == "annihilation":
            return bool(tasks.get("fight", True)) and bool(self.plan.get("annihilation", True))
        if key == "fight":
            return bool(tasks.get("fight", True)) and bool(self.plan.get("farming", True))
        return bool(tasks.get(key, True))

    def _warn(self, exc: BaseException) -> None:
        if not self._warned:
            self._warned = True
            print(f"进度文件没写成：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)

    # -- 对外 --
    def boot(self) -> None:
        """开始拉起游戏：日志还没有 StartUp 之前，启动游戏这一格算「进行中」。"""
        self.booting = True
        self._set("startup", "running" if self.states["startup"] == "pending" else self.states["startup"])
        self.write()

    def note(self, kind: str, **values: Any) -> None:
        self.counts[kind] = self.counts.get(kind, 0) + 1
        try:
            text = PROGRESS_NOTES[kind].format(**values)
            self.notes.append({"at": now_beijing().isoformat(), "text": text})
        except Exception as exc:  # noqa: BLE001 — (c) 进度文件不能拖垮跑场（#65）
            self._warn(exc)
        self.write()

    def update(self, lines: list[str], *, live: list[str] | None = None, plan: Plan | None = None) -> None:
        if self.final:
            return
        try:
            self._compute(lines, live if live is not None else lines, plan or self.plan)
        except Exception as exc:  # noqa: BLE001 — (c) 解析出错不能拖垮跑场（#65）
            self._warn(exc)
        self.write()

    def finish(self, status: str, lines: list[str] | None = None) -> None:
        if self.final:
            return
        if lines is not None:
            try:
                self._compute(lines, [], self.plan)
            except Exception as exc:  # noqa: BLE001 — (c) 同上
                self._warn(exc)
        self.status = status
        for key, *_ in PROGRESS_STEPS:
            state = self.states[key]
            if state == "running":
                self._set(key, "done" if status == "success" else "failed")
            elif state == "pending" and self.planned(key):
                self._set(key, "skipped")
        if self.states["fight"] == "done":
            self.fight["estimate"] = self.fight["done"]
        self.final = True
        self.write()

    # -- 计算 --
    def _set(self, key: str, state: str) -> None:
        if not self.planned(key):
            state = "skipped"
        previous = self.states[key]
        if state == previous:
            return
        stamp = now_beijing().isoformat()
        times = self.times[key]
        if state == "pending":
            times["started_at"] = times["finished_at"] = None
        elif state == "running":
            times["started_at"] = times["started_at"] or stamp
            times["finished_at"] = None
        elif state in ("done", "failed"):
            times["started_at"] = times["started_at"] or stamp
            times["finished_at"] = stamp
        self.states[key] = state

    def _compute(self, lines: list[str], live: list[str], plan: Plan) -> None:
        clean = [_clean_line(line, 300) for line in lines if line.strip()]
        offline = _offline_keys(clean)

        def one(task_key: str) -> str:
            state = _task_state(clean, task_key, _TASK_LABELS[task_key])
            if task_key in offline and state != "running":
                return "failed"
            return _PROGRESS_STATE[state]

        states = {"startup": one("StartUp"), "annihilation": one("Annihilation")}
        first, second = one("Fight"), one("Fight2")
        if "running" in (first, second):
            states["fight"] = "running"
        elif second == "done" or (first == "done" and second != "failed"):
            states["fight"] = "done"
        elif "failed" in (first, second):
            states["fight"] = "failed"
        else:
            states["fight"] = "pending"
        # 收尾汇总出来之前，剿灭和刷理智在流式输出里都是 `Fight`：按这一趟的计划分开。
        live_clean = [_clean_line(line, 300) for line in live if line.strip()]
        stream = _fight_stream_states(live_clean)
        if stream and not any(_SUMMARY_HEAD_RE.match(line) for line in live_clean):
            tasks = plan.get("tasks") or {}
            if bool(tasks.get("fight", True)) and bool(plan.get("annihilation", True)) and not plan.get("fallback_run"):
                states["annihilation"], stream = stream[0], stream[1:]
            if stream:
                states["fight"] = "running" if "running" in stream else stream[-1]
            elif states["fight"] == "running":
                states["fight"] = "pending"
        for key in ("infrast", "recruit", "mall", "award"):
            states[key] = one(key.capitalize())
        if self.booting and states["startup"] == "pending" and not any(
            state != "pending" for key, state in states.items() if key != "startup"
        ):
            states["startup"] = "running"
        # 做完的事不倒回「没开始」（收尾时只有汇总、没有流式段）；整份输出都没有任务起止
        # 才是真的从头来（没登录上、重启游戏后整场重跑）。
        restarted = not any(_TASK_EVENT_RE.fullmatch(line.strip()) for line in clean)
        for key, state in states.items():
            if state == "pending" and self.states[key] in ("done", "failed") and not restarted:
                continue
            self._set(key, state)

        sanity = _last_match(clean, r"Current sanity:\s*(\d+)\s*/\s*(\d+)")
        done = 0 if fight_wiped_out(clean)[0] else _fight_times(clean)
        self.fight["done"] = done
        self.fight["drops"] = [{"name": name, "count": count} for name, count in _drop_pairs(clean)]
        self.fight["sanity"] = (
            {"current": int(sanity.group(1)), "max": int(sanity.group(2))} if sanity else None
        )
        if self.states["fight"] == "running" and sanity and not self._ap_cost_known:
            self._ap_cost_known = True
            try:
                self._ap_cost = _stage_ap_cost(str(plan.get("stage") or ""), self.config)
            except Exception:  # noqa: BLE001 — (c) 查不到每把理智就不估总数
                self._ap_cost = None
        self.fight["ap_cost"] = self._ap_cost
        if self.states["fight"] == "done":
            self.fight["estimate"] = done
        elif self.states["fight"] == "running" and sanity and self._ap_cost:
            self.fight["estimate"] = done + int(sanity.group(1)) // self._ap_cost
        else:
            self.fight["estimate"] = None

    def _eta(self) -> str | None:
        if self.final or not self.history:
            return None
        now = now_beijing()
        remaining = 0.0
        for key, *_ in PROGRESS_STEPS:
            state = self.states[key]
            if state not in ("pending", "running"):
                continue
            if key not in self.history:
                return None
            spent = 0.0
            started = self.times[key]["started_at"]
            if state == "running" and started:
                spent = (now - datetime.fromisoformat(started)).total_seconds()
            remaining += max(0.0, self.history[key] - spent)
        return (now + timedelta(seconds=remaining)).isoformat(timespec="seconds")

    def payload(self) -> dict[str, Any]:
        current = next((key for key, *_ in PROGRESS_STEPS if self.states[key] == "running"), None)
        return {
            "schema_version": PROGRESS_SCHEMA_VERSION,
            "kind": self.kind,
            "run_id": self.run_id,
            "phase": self.phase,
            "started_at": self.started.isoformat(),
            "updated_at": now_beijing().isoformat(),
            "status": self.status,
            "current": None if self.final else current,
            "steps": [
                {"key": key, "label": label, "state": self.states[key], **self.times[key]}
                for key, label, _tasks in PROGRESS_STEPS
            ],
            "fight": dict(self.fight),
            "notes": list(self.notes),
            "eta": self._eta(),
        }

    def write(self) -> None:
        try:
            atomic_write_json(self.path, self.payload())
        except Exception as exc:  # noqa: BLE001 — (c) 写失败不能影响跑场（#65）
            self._warn(exc)


def extract_summary(
    stdout_lines: list[str],
    stderr_lines: list[str],
    *,
    plan: Plan | None = None,
    ok: bool | None = None,
    home_verified: bool | None = None,
    home_verify_detail: str = "",
) -> str:
    lines = [_clean_line(line, 500) for line in stdout_lines + stderr_lines if line.strip()]
    tasks = (plan or {}).get("tasks", {})
    annihilation_in_logs = any(
        f"[{name}]" in line for line in lines for name in ANNIHILATION_TASK_NAMES
    )
    annihilation_planned = (plan or {}).get("annihilation")
    # 第二个刷理智块只有「第一块设了 drops 上限 + 有后备关」时才渲染出来，
    # 战报也只在那时列它——否则每天都多一行「⏸️ 未执行」的噪音。
    second_fight_planned = bool(
        (plan or {}).get("farming_drops") and (plan or {}).get("farming_fallback_stage")
    )
    enabled = {
        "StartUp": True,
        # Show the step when this run included it, or when older logs still
        # have the named summary.  A False flag means "already done today".
        "Annihilation": annihilation_in_logs or annihilation_planned is True,
        "Fight": bool(tasks.get("fight", True)),
        "Fight2": bool(tasks.get("fight", True))
        and (
            second_fight_planned
            or any(f"[{FARMING_TASK_NAMES[1]}]" in line for line in lines)
        ),
        "Infrast": bool(tasks.get("infrast", True)),
        "Recruit": bool(tasks.get("recruit", True)),
        "Mall": bool(tasks.get("mall", True)),
        "Award": bool(tasks.get("award", True)),
        "Custom": True,
    }
    result = [f"🌟 总体：{'✅ 成功' if ok is not False else '❌ 未完成'}"]
    offline = _offline_keys(lines)
    for key, emoji, label, _running_text in TASK_STEPS:
        if not enabled[key]:
            if key == "Annihilation" and annihilation_planned is False:
                reason = str((plan or {}).get("annihilation_skip_reason") or "今日已刷过，本场跳过")
                result.append(f"{emoji} {label}：⏭️ {reason}")
            continue
        state = _task_state(lines, key, label)
        status = {"completed": "✅ 完成", "failed": "❌ 未完成", "running": "❌ 中断", "pending": "⏸️ 未执行"}[state]
        details: list[str] = []
        if key in offline:
            # MaaCore 撞上掉线弹窗就 Stop，被停的任务照样报 Completed（2026-11-09 早场
            # 信用商店 / 领取奖励都「✅」了，其实什么都没做）。
            status = "❌ 未完成"
            details.append(_offline_reason(key))
        if key == "StartUp" and state != "completed" and key not in offline:
            # 「启动游戏 ❌ 中断」看着像游戏那头的事，其实多半是 MaaTools 没连上或截图
            # 拿不到（窗口被台前调度收走）。把 MaaCore 的原始标记摊开，省得去翻 asst.log。
            # 游戏进程中途换了的那种，截图失败只是后果，直接说游戏退出了（#68）。
            marker = next(
                (m for m in CONNECT_FAILURE_MARKERS if any(m in line for line in lines)), ""
            )
            if game_exit_count(lines):
                details.append(GAME_EXITED_NOTE)
            elif marker:
                details.append(f"没连上游戏（{marker}），检查 MaaTools 与 MAA-Game 虚拟屏")
        elif key == "Annihilation":
            annihilation_lines = []
            for name in ANNIHILATION_TASK_NAMES:
                annihilation_lines = _named_task_section(lines, name)
                if annihilation_lines:
                    break
            annihilation_lines = annihilation_lines or lines
            count = _fight_times(annihilation_lines)
            details.append(
                f"当期剿灭 {count} 次；代理卡全权委托；满 {ANNIHILATION_WEEKLY_ORUNDUM} 合成玉/周后停止"
                if count
                else f"代理卡全权委托；满 {ANNIHILATION_WEEKLY_ORUNDUM} 合成玉/周后停止"
            )
        elif key in ("Fight", "Fight2"):
            # 游戏中途退出后接着跑（#68）时同一块在两趟汇总里各有一段，次数按段加起来。
            if key == "Fight":
                sections = _named_task_sections(lines, FARMING_TASK_NAMES[0])
                fight_lines = [line for part in sections for line in part] or lines
                stage_label = plan_stage_label(plan or {})
            else:
                # 第二块**不退回整份日志**：那会把第一块的掉落和次数重复算一遍。
                sections = _named_task_sections(lines, FARMING_TASK_NAMES[1])
                fight_lines = [line for part in sections for line in part]
                stage_label = str((plan or {}).get("farming_fallback_stage") or "第二个关")
            details.append(f"关卡 {stage_label}")
            proxy_batches, refunded, _streak = proxy_failures(fight_lines)
            wiped_batches, _wiped_refund = fight_wiped_out(fight_lines)
            count = (
                sum(_fight_times(part) for part in sections)
                if len(sections) > 1
                else _fight_times(fight_lines)
            )
            if wiped_batches:
                # MaaCore 会把「一批都没打成」也判成 Fight Completed，而 count 数的是
                # 发起的连战批次，不是真打完的次数。这里直接翻红，别让战报骗人。
                status = "❌ 未完成"
                details.append("实际完成 0 次")
            elif count:
                details.append(f"{count} 次")
            elif key == "Fight" and state == "failed" and _main_fight_was_dry(lines):
                spare = str((plan or {}).get("farming_fallback_stage") or "")
                second = _task_state(lines, "Fight2", FARMING_TASK_NAMES[1])
                details.append(
                    f"未消耗理智，已改刷后备关 {spare}"
                    if spare and second != "pending"
                    else "未消耗理智"
                )
            if proxy_batches:
                details.append(f"代理指挥失误 {proxy_batches} 批，理智已返还 ×{refunded}")
            medicine = (
                sum(_expiring_medicine_used(part) for part in sections)
                if len(sections) > 1
                else _expiring_medicine_used(fight_lines)
            )
            if medicine:
                details.append(f"临期理智药 ×{medicine}")
            sanity = _last_match(lines, r"Current sanity:\s*(\d+)\s*/\s*(\d+)")
            if sanity:
                details.append(f"结束理智 {sanity.group(1)}/{sanity.group(2)}")
            drops = _drop_pairs(fight_lines)
            if drops:
                details.append("掉落 " + "、".join(f"{name} ×{quantity}" for name, quantity in drops))
        elif key == "Infrast":
            facilities = []
            for raw_name, display in (
                ("Mfg", "制造站"),
                ("Trade", "贸易站"),
                ("Power", "发电站"),
                ("Control", "控制中枢"),
                ("Reception", "会客室"),
                ("Office", "办公室"),
                ("Dorm", "宿舍"),
            ):
                count = sum(1 for line in lines if f"EnterFacility {raw_name}" in line)
                if count:
                    facilities.append(f"{display} ×{count}")
            if facilities:
                details.append("、".join(facilities))
        elif key == "Recruit":
            recruited = _last_match(lines, r"Recruited\s+(\d+)\s+times")
            refreshed = _last_match(lines, r"Refreshed\s+(\d+)\s+times")
            if recruited:
                details.append(f"招募 {recruited.group(1)} 次")
            if refreshed:
                details.append(f"刷新 {refreshed.group(1)} 次")
        elif key == "Custom":
            # 截图才是最终交付物，所以它说了算：MAA 报错但截图确实在主页时说清楚，
            # 反之截图不在主页就把这一步判红，哪怕 MAA 自称完成。
            if home_verified is True:
                details.append("截图已确认在主页")
            elif home_verified is False:
                status = "❌ 未完成"
                details.append(f"截图不在主页：{home_verify_detail}" if home_verify_detail else "截图不在主页")
        suffix = f"（{'；'.join(details)}）" if details else ""
        result.append(f"{emoji} {label}：{status}{suffix}")
    return "\n".join(result)[:3900]


def _reader(
    stream: TextIO,
    recent: deque[str],
    all_lines: list[str],
    log_handle: TextIO | None = None,
    log_lock: threading.Lock | None = None,
) -> None:
    for line in iter(stream.readline, ""):
        clean = line.rstrip("\n")
        recent.append(clean)
        if len(all_lines) < 10000:
            all_lines.append(clean)
        if log_handle is not None and log_lock is not None:
            with log_lock:
                log_handle.write(line)
                log_handle.flush()
    stream.close()


def discord_outlet(config: Config) -> tuple[str, str]:
    """通知出口（不变量 #63）：返回 (token, channel_id)，缺哪样就整个返回空串，永不抛。

    Discord 只是出口之一：没配频道、读不到 token 时本场照跑，战报照样写进
    `runs/<场>-report.json`（`write_report_file()`），只是不发帖。
    """
    channel_id = str(config.get("channel_id", "")).strip()
    if not channel_id.isdigit():
        print("Discord 频道没配置，本场不发消息，战报只写文件", file=sys.stderr, flush=True)
        return "", ""
    try:
        token = discord_token()
    except Exception as exc:  # noqa: BLE001 — (c) 通知出口缺席不能拖垮执行
        print(f"读不到 Discord token（{exc}），本场不发消息，战报只写文件", file=sys.stderr, flush=True)
        return "", ""
    return token, channel_id


def notify(token: str, method: str, path: str, payload: dict[str, Any], *, what: str) -> Any:
    """发一条 Discord 请求；没有出口（token 为空或路径里频道为空）就跳过。

    发送失败（网络、HTTP、token 失效）只打一行日志、返回 None，永不抛（不变量 #63）。
    """
    if not token or "/channels//" in path or path.endswith("/channels/"):
        return None
    try:
        return discord_request(token, method, path, payload)
    except Exception as exc:  # noqa: BLE001 — (c) 通知发不出去只记日志，执行照常
        print(f"{what}发送失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return None


def open_thread(
    token: str, channel_id: str, phase: Phase, plan: Plan, started: datetime
) -> tuple[str, str]:
    """发开跑消息、建子区、放进度占位，返回 (thread_id, progress_message_id)。

    任何一步失败都返回已拿到的部分（拿不到子区就两个空串），永不抛：后面的进度
    更新和战报看到空 id 就跳过发帖，一场照常跑完（不变量 #63）。
    """
    if not token or not channel_id:
        return "", ""
    opening = notify(
        token,
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "content": (
                f"🌱 MAA 日常·{PHASE_LABELS[phase]}场开始\n"
                f"🎯 {plan_stage_label(plan)}"
                + (
                    ""
                    if plan.get("farming", True)
                    else "\n⏭️ " + str(
                        plan.get("farming_skip_reason")
                        or "理智不足以刷默认关，本场跳过刷理智。"
                    )
                )
                + (
                    " · ☄️ 今日剿灭"
                    if plan.get("annihilation")
                    else " · ☄️ 本周剿灭已满"
                    if plan.get("annihilation_skip_reason")
                    else " · ☄️ 剿灭今日已刷"
                )
                + f" · 🧪 {medicine_label(str(plan.get('medicine', '')))}"
            ),
            "allowed_mentions": {"parse": []},
        },
        what="开跑消息",
    )
    if not isinstance(opening, dict) or not opening.get("id"):
        return "", ""
    thread_name = f"MAA日常·{PHASE_LABELS[phase]} · {started:%m-%d %H:%M}"
    try:
        thread = create_thread(token, channel_id, str(opening["id"]), thread_name)
        thread_id = str(thread["id"])
    except Exception as exc:  # noqa: BLE001 — (c) 建子区失败只记日志，本场照跑、不发进度
        print(f"建子区失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return "", ""
    placeholder = notify(
        token,
        "POST",
        f"/channels/{thread_id}/messages",
        {"content": progress_content([], plan=plan), "allowed_mentions": {"parse": []}},
        what="进度占位",
    )
    progress_message_id = (
        str(placeholder["id"]) if isinstance(placeholder, dict) and placeholder.get("id") else ""
    )
    return thread_id, progress_message_id


def write_report_file(path: Path, payload: dict[str, Any]) -> str:
    """战报的「只写文件」出口：不管 Discord 发没发出去都写一份。失败返回原因，不抛。"""
    try:
        atomic_write_json(path, payload)
    except Exception as exc:  # noqa: BLE001 — (c) 战报文件写不出只记一条，不影响终态
        print(f"战报文件写入失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return f"{type(exc).__name__}: {exc}"
    return ""


def report_game_busy(
    config: Config,
    token: str,
    channel_id: str,
    phase: Phase,
    detail: str,
    attempted_at: datetime,
) -> None:
    """Announce a probe-skipped automatic run. Never a silent return (护栏 4)."""
    reason = (
        "检测到明日方舟（PlayCover）正在运行，判定你在玩，本场不抢游戏。需要照跑就说「现在跑」。"
    )
    common_report_game_busy(
        config,
        title=f"⏭️ MAA 日常·{PHASE_LABELS[phase]}场已跳过",
        reason=reason,
        detail=detail,
        at=attempted_at,
        state_update={
            "status": "skipped",
            "phase": phase,
            "skip_reason": "game_busy",
            "summary": reason,
            "game_probe": detail,
            "finished_at": attempted_at.isoformat(),
        },
        token=token,
        channel_id=channel_id,
        new_run=True,
    )
    maa_notify.notify(
        f"⏭️ {PHASE_LABELS[phase]}场已跳过",
        "检测到你在玩明日方舟，本场未启动。",
        level="passive",
        notification_id=f"run-skip-{phase}-{attempted_at:%Y%m%d%H%M%S}",
        url="wadosmaa://today",
    )


def report_upstream_block(
    token: str, channel_id: str, phase: Phase, reason: str, at: datetime, *, run_id: str = ""
) -> None:
    """上游状态不对，本场不开游戏。失败要说出来（护栏 4）。"""
    merge_last_run({
        "status": "failed",
        "phase": phase,
        "startup_error": reason,
        "summary": f"上游状态不对，本场没开跑：{reason}",
        "finished_at": at.isoformat(),
    })
    maa_notify.notify(
        f"⛔ {PHASE_LABELS[phase]}场未开跑",
        f"上游状态不对：{reason[:300]}",
        level="timeSensitive",
        notification_id=f"run-{run_id}" if run_id else f"run-upstream-{phase}-{at:%Y%m%d%H%M%S}",
        url=f"wadosmaa://run/{run_id}" if run_id else "wadosmaa://today",
    )
    notify(
        token,
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [
                {
                    "title": f"⛔ MAA 日常·{PHASE_LABELS[phase]}没开跑：上游状态不对",
                    "description": f"{reason[:1500]}\n\n未启动游戏。修好后可以「现在跑」补一场。",
                    "color": 0xED4245,
                    "timestamp": at.isoformat(),
                }
            ],
            "allowed_mentions": {"parse": []},
        },
        what="上游拒跑告警",
    )


def verify_home_screenshot(path: Path) -> tuple[bool | None, str]:
    """Check that a captured screenshot really shows the game home page.

    Returns (True | False | None, detail).  ``None`` means "could not tell"
    (ocrbox missing, OCR crashed) — that must never turn a good run red, so the
    caller only treats an explicit ``False`` as a failure.  Daily runs only:
    抄作业 keeps using capture_screenshot directly and is not gated by this.
    """
    ocrbox = SCRIPTS_DIR / "ocrbox"
    if not path.is_file():
        return None, "没有截图可校验"
    if not ocrbox.is_file():
        return None, "ocrbox 未部署，跳过主页校验"
    try:
        result = subprocess.run(
            [str(ocrbox), str(path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        return None, f"OCR 失败：{type(exc).__name__}: {exc}"
    if result.returncode != 0:
        return None, f"OCR 失败：{result.stderr.strip()[:120]}"
    # ocrbox prints "文本\t[x,y,w,h]" per line; only the text column matters.
    text = "\n".join(line.split("\t", 1)[0] for line in result.stdout.splitlines())
    upper = text.upper()
    hits = [group[0] for group in HOME_MARKERS if any(m in text or m in upper for m in group)]
    detail = (
        f"识别到 {len(hits)}/{len(HOME_MARKERS)} 个主页标识"
        + (f"（{'、'.join(hits)}）" if hits else "")
    )
    return len(hits) >= HOME_MARKER_MIN, detail


def capture_home_screenshot(
    config: Config, path: Path
) -> tuple[bool, str, bool | None, str]:
    """Capture the end-of-run screenshot and confirm it is the home page.

    Retries a few times because the home page animates in; each attempt waits
    the same settle delay the single-shot version used.
    """
    delay = max(0.0, float(config.get("home_screenshot_delay", 1)))
    attempts = max(1, int(config.get("home_screenshot_attempts", 3)))
    ok, error, verified, detail = False, "未执行", None, ""
    for _ in range(attempts):
        time.sleep(delay)
        ok, error = maa_playcover.capture_screenshot(config, path)
        if not ok:
            return ok, error, None, "没有截图可校验"
        verified, detail = verify_home_screenshot(path)
        if verified is not False:
            break
    return ok, error, verified, detail


def run_maa(
    config: Config,
    log_path: Path,
    token: str,
    thread_id: str,
    progress_message_id: str,
    plan: Plan | None = None,
    *,
    timeout: int | None = None,
    carry_lines: list[str] | None = None,
    append: bool = False,
    progress: RunProgressFile | None = None,
    game_watch: maa_playcover.GameExitWatch | None = None,
) -> tuple[int, list[str], list[str]]:
    """跑一趟 `maa run daily`，把两路输出写进日志并更新进度。

    `game_watch` 不为 None 时，拉起后先记下游戏进程，之后每 `PROGRESS_INTERVAL_SECONDS`
    查一次；游戏中途退出就停掉 maa run、返回 `GAME_EXITED_CODE`（不变量 #68）。
    """
    maa = str(config.get("maa_bin", "/opt/homebrew/bin/maa"))
    # maa-cli 0.7.5's --log-file redirects logs away from stderr.  Capture the
    # live streams ourselves and tee both to disk so Discord progress remains
    # observable without sacrificing the full local log.
    command = [maa, "run", "daily", "-v", "--batch"]
    env = maa_subprocess_env(config)
    env["MAA_LOG_PREFIX"] = "Never"
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        env=env,
    )
    assert process.stdout is not None and process.stderr is not None
    stderr_recent: deque[str] = deque(maxlen=12)
    stderr_lines: list[str] = []
    stdout_recent: deque[str] = deque(maxlen=12)
    stdout_lines: list[str] = []
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_lock = threading.Lock()
    with log_path.open("a" if append else "w", encoding="utf-8", buffering=1) as log_handle:
        stderr_thread = threading.Thread(
            target=_reader,
            args=(process.stderr, stderr_recent, stderr_lines, log_handle, log_lock),
            daemon=True,
        )
        stdout_thread = threading.Thread(
            target=_reader,
            args=(process.stdout, stdout_recent, stdout_lines, log_handle, log_lock),
            daemon=True,
        )
        stderr_thread.start()
        stdout_thread.start()
        previous = ""
        progress_error = ""
        next_update = time.monotonic()
        # Hermes' outer no-agent cron timeout is 3600s. Keep ten minutes of
        # headroom for boot, screenshot, cleanup and the final report.
        budget = int(config.get("maa_run_timeout", 3000) if timeout is None else timeout)
        deadline = time.monotonic() + max(MIN_RUN_TIMEOUT_SECONDS, budget)
        # 连着这么多批代理指挥失误就熔断：理智全额退回、一关没打成，再刷下去只会
        # 空转到超时，还会把游戏钉在结算页拖垮后面的基建/公招/商店/奖励。0 = 关闭。
        proxy_limit = max(0, int(config.get("proxy_failure_limit", 2)))
        prefix = list(carry_lines or [])
        timed_out = False
        interrupted = False
        proxy_tripped = 0
        game_exited = ""
        # 拉起 maa run 时游戏已经在跑（开跑前等过 MaaTools），这一次只是记下基线进程。
        started_wall = time.time()
        if game_watch is not None:
            game_watch.check()
        # 跑到一半 SCRN 回空（游戏窗口被台前调度收进侧边栏）时 MaaCore 会报
        # ScreencapFailed，连接还在，把窗口摆回 MAA-Game 台前就能接着截。游戏进程换了
        # 就不是这回事：旧连接断了、MaaCore 不会重连，所以摆窗之前先判进程（#68）。
        # 节流 30 秒，免得 MaaCore 连着报错时一直 `open -a`。
        screencap_failures = 0
        last_settle = 0.0
        try:
            while process.poll() is None:
                now = time.monotonic()
                if now >= deadline:
                    timed_out = True
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                    break
                if now >= next_update:
                    live = list(stdout_lines) + list(stderr_lines)
                    game_exited = game_watch.check() if game_watch is not None else ""
                    if game_exited:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=5)
                        break
                    if proxy_limit:
                        streak = proxy_failures(live)[2]
                        if streak >= proxy_limit:
                            proxy_tripped = streak
                            process.terminate()
                            try:
                                process.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.wait(timeout=5)
                            break
                    failures = sum("ScreencapFailed" in line for line in live)
                    if failures > screencap_failures and now - last_settle >= SCREENCAP_SETTLE_INTERVAL:
                        last_settle = now
                        # 跑到一半不重启游戏：MaaCore 还连着、任务可能已经点过。
                        trail: list[str] = []
                        try:
                            warning = maa_playcover.settle_game_window(config, trail=trail)
                        except Exception as exc:  # noqa: BLE001 — (c) 救场是尽力而为，不能拖垮主循环
                            warning = f"摆回游戏窗口失败：{exc}"
                        note = f"{SCREENCAP_SETTLE_NOTE}{warning}".strip()
                        stderr_lines.append(note)
                        if progress is not None:
                            progress.note("screen_lost")
                        with log_lock:
                            for step in trail:
                                log_handle.write(step + "\n")
                            log_handle.write(note + "\n")
                    screencap_failures = failures
                    content = progress_content(prefix + live, plan=plan)
                    if progress is not None:
                        progress.update(prefix + live, live=live, plan=plan)
                    # 没有子区（Discord 不可用，不变量 #63）就不发进度，只写日志。
                    if content != previous and thread_id and progress_message_id:
                        try:
                            discord_request(
                                token,
                                "PATCH",
                                f"/channels/{thread_id}/messages/{progress_message_id}",
                                {"content": content, "allowed_mentions": {"parse": []}},
                            )
                            previous = content
                        except Exception as exc:  # noqa: BLE001 — (c) 进度流是尽力而为，最终战报才是硬信号
                            # Streaming is best-effort; final report is the hard signal.
                            # 每 5 秒一次，同一个错误只打一次，免得刷屏。
                            error_text = f"{type(exc).__name__}: {exc}"
                            if error_text != progress_error:
                                print(f"progress update failed: {error_text}", file=sys.stderr, flush=True)
                                progress_error = error_text
                    next_update = now + PROGRESS_INTERVAL_SECONDS
                time.sleep(0.25)
        except KeyboardInterrupt:
            interrupted = True
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        return_code = process.wait()
        stderr_thread.join(timeout=2)
        stdout_thread.join(timeout=2)
    if interrupted:
        interrupt_message = "maa run 已按人工指令终止。"
        stderr_lines.append(interrupt_message)
        with log_path.open("a", encoding="utf-8") as log_handle:
            log_handle.write(interrupt_message + "\n")
        return_code = 130
    elif timed_out:
        timeout_message = "maa run 超时，已终止；可能是客户端更新、登录提示或识别流程卡住。"
        stderr_lines.append(timeout_message)
        with log_path.open("a", encoding="utf-8") as log_handle:
            log_handle.write(timeout_message + "\n")
        return_code = 124
        if progress is not None:
            progress.note("timeout")
    elif proxy_tripped:
        if progress is not None:
            progress.note("proxy_break", n=proxy_tripped)
        break_message = (
            f"连续 {proxy_tripped} 批代理指挥失误，理智全额返还、一关没打成，"
            "已中止 maa run，避免空转到超时。"
        )
        stderr_lines.append(break_message)
        with log_path.open("a", encoding="utf-8") as log_handle:
            log_handle.write(break_message + "\n")
        return_code = PROXY_BREAK_CODE
    elif game_exited:
        reports = maa_playcover.crash_reports_since(config, started_wall)
        exit_message = (
            f"{GAME_EXITED_NOTE}（{now_beijing():%H:%M:%S} 发现，{game_exited}），"
            "MaaCore 不会重连，已停掉 maa run。"
            + (f"崩溃报告：{reports[0]}" if reports else "没有崩溃报告。")
        )
        stderr_lines.append(exit_message)
        with log_path.open("a", encoding="utf-8") as log_handle:
            log_handle.write(exit_message + "\n")
        return_code = GAME_EXITED_CODE
    return return_code, stdout_lines, stderr_lines


def run_maa_resilient(
    config: Config,
    log_path: Path,
    token: str,
    thread_id: str,
    progress_message_id: str,
    plan: Plan | None = None,
    *,
    timeout: int | None = None,
    carry_lines: list[str] | None = None,
    log_preamble: list[str] | None = None,
    progress: RunProgressFile | None = None,
    task_path: Path | None = None,
) -> tuple[int, list[str], list[str], int, int]:
    """跑 maa run；一个键都没点成的两类失败上重开。末两位是（连接重开, 掉线重开）次数。

    1. **连接失败**（`connect_failed()`）：MaaTools 没连上或截图拿不到，没有任何任务
       跑到 Completed。等 `connect_retry_delay` 秒，把游戏窗口摆回 MAA-Game 台前（激活
       救不回来就重启游戏）、等 MaaTools 就绪再重开。几趟的输出拼在一起交回去。
    2. **没登录上**（`never_logged_in()`，2026-11-09 早场）：游戏弹「获取网络配置失败」，
       点确认救不回来。等 `offline_retry_delays` 里对应的秒数给故障留时间恢复，然后
       **一律重启游戏**、摆窗、整场重跑。死掉那一趟的输出**不交回去**（它的 Mall /
       Award 会假报 Completed），只留我们自己写的说明；完整现场在日志文件里。
    3. **游戏中途退出**（`run_maa()` 返回 `GAME_EXITED_CODE`，2026-11-25 手动场，#68）：
       MaaCore 不会重连新进程。重启游戏、摆窗，按 `game_exit_plan()` 去掉已经跑完的
       任务链后接着跑，最多 `game_exit_retry_limit` 次。给了 `task_path` 才改写任务文件，
       否则按原计划重跑。几趟的输出拼在一起交回去（战报按任务链取任一趟的 Completed）。

    所有重开共用同一个超时预算，绝不额外撑长 Hermes 那一小时；日志追加进同一个文件，
    不覆盖上一趟的现场。`log_preamble` 先写进日志开头（开跑前的摆窗留痕）。
    放弃时的说明里一定带 `CONNECT_GAVE_UP` / `OFFLINE_GAVE_UP` / `GAME_EXIT_GAVE_UP`，
    调用方据此跳过补跑。
    """
    if log_preamble:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("".join(line + "\n" for line in log_preamble), encoding="utf-8")
    budget = int(config.get("maa_run_timeout", 3000) if timeout is None else timeout)
    limit = max(0, int(config.get("connect_retry_limit", 2)))
    delay = max(0, int(config.get("connect_retry_delay", 8)))
    offline_limit = max(0, int(config.get("offline_retry_limit", 2)))
    offline_delays = offline_retry_delays(config)
    exit_limit = max(0, int(config.get("game_exit_retry_limit", 1)))
    started = time.monotonic()
    stdout_all: list[str] = []
    stderr_all: list[str] = []
    # 我们自己写进 stderr 的说明：掉线重开丢掉死掉那一趟的输出时，只留这些。
    notes: list[str] = []
    retries = 0
    offline_retries = 0
    game_exits = 0
    attempts = 0
    # 这一趟实际要跑的计划：游戏中途退出后只剩没跑完的任务链（进度和战报仍按原计划）。
    attempt_plan = cast(Plan, dict(plan or {}))

    def say(message: str) -> None:
        notes.append(message)
        stderr_all.append(message)
        _append_log(log_path, message)

    while True:
        remaining = budget - int(time.monotonic() - started)
        # 游戏中途退出过时，前几趟真跑完的任务链要留给战报（掉线重开只丢这一趟的输出）。
        kept_out, kept_err = list(stdout_all), list(stderr_all)
        code, out, err = run_maa(
            config,
            log_path,
            token,
            thread_id,
            progress_message_id,
            plan,
            timeout=remaining,
            carry_lines=list(carry_lines or []) + stdout_all + stderr_all,
            append=attempts > 0 or bool(log_preamble),
            progress=progress,
            game_watch=maa_playcover.GameExitWatch(config),
        )
        attempts += 1
        stdout_all += out
        stderr_all += err
        spent = int(time.monotonic() - started)
        if code == GAME_EXITED_CODE:
            if (
                game_exits >= exit_limit
                or budget - spent - RESTART_ALLOWANCE_SECONDS < MIN_RUN_TIMEOUT_SECONDS
            ):
                say(f"{GAME_EXITED_NOTE}，已重开 {game_exits} 次，{GAME_EXIT_GAVE_UP}。")
                if progress is not None:
                    progress.note("game_exit_gave_up")
                return code, stdout_all, stderr_all, retries, offline_retries
            game_exits += 1
            attempt_plan = game_exit_plan(attempt_plan, out + err)
            left = [
                label
                for flag, label in (
                    ("infrast", "基建"),
                    ("recruit", "公招"),
                    ("mall", "商店"),
                    ("award", "领奖"),
                )
                if (attempt_plan.get("tasks") or {}).get(flag, True)
            ]
            if (attempt_plan.get("tasks") or {}).get("fight", True):
                left[:0] = [
                    *(["剿灭"] if attempt_plan.get("annihilation") else []),
                    *(["刷理智"] if attempt_plan.get("farming", True) else []),
                ]
            say(
                f"{GAME_EXITED_NOTE}后重启游戏、接着跑第 {game_exits} 趟："
                + ("、".join(left) if left else "只登录并回主界面")
                + "。"
            )
            if progress is not None:
                progress.note("game_exited", n=game_exits, limit=exit_limit)
            if task_path is not None:
                atomic_write_text(task_path, render_daily_toml(attempt_plan, config))
            exit_trail: list[str] = []
            try:
                warnings = maa_playcover.restart_game(config)
                settled = maa_playcover.settle_game_window(config, trail=exit_trail)
                warning = "；".join([*warnings, *([settled] if settled else [])])
            except Exception as exc:  # noqa: BLE001 — (c) 重启尽力而为，下一趟 maa run 自己会报连接失败
                warning = f"重启游戏失败：{exc}"
            for step in exit_trail:
                _append_log(log_path, step)
            if warning:
                say(warning)
            continue
        marker = connect_failed(out + err, code)
        if marker:
            if retries >= limit or budget - spent - delay < MIN_RUN_TIMEOUT_SECONDS:
                say(f"游戏连接失败（{marker}），重试 {retries} 次{CONNECT_GAVE_UP}。")
                if progress is not None:
                    progress.note("connect_gave_up")
                return code, stdout_all, stderr_all, retries, offline_retries
            retries += 1
            say(
                f"游戏连接失败（{marker}）：MaaTools 没连上或截图为空，没有任务跑完。"
                f"等 {delay}s、把游戏窗口摆回台前后重开第 {retries} 趟。"
            )
            if progress is not None:
                progress.note("connect_retry", wait=_wait_text(delay), n=retries, limit=limit)
            time.sleep(delay)
            trail: list[str] = []
            try:
                warning = maa_playcover.settle_game_window(config, allow_restart=True, trail=trail)
                maa_playcover.wait_for_game(config)
            except Exception as exc:  # noqa: BLE001 — (c) 重开前准备尽力而为，下一趟 maa run 自己会再报连接失败
                warning = f"重开前准备游戏失败：{exc}"
            for step in trail:
                _append_log(log_path, step)
            if warning:
                say(warning)
            continue
        if code != 0 and code not in SELF_ASSIGNED_CODES and never_logged_in(out + err):
            wait = offline_delays[min(offline_retries, len(offline_delays) - 1)]
            if (
                offline_retries >= offline_limit
                or budget - spent - wait - RESTART_ALLOWANCE_SECONDS < MIN_RUN_TIMEOUT_SECONDS
            ):
                say(f"游戏没登录上（获取网络配置失败），重启游戏 {offline_retries} 次{OFFLINE_GAVE_UP}。")
                if progress is not None:
                    progress.note("offline_gave_up")
                return code, stdout_all, stderr_all, retries, offline_retries
            offline_retries += 1
            say(
                f"游戏没登录上（{GAME_OFFLINE_MARKER}：获取网络配置失败），点确认救不回来。"
                f"等 {wait}s 后重启游戏、整场重跑第 {offline_retries} 趟。"
            )
            if progress is not None:
                progress.note("offline_retry", wait=_wait_text(wait), n=offline_retries, limit=offline_limit)
            time.sleep(wait)
            _append_log(log_path, conf_probe())
            trail = []
            try:
                warnings = maa_playcover.restart_game(config)
                settled = maa_playcover.settle_game_window(config, trail=trail)
                warning = "；".join([*warnings, *([settled] if settled else [])])
            except Exception as exc:  # noqa: BLE001 — (c) 重启尽力而为，下一趟 maa run 自己会报连接失败
                warning = f"重启游戏失败：{exc}"
            for step in trail:
                _append_log(log_path, step)
            if warning:
                say(warning)
            # 死掉那一趟什么都没做成（never_logged_in 的第三条），它的输出只会让战报
            # 读到假 Completed；现场在日志文件里。游戏中途退出过时，退出前那几趟真跑完的
            # 任务链留着（#68），只丢这一趟。
            if game_exits:
                stdout_all = kept_out
                stderr_all = kept_err + [note for note in notes if note not in kept_err]
            else:
                stdout_all = []
                stderr_all = list(notes)
            continue
        return code, stdout_all, stderr_all, retries, offline_retries


DEFAULT_OFFLINE_RETRY_DELAYS = (120, 300)


def offline_retry_delays(config: Config) -> list[int]:
    """`offline_retry_delays`：第 n 次重启前等几秒。比次数短时用最后一个值补；写歪了用默认。"""
    raw = config.get("offline_retry_delays")
    if isinstance(raw, list):
        values = [
            max(0, int(item))
            for item in cast(list[Any], raw)
            if isinstance(item, int) and not isinstance(item, bool)
        ]
        if values:
            return values
    return list(DEFAULT_OFFLINE_RETRY_DELAYS)


def _append_log(log_path: Path, message: str) -> None:
    try:
        with log_path.open("a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    except OSError:
        pass


def salvage_plan(plan: Plan) -> Plan | None:
    """去掉 Fight 的补跑计划；除 Fight 外无事可做时返回 None。"""
    tasks = dict(plan.get("tasks", {}))
    if not any(bool(tasks.get(key, True)) for key in ("infrast", "recruit", "mall", "award")):
        return None
    tasks["fight"] = False
    return {**plan, "tasks": tasks}


def _summary_completed(lines: list[str], key: str, label: str) -> bool:
    """maa-cli 收尾汇总里这条任务链报了 Completed。只认汇总的 `[名字]` 行，不认流式的
    `<Task> Completed`：剿灭和刷理智都是 Fight，流式行分不清是哪一块。"""
    names = _task_display_names(key, label)
    return any(
        _SUMMARY_HEAD_RE.match(line.strip()) and "Completed" in line
        for line in lines
        if any(f"[{name}]" in line for name in names)
    )


def _started_past_startup(lines: list[str]) -> bool:
    """StartUp 之外有任务链开过头（流式 `<Task> Start`，或汇总里带了开始时间）。"""
    for kind, _body in _stream_segments(lines):
        if kind != "StartUp":
            return True
    return any(
        _SUMMARY_HEAD_RE.match(line.strip()) and not line.strip().startswith("[启动国服]")
        for line in lines
    )


def game_exit_plan(plan: Plan, lines: list[str]) -> Plan:
    """游戏中途退出后接着跑的计划（不变量 #68）：去掉死掉那一趟已经跑完的任务链。

    - 基建 / 公招 / 商店 / 领奖：汇总里报了 Completed 的不再跑。
    - 刷理智：两块都跑完（没有第二块时第一块跑完）才不再跑；没跑完就照原计划再跑，
      理智花多少由游戏决定，`stone` / `medicine` / `series` 都不变。
    - 剿灭：StartUp 之外有任何任务链开过头就不再进，免得重复消耗代理卡。
    - StartUp 和返回主界面每趟都跑。只改 `tasks` / `annihilation` / `farming`，不动快照（#10）。
    """
    tasks = dict(plan.get("tasks", {}))
    for key, flag in (("Infrast", "infrast"), ("Recruit", "recruit"), ("Mall", "mall"), ("Award", "award")):
        if _summary_completed(lines, key, _TASK_LABELS[key]):
            tasks[flag] = False
    second_planned = bool(plan.get("farming_drops") and plan.get("farming_fallback_stage"))
    farming_done = _summary_completed(lines, "Fight", FARMING_TASK_NAMES[0]) and (
        not second_planned or _summary_completed(lines, "Fight2", FARMING_TASK_NAMES[1])
    )
    annihilation = bool(plan.get("annihilation", True)) and not _started_past_startup(lines)
    farming = bool(plan.get("farming", True)) and not farming_done
    if not annihilation and not farming:
        tasks["fight"] = False
    return {**plan, "tasks": tasks, "annihilation": annihilation, "farming": farming}


def fallback_fight_plan(plan: Plan) -> Plan | None:
    """主关 Fight 空跑失败后，只刷后备关的补跑计划；没有可用后备关时返回 None。

    2026-09-09 早场：SR-8 的代理指挥没解锁，`Fight Error` 一颗理智没花，MaaCore 接着把
    基建 / 公招 / 商店 / 奖励都跑完了，唯独 `farming_fallback_stage = SR-7` 躺在计划里
    没人用——那一场 94 理智白挂到晚上。补跑只带 Fight：其余链条已经跑过，重跑是重复劳动；
    剿灭按游戏日记账，也不重进。
    """
    if not bool((plan.get("tasks") or {}).get("fight", True)) or not plan.get("farming", True):
        return None
    spare = str(plan.get("farming_fallback_stage") or "").strip()
    if not spare or spare == str(plan.get("stage") or ""):
        return None
    tasks = {key: False for key in ("infrast", "recruit", "mall", "award")}
    tasks["fight"] = True
    return {
        **plan,
        "stage": spare,
        "tasks": tasks,
        "annihilation": False,
        "farming": True,
        "fallback_run": True,
    }


def fight_failed_dry(lines: list[str]) -> bool:
    """主关的 Fight 段以 Error 收尾、且一次作战都没发起（一颗理智没花）。

    只认 maa-cli 汇总里 `[刷理智]` 那一段：段里没有 `Fight <关> n times`、没有掉落，
    才算「空跑」。打了几批之后才报错的不算——那是别的问题，补跑后备关只会把
    理智花在没人核对过的地方。第二块已经跑过（drops 上限那条路）也不补。
    """
    return _main_fight_was_dry(lines) and not _named_task_section(lines, FARMING_TASK_NAMES[1])


def _main_fight_was_dry(lines: list[str]) -> bool:
    """`[刷理智]` 段以 Error 收尾且没打过一批（战报文案与补跑判定共用）。"""
    section = _named_task_section(lines, FARMING_TASK_NAMES[0])
    if not section or _task_state(section, "Fight", FARMING_TASK_NAMES[0]) != "failed":
        return False
    return not (_fight_times(section) or _drop_pairs(section))


def _fallback_fight_run(
    *,
    config: Config,
    plan: Plan,
    task_path: Path,
    log_path: Path,
    token: str,
    thread_id: str,
    progress_message_id: str,
    carry_lines: list[str],
    elapsed: float,
    progress: RunProgressFile | None = None,
) -> tuple[int | None, list[str], list[str]]:
    """主关空跑失败后改刷后备关。返回码为 None 表示没跑（无后备关 / 关闭 / 时间不够）。"""
    if not bool(config.get("fight_fallback_on_error", True)):
        return None, [], []
    retry_plan = fallback_fight_plan(plan)
    if retry_plan is None:
        return None, [], []
    remaining = int(config.get("maa_run_timeout", 3000)) - int(elapsed)
    floor = max(60, int(config.get("fight_fallback_min_seconds", 300)))
    if remaining < floor:
        if progress is not None:
            progress.note("no_time")
        return None, [], [f"剩余预算 {max(0, remaining)}s 不足 {floor}s，跳过后备关补跑。"]
    atomic_write_text(task_path, render_daily_toml(retry_plan, config))
    if progress is not None:
        progress.note("fallback", stage=plan_stage_label(plan), spare=retry_plan.get("stage"))
    code, out, err = run_maa(
        config,
        log_path,
        token,
        thread_id,
        progress_message_id,
        retry_plan,
        timeout=remaining,
        carry_lines=carry_lines,
        progress=progress,
        game_watch=maa_playcover.GameExitWatch(config),
    )
    note = (
        f"刷理智 {plan_stage_label(plan)} 失败且未消耗理智，"
        f"已改刷后备关 {retry_plan.get('stage')}（其余任务链不重跑）。"
    )
    return code, out, [note, *err]


def _salvage_run(
    *,
    config: Config,
    plan: Plan,
    task_path: Path,
    log_path: Path,
    token: str,
    thread_id: str,
    progress_message_id: str,
    carry_lines: list[str],
    elapsed: float,
    progress: RunProgressFile | None = None,
) -> tuple[int | None, list[str], list[str]]:
    """熔断后补跑剩余任务链。返回码为 None 表示没跑（无事可做或时间不够）。"""
    if not bool(config.get("proxy_failure_salvage", True)):
        return None, [], []
    retry_plan = salvage_plan(plan)
    if retry_plan is None:
        return None, [], []
    # 两趟 maa run 共用同一个 maa_run_timeout 预算，别把 Hermes 的一小时撑爆。
    remaining = int(config.get("maa_run_timeout", 3000)) - int(elapsed)
    floor = max(60, int(config.get("proxy_failure_salvage_min_seconds", 300)))
    if remaining < floor:
        if progress is not None:
            progress.note("no_time")
        return None, [], [f"剩余预算 {max(0, remaining)}s 不足 {floor}s，跳过补跑。"]
    atomic_write_text(task_path, render_daily_toml(retry_plan, config))
    if progress is not None:
        progress.note("salvage")
    code, out, err = run_maa(
        config,
        log_path,
        token,
        thread_id,
        progress_message_id,
        retry_plan,
        timeout=remaining,
        carry_lines=carry_lines,
        progress=progress,
        game_watch=maa_playcover.GameExitWatch(config),
    )
    return code, out, ["代理指挥失误熔断，已补跑剩余任务（不含刷理智）。", *err]


def report_payload(
    *,
    ok: bool,
    phase: Phase,
    plan: Plan,
    duration: float,
    summary: str,
    screenshot_ok: bool,
    screenshot_error: str,
    cleanup_errors: list[str],
    home_verified: bool | None = None,
    home_verify_detail: str = "",
    proxy_batches: int = 0,
    proxy_refunded: int = 0,
    connect_retries: int = 0,
    inventory_error: str = "",
    offline_retries: int = 0,
    offline_gave_up: bool = False,
    cancelled: bool = False,
    game_exits: int = 0,
    game_exit_gave_up: bool = False,
) -> dict[str, Any]:
    label = PHASE_LABELS[phase]
    notes: list[str] = []
    if cancelled:
        notes.append(CANCELLED_NOTE)
    if game_exit_gave_up:
        notes.append(
            f"游戏中途退出 {game_exits} 次，重启后没能接着跑完。"
            "运行日志里有退出时刻和崩溃报告路径。"
        )
    elif game_exits:
        notes.append(f"游戏中途退出过 {game_exits} 次，已重启游戏接着跑剩下的任务。")
    if offline_gave_up:
        notes.append(
            f"游戏一直没登录上（获取网络配置失败），重启游戏 {offline_retries} 次都没恢复。"
            "多半是鹰角服务器或线路的短时故障，稍后手动跑一场。"
        )
    elif offline_retries:
        notes.append(f"游戏没登录上（获取网络配置失败），重启游戏 {offline_retries} 次后登录成功。")
    if connect_retries:
        notes.append(
            f"游戏连接失败（MaaTools 没连上或截图为空），已重开 {connect_retries} 趟 maa run。"
            "偶发可以不管；每天都撞上就检查游戏窗口是否独占 MAA-Game 虚拟屏。"
        )
    if proxy_batches:
        notes.append(
            f"代理指挥失误 {proxy_batches} 批，理智已返还 ×{proxy_refunded}，实际一关没打成。"
            f"多半是 {plan_stage_label(plan)} 的作战录像跟不上随机性——"
            "手动重打一次三星刷新录像，或换个关卡。"
        )
    if not screenshot_ok:
        notes.append(f"截图失败：{screenshot_error}")
    if home_verified is False:
        notes.append(f"截图不是游戏主页：{home_verify_detail}")
    if cleanup_errors:
        notes.append("清理异常：" + "；".join(cleanup_errors))
    if inventory_error:
        notes.append(f"库存增量记录失败：{inventory_error}")
    embed: dict[str, Any] = {
        "title": (
            f"⏹️ MAA 日常·{label}已停止"
            if cancelled
            else f"{'✅' if ok else '❌'} MAA 日常·{label}{'完成' if ok else '失败'}"
        ),
        "color": 0x99AAB5 if cancelled else 0x57F287 if ok else 0xED4245,
        "fields": [
            {"name": "关卡", "value": plan_stage_label(plan), "inline": True},
            {
                "name": "理智药",
                "value": medicine_label(str(plan.get("medicine", "none"))),
                "inline": True,
            },
            {"name": "碎石", "value": "0", "inline": True},
            {"name": "总耗时", "value": _format_duration(duration), "inline": True},
            {"name": "📋 执行结果", "value": summary[:1024], "inline": False},
        ],
        "footer": {"text": "游戏进程已执行清理"},
        "timestamp": now_beijing().isoformat(),
    }
    if notes:
        embed["fields"].append({"name": "备注", "value": "\n".join(notes)[:1024]})
    if screenshot_ok:
        embed["image"] = {"url": "attachment://shot.png"}
    payload: dict[str, Any] = {
        "embeds": [embed],
        "allowed_mentions": {"parse": []},
    }
    if screenshot_ok:
        payload["attachments"] = [{"id": 0, "filename": "shot.png"}]
    return payload


def send_report(
    token: str,
    channel_id: str,
    payload: dict[str, Any],
    screenshot: Path,
    config: Config,
) -> None:
    if "attachments" in payload:
        try:
            discord_upload(token, channel_id, payload, screenshot)
            return
        except Exception as exc:  # noqa: BLE001 — (c) 内嵌截图上传失败退回纯 embed
            embed = dict(payload["embeds"][0])
            embed.pop("image", None)
            fields = list(embed.get("fields", []))
            fields.append({"name": "图片上传", "value": f"内嵌上传失败：{type(exc).__name__}"})
            embed["fields"] = fields
            discord_request(
                token,
                "POST",
                f"/channels/{channel_id}/messages",
                {"embeds": [embed], "allowed_mentions": {"parse": []}},
            )
            hermes = str(config.get("hermes_bin", Path.home() / ".local" / "bin" / "hermes"))
            subprocess.run(
                [hermes, "send", "--to", f"discord:{channel_id}", f"MEDIA:{screenshot}"],
                capture_output=True,
                check=False,
                timeout=30,
            )
            return
    discord_request(token, "POST", f"/channels/{channel_id}/messages", payload)


def send_direct_failure(
    token: str,
    channel_id: str,
    phase: Phase,
    plan: Plan,
    message: str,
) -> None:
    notify(
        token,
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [
                {
                    "title": f"❌ MAA 日常·{PHASE_LABELS[phase]}启动失败",
                    "description": message[:3500],
                    "color": 0xED4245,
                    "fields": [
                        {"name": "计划关卡", "value": plan_stage_label(plan), "inline": True},
                        {"name": "碎石", "value": "0", "inline": True},
                    ],
                    "timestamp": now_beijing().isoformat(),
                }
            ],
            "allowed_mentions": {"parse": []},
        },
        what="启动失败直报",
    )


def should_skip(plan: Plan, phase: Phase) -> bool:
    """Whether this run bails out before touching the game.

    `skip` is now **per session** (四期 D2): it comes from `sessions.<phase>`,
    so silencing 08:00 leaves 22:00 alone.  A manual run is the user asking for
    it right now, which overrides today's plan by definition — otherwise
    "跳过本场" would leave no way to run at all short of un-skipping.
    """
    return bool(plan.get("skip")) and phase != "now"


# K17：日常等更新的上限（分钟），要从 `maa_run_timeout` 里扣，Hermes 外层只有 1 小时。
DEFAULT_UPDATE_WAIT_MINUTES = 15
MIN_RUN_TIMEOUT = 600
UPDATE_WAIT_POLL_SECONDS = 5.0


def wait_for_update_holder(
    config: Config,
    *,
    sleep: Any = time.sleep,
    clock: Any = time.monotonic,
) -> float:
    """锁的持有者是「上游更新」就阻塞等它放锁，返回等了多少秒（不是更新 / 没被占返回 0）。

    上限 `update_wait_minutes`（默认 15）。到了上限还没放就不等了，交给后面的锁冲突处理
    （不变量 #23 照旧：写 `last_lock_conflict_*`、发 Discord、返回失败）。
    """
    marker = run_lock_holder()
    if not marker or marker.get("holder") != "update":
        return 0.0
    limit = max(0, int(config.get("update_wait_minutes", DEFAULT_UPDATE_WAIT_MINUTES))) * 60
    start = clock()
    while clock() - start < limit:
        sleep(UPDATE_WAIT_POLL_SECONDS)
        current = run_lock_holder()
        if not current or current.get("holder") != "update":
            break
    return clock() - start


def report_lock_conflict(
    config: Config,
    token: str,
    channel_id: str,
    phase: Phase,
    attempted_at: datetime,
) -> None:
    """Make a rejected daily run visible without clobbering the active run."""
    busy = lock_holder_text(run_lock_holder())
    reason = (
        f"{busy}正在用游戏，本场没有启动游戏或执行任何任务"
        if busy
        else "run.lock 被另一场 MAA 占用，本场没有启动游戏或执行任何任务"
    )
    # Another runner may currently own last_run.status=running. Keep its state
    # intact and append conflict-specific observation fields instead.
    errors: list[str] = []
    try:
        merge_last_run(
            {
                "last_lock_conflict_at": attempted_at.isoformat(),
                "last_lock_conflict_phase": phase,
                "last_lock_conflict_reason": reason,
            }
        )
    except Exception as exc:  # noqa: BLE001 — (a) 汇报路径：状态写入失败汇总后抛给调用方
        errors.append(f"冲突状态写入失败：{type(exc).__name__}: {exc}")
    # 告警发不出去只记日志（不变量 #63）；状态写不进去才抛。
    maa_notify.notify(
        f"❌ {PHASE_LABELS[phase]}场未启动",
        reason[:300],
        level="timeSensitive",
        notification_id=f"run-lock-{phase}-{attempted_at:%Y%m%d%H%M%S}",
        url="wadosmaa://today",
    )
    notify(
        token,
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [
                {
                    "title": f"❌ MAA 日常·{PHASE_LABELS[phase]}未启动",
                    "description": reason,
                    "color": 0xED4245,
                    "timestamp": attempted_at.isoformat(),
                }
            ],
            "allowed_mentions": {"parse": []},
        },
        what="冲突告警",
    )
    if errors:
        raise RuntimeError("；".join(errors))


def manual_run_stage(manual_token: str) -> str | None:
    """`maa_daily.py now <token>` 要刷的关（`PLAN_MANUAL_RUN.md` M-e）。

    请求必须是 `manual_run.json` 里**这个 token** 且已 `dispatched`；对不上返回 None，
    调用方不跑。token 为空（终端直接 `maa_daily.py now`）不走这里（M6）。
    """
    request = manual_run_request(manual_token)
    return None if request is None else str(request.get("stage") or "")


def manual_run_request(manual_token: str) -> dict[str, Any] | None:
    """整份手动场请求（关 + Wado's MAA「这一次」的环节开关）；对不上返回 None。"""
    with state_lock():
        state = check_schema(
            "manual_run.json", load_json(MANUAL_RUN_PATH, {}), MANUAL_RUN_SCHEMA_VERSION
        )
    if (
        not isinstance(state, dict)
        or state.get("token") != manual_token
        or state.get("status") != "dispatched"
        or "stage" not in state
    ):
        return None
    return state


def apply_local_switches(plan: Plan, request: dict[str, Any]) -> Plan:
    """把 `run local` 的「这一次」开关叠到本场计划上（K12）。

    `tasks` 只认五个已知环节、只认真布尔，缺的照默认；剿灭关掉时带上原因进战报。
    选关卡（Discord）派发的请求没有这两个字段，原样返回。
    """
    result: dict[str, Any] = dict(plan)
    tasks = request.get("tasks")
    if isinstance(tasks, dict):
        merged = dict(result.get("tasks") or DEFAULT_TASKS)
        for key in DEFAULT_TASKS:
            if isinstance(tasks.get(key), bool):
                merged[key] = tasks[key]
        result["tasks"] = merged
    if request.get("annihilation") is False and result.get("annihilation") is not False:
        result["annihilation"] = False
        result["annihilation_skip_reason"] = "这一次手动场关掉了剿灭"
    return cast(Plan, result)


def report_manual_run_mismatch(
    config: Config, token: str, channel_id: str, manual_token: str
) -> None:
    notify(
        token,
        "POST",
        f"/channels/{channel_id}/messages",
        {
            "embeds": [
                {
                    "title": "❌ MAA 日常·手动未启动",
                    "description": (
                        f"选关请求 `{manual_token}` 与 manual_run.json 对不上"
                        "（已过期、已作废或已被另一次派发消费），本场没有启动游戏或执行任何任务。"
                        "重新说「现在跑」再选一次。"
                    ),
                    "color": 0xED4245,
                    "timestamp": now_beijing().isoformat(),
                }
            ],
            "allowed_mentions": {"parse": []},
        },
        what="手动场对不上告警",
    )


def daily_failure(
    *,
    startup_error: str,
    offline_gave_up: bool,
    connect_gave_up: bool,
    timed_out: bool,
    proxy_batches: int,
    return_code: int,
    home_verified: bool | None,
    cleanup_errors: list[str],
    inventory_error: str,
    game_exit_gave_up: bool = False,
) -> str:
    """一场日常没成功的主因（场次索引 `failure`，#66）：按下面的先后取第一条。"""
    if startup_error:
        return "startup"
    if offline_gave_up:
        return "offline"
    if game_exit_gave_up:
        return "game_exited"
    if connect_gave_up:
        return "screen_lost"
    if timed_out:
        return "timeout"
    if proxy_batches:
        return "proxy"
    if return_code != 0:
        return "task_failed"
    if home_verified is False:
        return "not_home"
    if cleanup_errors:
        return "cleanup"
    if inventory_error:
        return "inventory"
    return "unknown"


def record_daily_run(
    *,
    phase: str,
    started: datetime,
    plan: Plan,
    status: str,
    progress: RunProgressFile | None = None,
    log_path: Path | None = None,
    report: str | None = None,
    failure: str | None = None,
    skip_reason: str | None = None,
    retries: int | None = None,
    restarts: int | None = None,
    game_exits: int | None = None,
) -> None:
    """一场日常结束，往 `runs/index.jsonl` 追加一行（#66）。永不抛。

    `retries` / `restarts` / `game_exits` 拿不到就是 None；`window_fixes` / `rescue` 来自进度文件的说明计数。
    """
    try:
        finished = now_beijing()
        counts = progress.counts if progress is not None else None
        rescue = None
        if counts and counts.get("salvage"):
            rescue = "salvage"
        elif counts and counts.get("fallback"):
            rescue = "fallback"
        fight_on = bool((plan.get("tasks") or {}).get("fight", True))
        row: dict[str, Any] = {
            "id": progress.run_id if progress is not None else make_run_id(phase, started),
            "kind": "daily",
            "phase": phase,
            "stage": str(plan.get("stage") or "") if fight_on else "",
            "started_at": started.isoformat(),
            "finished_at": finished.isoformat(),
            "duration_seconds": max(0, int((finished - started).total_seconds())),
            "status": status,
            "failure": failure if status == "failed" else None,
            "skip_reason": skip_reason if status == "skipped" else None,
            "retries": retries,
            "restarts": restarts,
            "game_exits": game_exits,
            "window_fixes": counts.get("screen_lost", 0) if counts is not None else None,
            "rescue": rescue,
            "report": report,
            "progress": str(progress.path) if progress is not None else None,
            "log": str(log_path) if log_path is not None else None,
        }
    except Exception as exc:  # noqa: BLE001 — (c) 索引只是统计，拼不出来不能拖垮跑场（#66）
        print(f"场次索引没写成：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        return
    append_run_index(RUNS_DIR, row)


def execute(phase: Phase, manual_token: str = "") -> int:
    """跑一场。`run cancel` 的 SIGINT（不变量 #64）：只有第一次打断，主流程里收到就照常
    关游戏、还原台前调度、发战报，`last_run.status = cancelled`；落在主流程之外（拿到
    锁之后、开游戏之前，或者收尾时）也补写 `cancelled`。返回 130。
    """
    marks: dict[str, Any] = {"locked": False, "finished": False, "progress": None, "record": None}
    with interrupt_once():
        try:
            return _execute(phase, manual_token, marks)
        except KeyboardInterrupt:
            if marks["locked"] and not marks["finished"]:
                # 索引先写：GUI 靠 `last_run.json` 的改动重读，那时这一行要已经在了（#66）。
                if marks["record"] is not None:
                    marks["record"]("cancelled")
                merge_last_run({
                    "status": "cancelled",
                    "finished_at": now_beijing().isoformat(),
                    "return_code": CANCEL_EXIT_CODE,
                    "summary": CANCELLED_NOTE,
                })
                if marks["progress"] is not None:
                    marks["progress"].finish("cancelled")
            return CANCEL_EXIT_CODE


def _execute(phase: Phase, manual_token: str, marks: dict[str, Any]) -> int:
    started = now_beijing()
    config = load_config()
    # Discord 只是通知出口：缺频道 / token 时两个都是空串，本场照跑（不变量 #63）。
    token, channel_id = discord_outlet(config)
    last_run_state = check_schema(
        "last_run.json", load_json(LAST_RUN_PATH, {}), LAST_RUN_SCHEMA_VERSION, strict=False
    )
    if not isinstance(last_run_state, dict):
        last_run_state = {}
    # 计划按场次求值（四期 D1~D3）：早场改的关不会带到晚场。
    # 手动场 `now` 没有场次覆盖：带 token 时刷选关卡上选的关（PLAN_MANUAL_RUN M4，
    # 不带 drops 上限和后备关）；不带 token 是终端排障入口，刷 defaults.json（M6）。
    base_plan = effective_plan(started, phase)
    request: dict[str, Any] = {}
    if phase == "now" and manual_token:
        found = manual_run_request(manual_token)
        if found is None:
            report_manual_run_mismatch(config, token, channel_id, manual_token)
            return 1
        request = found
        base_plan["stage"] = str(found.get("stage") or "")
        # 谁派的就记谁：保留白名单内的真实来源（gui / ios / discord）。
        raw_source = str(found.get("source") or "")
        base_plan["stage_source"] = raw_source if raw_source in ACTION_SOURCES else "discord"
        base_plan["farming_drops"] = {}
        base_plan["farming_fallback_stage"] = ""
    plan = attach_sanity_yield(
        apply_local_switches(attach_annihilation(base_plan, started, last_run_state), request),
        config,
        started,
    )
    run_id = make_run_id(phase, started)
    run_stem = run_id
    snapshot_path = RUNS_DIR / f"{run_stem}.json"
    log_path = RUNS_DIR / f"{run_stem}.log"
    screenshot_path = RUNS_DIR / f"{run_stem}.png"
    report_path = RUNS_DIR / f"{run_stem}-report.json"
    progress_path = progress_path_for(log_path)

    # K17：07:50 的上游更新拖过了开跑时间 → 等它跑完（有上限），等掉的时间从本场预算里扣。
    waited = wait_for_update_holder(config)
    if waited:
        config = cast(Config, {
            **config,
            "maa_run_timeout": max(
                MIN_RUN_TIMEOUT, int(config.get("maa_run_timeout", 3000)) - int(waited)
            ),
        })
    with run_lock(blocking=False, holder="daily", detail=PHASE_LABELS[phase], run_id=run_id) as acquired:
        if not acquired:
            report_lock_conflict(config, token, channel_id, phase, started)
            return 1
        marks["locked"] = True
        cleanup_run_files(int(config.get("retention_days", 14)), started)
        snapshot = {
            "run_id": run_id,
            "date": started.date().isoformat(),
            "phase": phase,
            "started_at": started.isoformat(),
            "plan": plan,
        }
        # This is the immutable per-run plan snapshot. Later plan.json writes
        # cannot change this Python object or this file.
        atomic_write_json(snapshot_path, snapshot)
        # 本场进度文件（#65）：先写一份空的，盖掉同名旧场；之后每 5 秒和收尾各写一次。
        progress = RunProgressFile(
            progress_path, phase=phase, plan=plan, config=config, started=started, run_id=run_id
        )
        marks["progress"] = progress

        def record(status: str, **extra: Any) -> None:
            """场次索引一场只写一行（#66）：收尾时被打断也不会再补一行。"""
            if marks.get("indexed"):
                return
            marks["indexed"] = True
            record_daily_run(
                phase=phase, started=started, plan=plan, status=status,
                progress=progress, log_path=log_path, **extra,
            )

        marks["record"] = record
        merge_last_run(
            {
                "run_id": run_id,
                "status": "running",
                "phase": phase,
                "started_at": started.isoformat(),
                "plan": plan,
                "snapshot": str(snapshot_path),
                # Do not expose terminal fields from the previous run while
                # this run is still booting and has not created its thread.
                "thread_id": None,
                "finished_at": None,
                "duration_seconds": None,
                "return_code": None,
                # 本场自己的日志路径不算「上一场的终态字段」：GUI 运行中靠它逐行跟
                # maa-cli 的 `<Task> Start` 显示当前阶段（DEV_GUIDE §12.3）。文件此刻
                # 可能还不存在，或仍是同名旧场的内容，等 maa run 开写才会被截断重写。
                "log": str(log_path),
                "screenshot": None,
                "screenshot_error": None,
                "startup_error": None,
                "cleanup_errors": [],
                "summary": "",
                "report": None,
                "progress": str(progress_path),
            },
            new_run=True,
        )

        if should_skip(plan, phase):
            notify(
                token,
                "POST",
                f"/channels/{channel_id}/messages",
                {
                    "embeds": [
                        {
                            "title": f"⏭️ MAA 日常·{PHASE_LABELS[phase]}已跳过",
                            "description": "计划卡上把**本场**设成了跳过；未启动游戏。"
                            "今天的另一场和手动开跑（「现在跑」）都不受影响。",
                            "color": 0x99AAB5,
                            "timestamp": started.isoformat(),
                        }
                    ],
                    "allowed_mentions": {"parse": []},
                },
                what="跳过通知",
            )
            maa_notify.notify(
                f"⏭️ {PHASE_LABELS[phase]}场已跳过",
                "本场已设为跳过，未启动游戏。",
                level="passive",
                notification_id=f"run-skip-{run_id}",
                url="wadosmaa://today",
            )
            record("skipped", skip_reason="plan", retries=0, restarts=0)
            merge_last_run({"status": "skipped", "finished_at": now_beijing().isoformat()})
            progress.finish("skipped")
            return 0

        # spike §6(c) 方案 B：开跑前离线查一次上游，只认「源被改了」和「不自洽」两种硬拒。
        # 自动场和手动场都查；其余（不新鲜、上游有新版）只显示，不挡跑。
        blocked = upstream_hard_block(config)
        if blocked:
            record("failed", failure="upstream", retries=0, restarts=0)
            report_upstream_block(token, channel_id, phase, blocked, now_beijing(), run_id=run_id)
            progress.finish("failed")
            return 1

        # PLAN_NAV_GATE B: the automatic phases must not take the device away
        # from a user who is playing — every failure path here would quit their
        # game (结论 3). `now` is an explicit "run it anyway" and skips this.
        if phase in AUTO_PHASES:
            online, probe_detail = maa_playcover.game_is_online(config)
            if online:
                record("skipped", skip_reason="game_busy", retries=0, restarts=0)
                report_game_busy(
                    config, token, channel_id, phase, probe_detail, now_beijing()
                )
                progress.finish("skipped")
                return 0

        game_opened = False
        launching = False
        cancelled = False
        session_open = False
        thread_id = ""
        progress_message_id = ""
        stdout_lines: list[str] = []
        stderr_lines: list[str] = []
        return_code = 1
        screenshot_ok = False
        screenshot_error = "未执行"
        home_verified: bool | None = None
        home_verify_detail = ""
        cleanup_errors: list[str] = []
        inventory_error = ""
        salvage_log_path: Path | None = None
        connect_retries = 0
        offline_retries = 0
        startup_error = ""
        # 不变量 #62：拿到锁之后、开游戏之前关台前调度，finally 里关完游戏再还原。永不抛。
        stage_manager_paused = maa_playcover.pause_stage_manager(config)
        if stage_manager_paused:
            progress.note("stage_manager")
        try:
            require_executable(config, "maa_bin", "/opt/homebrew/bin/maa", "maa-cli")
            maa_playcover.verify_game_installed(config)
            launching = True
            progress.boot()
            maa_playcover.launch_game(config)
            game_opened = True
            maa_playcover.wait_for_game(config)
            # 到这里才算「开始干活」：之后的异常进战报，之前的异常走启动失败直报。
            session_open = True
            maa_notify.notify(
                f"{PHASE_LABELS[phase]}场开跑 · {plan_stage_label(plan)}",
                "游戏已就绪，开始执行日常任务。",
                level="passive",
                notification_id=f"run-{run_id}",
                url=f"wadosmaa://run/{run_id}",
            )
            # 开跑消息、子区、进度占位都是尽力而为：Discord 连不上就空着，本场照跑（#63）。
            thread_id, progress_message_id = open_thread(
                token, channel_id, phase, plan, started
            )
            if thread_id:
                merge_last_run(
                    {
                        "thread_id": thread_id,
                        "threads": [{"thread_id": thread_id, "created_at": started.isoformat()}],
                    }
                )
            task_path = Path(str(config.get("maa_config_dir", MAA_CONFIG_DIR))) / "tasks" / "daily.toml"
            atomic_write_text(task_path, render_daily_toml(plan, config))
            # 最后一道门：游戏窗口必须在 MAA-Game 虚拟屏的台前，否则 MaaTools 截图为空、
            # 整场空跑。激活救不回来就重启游戏（还一个键都没点过）；摆不回来只记一条警告，
            # 不阻断（maa run 自己会报连接失败并重开）。每一步写进日志开头。
            settle_trail: list[str] = []
            settle_warning = maa_playcover.settle_game_window(
                config, allow_restart=True, trail=settle_trail
            )
            if settle_warning:
                stderr_lines.append(settle_warning)
                progress.note("window")
            prior_errors = list(stderr_lines)
            (
                return_code,
                stdout_lines,
                run_errors,
                connect_retries,
                offline_retries,
            ) = run_maa_resilient(
                config,
                log_path,
                token,
                thread_id,
                progress_message_id,
                plan,
                carry_lines=prior_errors,
                log_preamble=settle_trail,
                progress=progress,
                task_path=task_path,
            )
            stderr_lines = prior_errors + run_errors
            cancelled = return_code == CANCEL_EXIT_CODE
            # 重开到底还是拿不到游戏画面 / 登录不上 / 游戏又退了：补跑只是换个关卡 / 换条链，
            # 在同一个死掉的游戏上救不回来，跳过（2026-11-09 早场的后备关补跑就是白跑）。
            if any(CONNECT_GAVE_UP in line for line in run_errors):
                lost_note = SCREEN_LOST_SKIP_NOTE
            elif any(OFFLINE_GAVE_UP in line for line in run_errors):
                lost_note = OFFLINE_SKIP_NOTE
            elif return_code == GAME_EXITED_CODE:
                lost_note = GAME_EXIT_SKIP_NOTE
            else:
                lost_note = ""
            # 125 也可能是 maa 自己的退出码，所以还要确认日志里真有代理失误，
            # 免得凭一个数字就多跑一趟。
            if cancelled:
                pass  # 停下就是停下：不补跑、不换关（#64）。
            elif lost_note:
                if return_code == PROXY_BREAK_CODE or fight_failed_dry(stdout_lines + stderr_lines):
                    stderr_lines.append(lost_note)
            elif return_code == PROXY_BREAK_CODE and fight_wiped_out(stdout_lines + stderr_lines)[0]:
                # 熔断掐掉的是整条 maa run，基建/公招/商店/奖励也一起没了。补跑一趟
                # 去掉 Fight 的链条把它们捞回来——StartUp 会顺手把卡在结算页的游戏
                # 带回主界面。预算从总超时里扣，绝不额外撑长 Hermes 那一小时。
                salvage_log = RUNS_DIR / f"{run_stem}-salvage.log"
                salvage_code, salvage_out, salvage_err = _salvage_run(
                    config=config,
                    plan=plan,
                    task_path=task_path,
                    log_path=salvage_log,
                    token=token,
                    thread_id=thread_id,
                    progress_message_id=progress_message_id,
                    carry_lines=stdout_lines + stderr_lines,
                    elapsed=(now_beijing() - started).total_seconds(),
                    progress=progress,
                )
                if salvage_code is not None:
                    return_code = salvage_code
                    salvage_log_path = salvage_log
                stdout_lines += salvage_out
                stderr_lines += salvage_err
            elif return_code != 0 and fight_failed_dry(stdout_lines + stderr_lines):
                # 主关一颗理智没花就 Error（2026-09-09 早场 SR-8 代理指挥未解锁），其余
                # 链条 MaaCore 已经跑完。只补一趟 Fight 打后备关，预算同样从总超时里扣。
                fallback_log = RUNS_DIR / f"{run_stem}-fallback.log"
                fallback_code, fallback_out, fallback_err = _fallback_fight_run(
                    config=config,
                    plan=plan,
                    task_path=task_path,
                    log_path=fallback_log,
                    token=token,
                    thread_id=thread_id,
                    progress_message_id=progress_message_id,
                    carry_lines=stdout_lines + stderr_lines,
                    elapsed=(now_beijing() - started).total_seconds(),
                    progress=progress,
                )
                if fallback_code is not None:
                    return_code = fallback_code
                    salvage_log_path = fallback_log
                stdout_lines += fallback_out
                stderr_lines += fallback_err
            cancelled = cancelled or return_code == CANCEL_EXIT_CODE
            # The final Custom task has returned to Home. Let the last UI
            # animation settle, then capture before the separate CloseDown and
            # confirm by OCR that the frame we ship really is the home page.
            # 停下来的那一场不在主页，不截。
            if cancelled:
                screenshot_error = "已停止，没有截图"
            else:
                (
                    screenshot_ok,
                    screenshot_error,
                    home_verified,
                    home_verify_detail,
                ) = capture_home_screenshot(config, screenshot_path)
        except KeyboardInterrupt:
            # `run cancel`（#64）：落在 maa run 之外（开游戏、等游戏、截图、重开前的等待）。
            # 只有这一次会打断（interrupt_once），下面照常关游戏、还原、发战报。
            cancelled = True
            return_code = CANCEL_EXIT_CODE
            stderr_lines.append(CANCELLED_NOTE)
        except Exception as exc:  # noqa: BLE001 — (a) 整场兜底：异常进战报 / 直报，finally 照常关游戏
            exception_detail = f"{type(exc).__name__}: {exc}"
            stderr_lines.append(exception_detail)
            return_code = 1
            if not session_open:
                startup_error = exception_detail
                try:
                    send_direct_failure(token, channel_id, phase, plan, exception_detail)
                except Exception as report_exc:  # noqa: BLE001 — (b) 直报失败不能盖住主错误（主错误已在 stderr_lines）
                    print(
                        f"direct failure report failed: {type(report_exc).__name__}: {report_exc}",
                        file=sys.stderr,
                        flush=True,
                    )
        finally:
            # 停在开游戏半路上也要关（#64）：游戏可能已经拉起来了。
            if game_opened or (cancelled and launching):
                try:
                    cleanup_errors = maa_playcover.close_game(config)
                except Exception as exc:  # noqa: BLE001 — (b) 收尾清理不能盖住主错误，异常并入 cleanup_errors
                    cleanup_errors = [f"清理异常：{type(exc).__name__}: {exc}"]
            if stage_manager_paused:
                maa_playcover.restore_stage_manager()

        # 两个刷理智块的掉落一起回写库存估算（四期步骤 3b）。
        fight_lines = farming_sections(stdout_lines + stderr_lines)
        drops = _drop_pairs(fight_lines) if fight_lines else []
        if drops:
            try:
                maa_depot.record_drops(drops, config, at=now_beijing())
            except Exception as exc:  # noqa: BLE001 — (c) 掉落记账失败只进战报 inventory_error
                inventory_error = f"{type(exc).__name__}: {exc}"

        duration = (now_beijing() - started).total_seconds()
        # 代理指挥失误到一关没打成，就算后面的链条都补回来了也不算成功——得让人
        # 看见红色去修作战录像，否则理智白挂在那儿谁也不知道。
        proxy_batches, proxy_refunded = fight_wiped_out(stdout_lines + stderr_lines)
        game_exits = game_exit_count(stderr_lines)
        game_exit_gave_up = return_code == GAME_EXITED_CODE or any(
            GAME_EXIT_GAVE_UP in line and line.startswith(GAME_EXITED_NOTE) for line in stderr_lines
        )
        ok = (
            not cancelled
            and return_code == 0
            and not cleanup_errors
            and home_verified is not False
            and not proxy_batches
            and not inventory_error
        )
        summary = extract_summary(
            stdout_lines,
            stderr_lines,
            plan=plan,
            ok=ok,
            home_verified=home_verified,
            home_verify_detail=home_verify_detail,
        )
        if cancelled:
            summary = f"⏹️ {CANCELLED_NOTE}\n{summary}".strip()
        if thread_id and progress_message_id:
            final_heading = (
                f"⏹️ 已停止 · 总耗时 {_format_duration(duration)}"
                if cancelled
                else f"{'✅' if ok else '❌'} 结束 · 总耗时 {_format_duration(duration)}"
            )
            try:
                discord_request(
                    token,
                    "PATCH",
                    f"/channels/{thread_id}/messages/{progress_message_id}",
                    {
                        "content": progress_content(
                            stdout_lines + stderr_lines,
                            plan=plan,
                            final=final_heading,
                        ),
                        "allowed_mentions": {"parse": []},
                    },
                )
            except Exception as exc:  # noqa: BLE001 — (c) 进度消息收尾是尽力而为，最终战报才是硬信号
                print(f"final progress update failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        # 战报两个出口（不变量 #63）：文件一定写；Discord 只在开始干活之后发
        # （启动失败已经直报过），发不出去只记日志。
        payload = report_payload(
            ok=ok,
            phase=phase,
            plan=plan,
            duration=duration,
            summary=summary,
            screenshot_ok=screenshot_ok,
            screenshot_error=screenshot_error,
            cleanup_errors=cleanup_errors,
            home_verified=home_verified,
            home_verify_detail=home_verify_detail,
            proxy_batches=proxy_batches,
            proxy_refunded=proxy_refunded,
            connect_retries=connect_retries,
            inventory_error=inventory_error,
            offline_retries=offline_retries,
            offline_gave_up=any(OFFLINE_GAVE_UP in line for line in stderr_lines),
            cancelled=cancelled,
            game_exits=game_exits,
            game_exit_gave_up=game_exit_gave_up and not cancelled,
        )
        report_error = write_report_file(report_path, payload)
        if (session_open or cancelled) and token and channel_id:
            try:
                send_report(token, channel_id, payload, screenshot_path, config)
            except Exception as exc:  # noqa: BLE001 — (c) 战报发不出去只记日志，终态照写
                print(f"战报发送失败：{type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        # 统一通知矩阵（S1-3 / S0-5 实证：同 id=run-<run_id> 原地覆盖，失败升权 timeSensitive 正常亮屏）。
        notify_title = (
            f"⏹️ {PHASE_LABELS[phase]}场已停止 · {plan_stage_label(plan)}"
            if cancelled
            else f"✅ {PHASE_LABELS[phase]}场完成 · {plan_stage_label(plan)}"
            if ok
            else f"❌ {PHASE_LABELS[phase]}场异常 · {plan_stage_label(plan)}"
        )
        notify_body = (
            startup_error[:300]
            if (not ok and not cancelled and startup_error)
            else summary[:400] or f"总耗时 {_format_duration(duration)}"
        )
        maa_notify.notify(
            notify_title,
            notify_body,
            level="passive" if cancelled else "active" if ok else "timeSensitive",
            notification_id=f"run-{run_id}",
            url=f"wadosmaa://run/{run_id}",
        )
        finished: LastRun = {
            "status": "cancelled" if cancelled else "success" if ok else "failed",
            "finished_at": now_beijing().isoformat(),
            "duration_seconds": int(duration),
            "return_code": return_code,
            "log": str(log_path),
            "salvage_log": str(salvage_log_path) if salvage_log_path else None,
            "screenshot": str(screenshot_path) if screenshot_ok else None,
            "screenshot_error": screenshot_error if not screenshot_ok else None,
            "startup_error": startup_error or None,
            "home_verified": home_verified,
            "home_verify_detail": home_verify_detail,
            "cleanup_errors": cleanup_errors,
            "summary": summary,
            "proxy_failure_batches": proxy_batches,
            "proxy_failure_sanity_refunded": proxy_refunded,
            "connect_retries": connect_retries,
            "offline_retries": offline_retries,
            "game_exits": game_exits,
            "inventory_error": inventory_error or None,
            "report": None if report_error else str(report_path),
        }
        if cancelled:
            progress.note("cancelled")
        progress.finish(finished["status"], stdout_lines + stderr_lines)
        if plan.get("annihilation") and annihilation_consumed(stdout_lines + stderr_lines):
            finished["annihilation_game_day"] = cn_game_day(started)
            finished["annihilation_finished_at"] = now_beijing().isoformat()
        record(
            finished["status"],
            report=finished["report"],
            failure=daily_failure(
                startup_error=startup_error,
                offline_gave_up=any(OFFLINE_GAVE_UP in line for line in stderr_lines),
                connect_gave_up=any(CONNECT_GAVE_UP in line for line in stderr_lines),
                timed_out=bool(progress.counts.get("timeout")),
                proxy_batches=proxy_batches,
                return_code=return_code,
                home_verified=home_verified,
                cleanup_errors=cleanup_errors,
                inventory_error=inventory_error,
                game_exit_gave_up=game_exit_gave_up,
            ),
            retries=connect_retries,
            restarts=offline_retries,
            game_exits=game_exits,
        )
        merge_last_run(finished)
        marks["finished"] = True
        return CANCEL_EXIT_CODE if cancelled else 0 if ok else 1


def main(argv: list[str]) -> int:
    return execute(select_phase(argv), manual_token_from_argv(argv))


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001 — (a) 进程顶层：打一行再以 1 退出
        print(f"MAA 日常失败：{type(exc).__name__}: {exc}", file=sys.stderr)
        raise SystemExit(1)
