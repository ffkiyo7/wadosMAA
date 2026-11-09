#!/usr/bin/env python3
"""`config.json` 里**允许从外面改**的键：白名单 + 逐项校验（K3 / K5）。

`maa_action config get/set/patch` 和 Wado's MAA 的配置页只认这张表；表外的键（路径、
可执行文件、MaaTools 地址、运行时缓存、突袭开关）一律只读。

校验和渲染器共用一份规则（不变量 #44 / #51）：商店物品名走 `maa_common.SAFE_MALL_ITEM_RE`
——渲染器遇到不合规的项是**静默丢弃**（不能让一个坏值拖垮整场日常），这里是**整次拒绝**
（用户当场就能看到哪一项不对）。两边用同一个正则，所以「能存进去的」一定「能渲染出来」。

降级开关（碎石、吃药、助战、忽略练度）不在表里，也不许出现（K11、不变量 #1 / #2 / #15）。
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Mapping

from maa_common import (
    SAFE_MALL_ITEM_RE,
    validate_session_schedule,
)

# 关卡代号（主线 / 资源本）。活动关不进手工表：它们靠上游掉落表自动跟随（不变量 #38）。
TABLE_STAGE_RE = re.compile(r"^[A-Za-z0-9]{1,8}-\d{1,2}$")
DISPLAY_NAME_RE = re.compile(r"^[\w .\-]{0,40}$")
MAX_LIST_ITEMS = 40


@dataclass(frozen=True)
class Field:
    key: str
    group: str
    label: str
    kind: str  # bool / int / float / str_list / weights / stage_table / number_table / text / session_schedule
    default: Any
    minimum: float | None = None
    maximum: float | None = None
    help: str = ""
    extra: Mapping[str, Any] = field(default_factory=dict)

    def describe(self) -> dict[str, Any]:
        item: dict[str, Any] = {
            "key": self.key,
            "group": self.group,
            "label": self.label,
            "kind": self.kind,
            "default": self.default,
        }
        if self.minimum is not None:
            item["min"] = self.minimum
        if self.maximum is not None:
            item["max"] = self.maximum
        if self.help:
            item["help"] = self.help
        return item


def _f(key: str, group: str, label: str, kind: str, default: Any, lo: float | None = None,
       hi: float | None = None, help: str = "") -> Field:
    return Field(key, group, label, kind, default, lo, hi, help)


# 分组即 GUI 的页面（K5）。默认值与种子 `state/config.json` 一致（`SettingsSeedTests` 盯着）。
FIELDS: tuple[Field, ...] = (
    # 场次（K6）：改它要同步 cron，所以只能走 `schedule` 命令，这里只读。
    _f("session_schedule", "场次", "早晚场时间", "session_schedule",
       {"am": {"time": "08:00", "enabled": True}, "pm": {"time": "22:00", "enabled": True}},
       help="用「场次」页改：会同步 Hermes cron"),
    # 日常细项
    _f("medicine_expire_days", "日常", "吃临期理智药的窗口（天）", "int", 2, 0, 7,
       "只吃这么多天内过期的药；0 = 一瓶都不吃"),
    _f("recruit_times", "日常", "公招次数", "int", 4, 0, 4),
    _f("report_drops", "日常", "匿名上报掉落（一图流 / 企鹅物流）", "bool", True),
    _f("award_orundum", "日常", "领幸运墙合成玉", "bool", False),
    _f("award_mining", "日常", "领限时开采许可合成玉", "bool", False),
    _f("award_specialaccess", "日常", "领月卡（周年特权）奖励", "bool", False),
    _f("mall_buy_first", "日常", "信用商店优先买", "str_list", [],
       help="中日文 / 字母 / 数字 / ·，每项不超过 20 字"),
    _f("mall_blacklist", "日常", "信用商店不买", "str_list", []),
    _f("mall_reserve_max_credit", "日常", "信用点低于 300 停止购买", "bool", False),
    _f("mall_only_buy_discount", "日常", "只买打折物品", "bool", False),
    _f("proxy_failure_limit", "日常", "代理指挥连续失误几批熔断", "int", 2, 1, 10),
    _f("proxy_failure_salvage", "日常", "熔断后补跑去掉刷理智的链条", "bool", True),
    _f("annihilation_sanity", "日常", "为每日剿灭预留的理智", "int", 25, 0, 135),
    # 自动定关（材料缺口）
    _f("farming_weights", "自动定关", "稀缺 / 缺口 / 效率 三项权重", "weights",
       {"scarcity": 0.5, "gap": 0.3, "efficiency": 0.2}, help="和为任意值都会归一"),
    _f("farming_min_samples", "自动定关", "掉率最低样本量", "int", 300, 0, 100000),
    _f("farming_target_days", "自动定关", "缺口按多少天用量算", "int", 30, 1, 365),
    _f("farming_activity_edge", "自动定关", "活动关要便宜多少倍才算明显更优", "float", 1.3, 1.0, 10.0),
    _f("farming_rerun_days", "自动定关", "预计复刻间隔（天）", "int", 378, 30, 1000),
    _f("farming_scarcity_horizon_days", "自动定关", "稀缺分视野（天）", "int", 400, 30, 2000),
    _f("farming_stage_table", "自动定关", "材料 → 关卡手工表", "stage_table", {},
       help="只放主线 / 资源本；活动关跟随上游掉落表"),
    _f("farming_manual_weights", "自动定关", "材料手工权重", "number_table", {}),
    # 抄作业
    _f("copilot_blackout_minutes", "抄作业", "早晚场前多久不派发抄作业（分钟）", "int", 25, 0, 180),
    _f("auto_copilot_min_lead_minutes", "抄作业", "距下一场不足多久不再开新的一关（分钟）", "int", 40, 0, 240),
    _f("activity_search_retry_minutes", "抄作业", "练度不满足 / 没作业时的重试间隔（分钟）", "int", 30, 5, 1440),
    _f("auto_copilot_max_attempts_per_day", "抄作业", "同一关每天最多自动尝试几次", "int", 2, 0, 20,
       "0 = 不限"),
    _f("manual_run_blackout_minutes", "抄作业", "早晚场前多久不接受手动场（分钟）", "int", 30, 0, 180),
    # 森空岛
    _f("skland_roster_refresh_days", "森空岛", "练度快照多少天强制刷新", "int", 7, 1, 60),
    # 运行环境
    _f("game_display_name", "运行环境", "游戏窗口常驻的显示器名", "text", "MAA-Game",
       help="系统设置里显示器的名字；留空 = 不挪窗口"),
    _f("game_launch_timeout", "运行环境", "等游戏和 MaaTools 就绪（秒）", "int", 120, 30, 600),
    _f("game_quit_timeout", "运行环境", "等游戏退出（秒）", "int", 30, 5, 120),
    _f("game_probe_timeout", "运行环境", "开跑前探测游戏是否在玩（秒）", "int", 5, 0, 30, "0 = 不探测"),
    _f("maa_run_timeout", "运行环境", "一场日常的上限（秒）", "int", 3000, 600, 3300,
       "Hermes 外层上限 1 小时，要留出清理时间"),
    _f("update_wait_minutes", "运行环境", "日常等上游更新跑完的上限（分钟）", "int", 15, 0, 30,
       "从一场日常的上限里扣"),
    _f("connect_retry_limit", "运行环境", "连接阶段崩溃重开次数", "int", 2, 0, 5),
    _f("offline_retry_limit", "运行环境", "没登录上时重启游戏次数", "int", 2, 0, 5,
       "游戏弹「获取网络配置失败」时等一会儿、重启游戏、整场重跑"),
    _f("retention_days", "运行环境", "本地日志 / 截图保留天数", "int", 14, 1, 90),
    _f("resource_update_timeout", "运行环境", "资源更新超时（秒）", "int", 300, 60, 1800),
    _f("maa_cli_update_timeout", "运行环境", "maa-cli 升级超时（秒）", "int", 180, 60, 1800),
)
BY_KEY: dict[str, Field] = {item.key: item for item in FIELDS}
# 只能经别的命令改的键：`config set` 拒绝，`config get` 照常给。
READ_ONLY_HERE = {"session_schedule": "早晚场时间用 schedule set / enable / disable 改（要同步 cron）"}
GROUPS = tuple(dict.fromkeys(item.group for item in FIELDS))


def _int(spec: Field, value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"{spec.label}要填整数")
    _range(spec, value)
    return value


def _float(spec: Field, value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{spec.label}要填数字")
    _range(spec, float(value))
    return float(value)


def _range(spec: Field, value: float) -> None:
    if spec.minimum is not None and value < spec.minimum:
        raise ValueError(f"{spec.label}不能小于 {spec.minimum:g}")
    if spec.maximum is not None and value > spec.maximum:
        raise ValueError(f"{spec.label}不能大于 {spec.maximum:g}")


def _name(spec: Field, value: Any) -> str:
    if not isinstance(value, str) or not SAFE_MALL_ITEM_RE.match(value):
        raise ValueError(f"{spec.label}里「{str(value)[:20]}」不合规：只能是中日文 / 字母 / 数字 / ·，不超过 20 字")
    return value


def _str_list(spec: Field, value: Any) -> list[str]:
    if not isinstance(value, list) or len(value) > MAX_LIST_ITEMS:
        raise ValueError(f"{spec.label}要是不超过 {MAX_LIST_ITEMS} 项的列表")
    names = [_name(spec, item) for item in value]
    return list(dict.fromkeys(names))


def _weights(spec: Field, value: Any) -> dict[str, float]:
    keys = ("scarcity", "gap", "efficiency")
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError(f"{spec.label}要正好有 scarcity / gap / efficiency 三项")
    result = {}
    for key in keys:
        number = value[key]
        if isinstance(number, bool) or not isinstance(number, (int, float)) or not math.isfinite(number) or number < 0:
            raise ValueError(f"{spec.label}的 {key} 要是不小于 0 的数")
        result[key] = float(number)
    if sum(result.values()) <= 0:
        raise ValueError(f"{spec.label}不能全是 0")
    return result


def _stage_table(spec: Field, value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or len(value) > MAX_LIST_ITEMS:
        raise ValueError(f"{spec.label}要是不超过 {MAX_LIST_ITEMS} 项的表")
    result = {}
    for material, stage in value.items():
        _name(spec, material)
        if not isinstance(stage, str) or not TABLE_STAGE_RE.match(stage):
            raise ValueError(f"{spec.label}里 {material} 的关卡「{str(stage)[:12]}」不是主线 / 资源本代号")
        result[material] = stage
    return result


def _number_table(spec: Field, value: Any) -> dict[str, float]:
    if not isinstance(value, dict) or len(value) > MAX_LIST_ITEMS:
        raise ValueError(f"{spec.label}要是不超过 {MAX_LIST_ITEMS} 项的表")
    result: dict[str, float] = {}
    for material, number in value.items():
        _name(spec, material)
        if isinstance(number, bool) or not isinstance(number, (int, float)) or not 0 <= number <= 1000:
            raise ValueError(f"{spec.label}里 {material} 的权重要在 0–1000 之间")
        result[material] = number
    return result


def _text(spec: Field, value: Any) -> str:
    if not isinstance(value, str) or not DISPLAY_NAME_RE.match(value):
        raise ValueError(f"{spec.label}只能是字母 / 数字 / 空格 / .-_，不超过 40 字")
    return value


def _bool(spec: Field, value: Any) -> bool:
    if not isinstance(value, bool):
        raise ValueError(f"{spec.label}只能是 true / false")
    return value


VALIDATORS: dict[str, Callable[[Field, Any], Any]] = {
    "bool": _bool,
    "int": _int,
    "float": _float,
    "str_list": _str_list,
    "weights": _weights,
    "stage_table": _stage_table,
    "number_table": _number_table,
    "text": _text,
    "session_schedule": lambda _spec, value: validate_session_schedule(value),
}


def validate(key: str, value: Any) -> Any:
    """校验一项，返回规范化后的值；不在白名单 / 不合规抛 `ValueError`（中文原因）。"""
    spec = BY_KEY.get(key)
    if spec is None:
        raise ValueError(f"「{key[:40]}」不能从这里改")
    if key in READ_ONLY_HERE:
        raise ValueError(READ_ONLY_HERE[key])
    return VALIDATORS[spec.kind](spec, value)


def validate_many(updates: Mapping[str, Any]) -> dict[str, Any]:
    """一次改多项：**全部合规才写**，任何一项不行整次拒绝。"""
    if not updates:
        raise ValueError("没有要改的项")
    return {key: validate(key, value) for key, value in updates.items()}


def snapshot(config: Mapping[str, Any]) -> dict[str, Any]:
    """`config get` 的数据：每项的当前值（缺省给默认）、元信息、谁几点改的。"""
    meta = config.get("config_meta")
    meta = meta if isinstance(meta, dict) else {}
    values = {}
    for item in FIELDS:
        values[item.key] = config.get(item.key, item.default)
    return {
        "schema_version": config.get("schema_version", 1),
        "groups": list(GROUPS),
        "fields": [item.describe() for item in FIELDS],
        "values": values,
        "meta": {key: meta[key] for key in meta if key in BY_KEY},
    }
