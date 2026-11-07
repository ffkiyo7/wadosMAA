#!/usr/bin/env python3
"""上游更新（maa-cli / MaaCore / MaaResource）的**唯一实现**（K17–K20，不变量 #60）。

两个调用方共用这里：

- 07:50 早场计划卡（`maa_plan_card.check_and_update_upstream()`）：只做 Discord 那部分；
- Wado's MAA：`maa_action.py upstream status [--online]` / `upstream update`。

更新期间持有 `run.lock`（持有者 `update`），抢不到就跳过，不和日常、抄作业抢 maa-cli。
分步结果写 `state/maa/upstream.json`（带 `schema_version`），`last_run.json` 的
`resource_update_*` 照旧写，战报和计划卡不用改。

全库只有这个文件会调 `maa update` / `maa hot-update` / `brew upgrade`（有单测守着）。

命令行（worker，由 `maa_action.py upstream update` 脱离会话派发）::

    maa_upstream.py update <source>
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Mapping

from maa_common import (
    BEIJING,
    CONFIG_PATH,
    CONFIG_SCHEMA_VERSION,
    HERMES_HOME,
    MAA_CONFIG_DIR,
    STATE_DIR,
    Config,
    atomic_write_json,
    check_schema,
    load_config,
    load_json,
    lock_holder_text,
    maa_subprocess_env,
    merge_last_run,
    now_beijing,
    run_lock,
    run_lock_holder,
    session_label,
    session_within,
)

UPSTREAM_PATH = STATE_DIR / "upstream.json"
UPSTREAM_SCHEMA_VERSION = 1
DEFAULT_MAA_CLI_FORMULA = "MaaAssistantArknights/tap/maa-cli"
MAA_RESOURCE_REMOTE = "https://github.com/MaaAssistantArknights/MaaResource.git"
MAA_DATA_DIR = Path.home() / "Library" / "Application Support" / "com.loong.maa"
MAA_CACHE_DIR = Path.home() / "Library" / "Caches" / "com.loong.maa"
LIVE_HERMES_HOME = Path.home() / ".hermes"
# K18：「已经更新过」= 本游戏日（北京时间 04:00 换日）成功更新过一次。
GAME_DAY_RESET = timedelta(hours=4)
DEFAULT_BLACKOUT_MINUTES = 30
SOURCE_LABELS = {"plan_card": "07:50 计划卡", "gui": "Wado's MAA", "manual": "终端"}
# `cli.toml` 里必须钉住的几项（spike §5 V10）：值按 TOML 原文比。
PINNED_CLI_TOML = {
    ("core", "channel"): '"Beta"',
    ("resource", "backend"): '"git"',
    ("resource", "auto_update"): "false",
}
_VERSION_RE = re.compile(r"(?im)^(maa-cli|MaaCore|maa)\s+(v?\d+\.\d+\.\d+\S*)")
_TOML_SECTION_RE = re.compile(r"^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$")
_TOML_KEY_RE = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=\s*(.+?)\s*(?:#.*)?$")
_SHA_RE = re.compile(r"^[0-9a-f]{40}$")


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------


def game_day_start(at: datetime | None = None) -> datetime:
    moment = (at or now_beijing()).astimezone(BEIJING)
    start = moment.replace(hour=4, minute=0, second=0, microsecond=0)
    return start if moment >= start else start - timedelta(days=1)


def parse_maa_versions(output: str) -> tuple[str, str]:
    """Return ``(maa-cli version, MaaCore version)`` from ``maa version`` output."""
    cli = ""
    core = ""
    for match in _VERSION_RE.finditer(output or ""):
        version = match.group(2)
        if not version.lower().startswith("v"):
            version = f"v{version}"
        if match.group(1).lower() == "maacore":
            core = version
        else:
            cli = version
    return cli, core


def format_update_summary(result: Mapping[str, Any]) -> str:
    """One Discord field for today's maa-cli / MaaCore check."""
    if result.get("status") == "skipped":
        return str(result.get("summary") or "今天跳过了上游更新")
    if not result.get("ok"):
        detail = str(result.get("detail") or "未知错误").strip()
        first = detail.splitlines()[0] if detail else "未知错误"
        return f"今天检查失败：{first[:300]}"

    def _line(label: str, before: str, after: str) -> tuple[bool, str]:
        before = before or "未知"
        after = after or before
        if before != after:
            return True, f"{label} {before} → {after}"
        return False, f"{label} {after}"

    cli_changed, cli_text = _line(
        "maa-cli", str(result.get("cli_before") or ""), str(result.get("cli_after") or "")
    )
    core_changed, core_text = _line(
        "MaaCore", str(result.get("core_before") or ""), str(result.get("core_after") or "")
    )
    if result.get("changed") or cli_changed or core_changed:
        return f"今天已更新：{cli_text}；{core_text}"
    return f"今天已检查，无新版本（{cli_text} · {core_text}）"


def _combined_output(stdout: str, stderr: str) -> str:
    return "\n".join(part for part in (stdout, stderr) if part)


def _run_captured(
    argv: list[str],
    *,
    env: dict[str, str] | None,
    timeout: int,
) -> tuple[int, str, str]:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
            env=env,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        return 1, "", f"{type(exc).__name__}: {exc}"
    return result.returncode, (result.stdout or "").strip(), (result.stderr or "").strip()


def _brew_env(config: Config, *, auto_update: bool = True) -> dict[str, str]:
    """brew 的环境：带代理、PATH 补全（`maa_subprocess_env`），关掉提示。"""
    env = maa_subprocess_env(config, keep_proxy=True)
    env["HOMEBREW_NO_ENV_HINTS"] = "1"
    if not auto_update:
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    return env


def _brew(env: Mapping[str, str]) -> str | None:
    # GUI 从 Finder 起时 PATH 没有 /opt/homebrew/bin：按补全后的 PATH 找。
    return shutil.which("brew", path=env.get("PATH"))


def _formula(config: Config) -> str:
    return str(config.get("maa_cli_formula", DEFAULT_MAA_CLI_FORMULA)).strip()


def _maa_bin(config: Config) -> str:
    return str(config.get("maa_bin", "/opt/homebrew/bin/maa"))


def is_live_home() -> bool:
    try:
        return HERMES_HOME.resolve() == LIVE_HERMES_HOME.resolve()
    except OSError:
        return False


# ---------------------------------------------------------------------------
# 版本信号（全部离线、只读）
# ---------------------------------------------------------------------------


def read_maa_versions(config: Config) -> tuple[str, str]:
    code, stdout, stderr = _run_captured(
        [_maa_bin(config), "version"],
        env=maa_subprocess_env(config, keep_proxy=True),
        timeout=30,
    )
    if code != 0:
        return "", ""
    return parse_maa_versions(_combined_output(stdout, stderr))


def persist_installed_versions(config: Config, cli_version: str, core_version: str) -> None:
    if not cli_version and not core_version:
        return
    current = check_schema("config.json", load_json(CONFIG_PATH, {}), CONFIG_SCHEMA_VERSION)
    if not isinstance(current, dict):
        current = {}
    if cli_version:
        current["maa_cli_version"] = cli_version
        config["maa_cli_version"] = cli_version
    if core_version:
        current["maa_core_version"] = core_version
        config["maa_core_version"] = core_version
    atomic_write_json(CONFIG_PATH, current)


def resource_head(repo: Path | None = None) -> str:
    """MaaResource 热更新层的 git HEAD。直接读 `.git`，不起子进程。"""
    git_dir = (repo or MAA_DATA_DIR / "MaaResource") / ".git"
    try:
        head = (git_dir / "HEAD").read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    if _SHA_RE.match(head):
        return head
    if not head.startswith("ref: "):
        return ""
    ref = head[5:].strip()
    try:
        value = (git_dir / ref).read_text(encoding="utf-8").strip()
        if _SHA_RE.match(value):
            return value
    except OSError:
        pass
    try:
        packed = (git_dir / "packed-refs").read_text(encoding="utf-8")
    except OSError:
        return ""
    for line in packed.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == ref and _SHA_RE.match(parts[0]):
            return parts[0]
    return ""


def _json_field(path: Path, key: str) -> str:
    data = load_json(path, {})
    return str(data.get(key) or "") if isinstance(data, dict) else ""


def _mtime(path: Path) -> str:
    try:
        return datetime.fromtimestamp(path.stat().st_mtime, BEIJING).isoformat()
    except OSError:
        return ""


def read_cli_toml(path: Path) -> dict[tuple[str, str], str] | None:
    """极简 TOML：只认 `[段]` 和 `键 = 值`（3.9 没有 tomllib，我们也只要三项）。"""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return None
    section = ""
    values: dict[tuple[str, str], str] = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = _TOML_SECTION_RE.match(line)
        if match:
            section = match.group(1)
            continue
        match = _TOML_KEY_RE.match(line)
        if match:
            values[(section, match.group(1))] = match.group(2)
    return values


def pinned_problems(config: Config) -> list[str]:
    """「源被改了」：maa-cli 的 `cli.toml` 不再是仓库钉住的那份（V10）。"""
    path = Path(str(config.get("maa_config_dir", MAA_CONFIG_DIR))) / "cli.toml"
    values = read_cli_toml(path)
    if values is None:
        return [f"找不到 {path}"]
    problems = []
    for (section, key), expected in PINNED_CLI_TOML.items():
        actual = values.get((section, key))
        if actual != expected:
            problems.append(f"cli.toml 的 [{section}] {key} 应为 {expected}，现在是 {actual or '（没写）'}")
    return problems


def load_upstream() -> dict[str, Any]:
    value = check_schema(
        "upstream.json", load_json(UPSTREAM_PATH, {}), UPSTREAM_SCHEMA_VERSION, strict=False
    )
    return value if isinstance(value, dict) else {}


def _write_upstream(record: dict[str, Any]) -> None:
    record["schema_version"] = UPSTREAM_SCHEMA_VERSION
    atomic_write_json(UPSTREAM_PATH, record)


def inconsistency(record: Mapping[str, Any], *, update_running: bool = False) -> str:
    """「不自洽」：上次更新换了 Core 却没让 MaaResource 跟上，或者半路断了（§11.16）。"""
    state = record.get("state")
    if state == "running" and not update_running:
        return "上次上游更新跑到一半就断了（进程被杀或机器睡了），Core 和资源可能对不上"
    if state == "done" and record.get("core_changed") and not record.get("hot_ok"):
        return (
            f"上次上游更新把 MaaCore 换成了 {record.get('core_after') or '新版'}，"
            "MaaResource 却没跟上"
        )
    return ""


def hard_block(config: Config) -> str:
    """开跑前的离线硬拒（spike §6(c) 方案 B）：只认「源被改了」和「不自洽」。"""
    problems = pinned_problems(config)
    if problems:
        return "maa-cli 的更新源被改了：" + "；".join(problems) + "。跑一次 deploy.py 恢复"
    holder = run_lock_holder()
    return inconsistency(
        load_upstream(), update_running=bool(holder and holder.get("holder") == "update")
    )


def update_gate(config: Config, at: datetime | None = None) -> str:
    """GUI / 终端触发更新前的闸门；07:50 计划卡那一趟不走这里。空串 = 放行。"""
    if not is_live_home():
        return (
            f"开发副本（HERMES_HOME={HERMES_HOME}）只检查不更新：maa-cli 的目录全机共用，"
            "副本的 run.lock 挡不住线上"
        )
    minutes = max(
        0, int(config.get("manual_run_blackout_minutes", DEFAULT_BLACKOUT_MINUTES))
    )
    hit = session_within(config, minutes, at or now_beijing()) if minutes else None
    if hit:
        return f"距{session_label(config, hit[0])} 不足 {minutes} 分钟，定时场优先，先别更新"
    return ""


# ---------------------------------------------------------------------------
# 三步更新
# ---------------------------------------------------------------------------


def brew_outdated(config: Config, brew: str, timeout: int) -> tuple[bool | None, str]:
    """`(有没有新版, 说明)`；`None` = 查不出来。

    只看 `--json=v2` 的解析结果，**不看退出码**：点名查一个 formula 时有新版退出码就是 1
    （Homebrew `cmd/outdated.rb`），老代码把它当失败，maa-cli 停在了 0.7.5（K19）。
    """
    code, stdout, stderr = _run_captured(
        [brew, "outdated", "--json=v2", "--formula", _formula(config)],
        env=_brew_env(config, auto_update=True),
        timeout=timeout,
    )
    try:
        parsed = json.loads(stdout)
        formulae = parsed["formulae"]
        if not isinstance(formulae, list):
            raise TypeError("formulae")
    except (ValueError, KeyError, TypeError):
        return None, _combined_output(stdout, stderr) or f"brew outdated 退出码 {code}"
    if not formulae:
        return False, "maa-cli 已是最新"
    item = formulae[0] if isinstance(formulae[0], dict) else {}
    return True, f"maa-cli 有新版 {item.get('current_version') or ''}".strip()


def upgrade_maa_cli(config: Config) -> dict[str, Any]:
    """Upgrade the Homebrew maa-cli formula when a newer bottle exists."""
    timeout = max(30, int(config.get("maa_cli_update_timeout", 180)))
    brew = _brew(_brew_env(config))
    if not brew:
        return {"ok": True, "changed": False, "detail": "未找到 brew，跳过 maa-cli"}
    outdated, note = brew_outdated(config, brew, timeout)
    if outdated is None:
        return {"ok": False, "changed": False, "detail": note}
    if not outdated:
        return {"ok": True, "changed": False, "detail": note}
    code, up_out, up_err = _run_captured(
        [brew, "upgrade", "--formula", _formula(config)],
        env=_brew_env(config, auto_update=False),
        timeout=timeout,
    )
    detail = _combined_output(up_out, up_err) or note
    if code != 0:
        return {"ok": False, "changed": False, "detail": detail or f"brew upgrade 退出码 {code}"}
    return {"ok": True, "changed": True, "detail": detail or f"已升级 {_formula(config)}"}


def _maa_step(config: Config, args: list[str]) -> dict[str, Any]:
    timeout = max(30, int(config.get("resource_update_timeout", 300)))
    code, stdout, stderr = _run_captured(
        [_maa_bin(config), *args],
        env=maa_subprocess_env(config, keep_proxy=True),
        timeout=timeout,
    )
    detail = _combined_output(stdout, stderr)
    if code != 0:
        return {"ok": False, "detail": detail or f"maa {args[0]} 退出码 {code}"}
    return {"ok": True, "detail": detail}


def update_maa_core(config: Config) -> dict[str, Any]:
    """Download a newer Beta MaaCore (and bundled resources) when one exists."""
    return _maa_step(config, ["update", "--batch"])


def update_hot_resources(config: Config) -> dict[str, Any]:
    """Keep the MaaResource overlay compatible with the installed MaaCore."""
    return _maa_step(config, ["hot-update", "--batch"])


def _update_steps(config: Config) -> dict[str, Any]:
    cli_before, core_before = read_maa_versions(config)
    head_before = resource_head()
    cli_step = upgrade_maa_cli(config)
    core_step = update_maa_core(config)
    # The hot-update directory overrides files bundled with MaaCore. Updating
    # only MaaCore can therefore leave an older infrast.json pointing at
    # templates that no longer exist in the new bundle. Do not advance the
    # overlay when the core update itself failed, because the inverse mismatch
    # (new resources on an old core) is unsafe too.
    hot_step = (
        update_hot_resources(config)
        if core_step.get("ok")
        else {"ok": False, "detail": "MaaCore 更新失败，未更新热更新资源"}
    )
    cli_after, core_after = read_maa_versions(config)
    cli_after = cli_after or cli_before
    core_after = core_after or core_before
    persist_installed_versions(config, cli_after, core_after)
    ok = bool(cli_step.get("ok")) and bool(core_step.get("ok")) and bool(hot_step.get("ok"))
    core_changed = bool(core_before) and bool(core_after) and core_before != core_after
    changed = (
        bool(cli_step.get("changed"))
        or (bool(cli_before) and bool(cli_after) and cli_before != cli_after)
        or core_changed
    )
    detail = "\n".join(
        str(part)
        for part in (cli_step.get("detail"), core_step.get("detail"), hot_step.get("detail"))
        if part
    )
    if not ok and not detail:
        detail = "上游更新失败"
    head_after = resource_head()
    return {
        "ok": ok,
        "status": "ok" if ok else "failed",
        "changed": changed,
        "core_changed": core_changed,
        "hot_ok": bool(hot_step.get("ok")),
        "steps": {
            "cli": {key: cli_step.get(key) for key in ("ok", "changed", "detail")},
            "core": {"ok": bool(core_step.get("ok")), "changed": core_changed,
                     "detail": str(core_step.get("detail") or "")[-500:]},
            "hot": {"ok": bool(hot_step.get("ok")),
                    "changed": bool(head_before) and head_before != head_after,
                    "detail": str(hot_step.get("detail") or "")[-500:]},
        },
        "cli_before": cli_before,
        "cli_after": cli_after,
        "core_before": core_before,
        "core_after": core_after,
        "resource_head_before": head_before,
        "resource_head_after": head_after,
        "detail": detail[-1000:],
    }


def run_update(config: Config, source: str, at: datetime | None = None) -> dict[str, Any]:
    """持 `run.lock` 跑完三步，写 `upstream.json` 和 `last_run.json`；不发 Discord。

    抢不到锁就跳过（`status == "skipped"`），不算失败。
    """
    started = at or now_beijing()
    previous = load_upstream()
    base = {
        "source": source,
        "pid": os.getpid(),
        "started_at": started.isoformat(),
        "last_success_at": previous.get("last_success_at") or "",
    }
    with run_lock(blocking=False, holder="update", detail=SOURCE_LABELS.get(source, source)) as acquired:
        if not acquired:
            who = lock_holder_text(run_lock_holder()) or "另一场"
            result: dict[str, Any] = {
                "ok": False,
                "status": "skipped",
                "changed": False,
                "detail": f"跳过：{who}正在用 maa-cli",
                "summary": f"今天跳过了上游更新：{who}正在用 maa-cli",
            }
            # 只记一笔 last_skip：不改 state，免得盖住上一次「不自洽」的记录。
            _write_upstream({**previous, "last_skip": {
                "at": started.isoformat(), "source": source, "detail": result["detail"]}})
            merge_last_run({
                "resource_update_attempted_at": started.isoformat(),
                "resource_update_status": "skipped",
                "resource_update_detail": result["detail"],
                "resource_update_summary": result["summary"],
                "resource_update_changed": False,
            })
            return result
        _write_upstream({**base, "state": "running"})
        result = _update_steps(config)
        finished = now_beijing()
        result["summary"] = format_update_summary(result)
        _write_upstream({
            **base,
            **result,
            "state": "done",
            "finished_at": finished.isoformat(),
            "last_success_at": finished.isoformat() if result["ok"] else base["last_success_at"],
        })
        merge_last_run({
            "resource_update_attempted_at": started.isoformat(),
            "resource_update_status": result["status"],
            "resource_update_detail": result["detail"],
            "resource_update_summary": result["summary"],
            "resource_update_changed": result["changed"],
            "maa_cli_version": result["cli_after"],
            "maa_core_version": result["core_after"],
        })
    return result


# ---------------------------------------------------------------------------
# 状态（Wado's MAA 用）
# ---------------------------------------------------------------------------


def online_signals(config: Config) -> dict[str, Any]:
    """联网查「上游有新版」（V2 / V7'）：带代理，总预算 < 20 秒。只显示，不动手。"""
    result: dict[str, Any] = {"maa_cli_latest": "", "maa_resource_remote_head": "", "errors": []}
    env = _brew_env(config, auto_update=False)
    brew = _brew(env)
    if brew:
        code, stdout, stderr = _run_captured(
            [brew, "info", "--json=v2", _formula(config)], env=env, timeout=8
        )
        try:
            stable = json.loads(stdout)["formulae"][0]["versions"]["stable"]
            result["maa_cli_latest"] = f"v{str(stable).lstrip('v')}"
        except (ValueError, KeyError, IndexError, TypeError):
            result["errors"].append(f"brew info 失败：{_combined_output(stdout, stderr)[-200:] or code}")
    code, stdout, stderr = _run_captured(
        ["git", "ls-remote", MAA_RESOURCE_REMOTE, "refs/heads/main"],
        env=maa_subprocess_env(config, keep_proxy=True),
        timeout=10,
    )
    head = stdout.split()[0] if stdout.split() else ""
    if code == 0 and _SHA_RE.match(head):
        result["maa_resource_remote_head"] = head
    else:
        result["errors"].append(f"git ls-remote 失败：{_combined_output(stdout, stderr)[-200:] or code}")
    return result


def status(config: Config, *, online: bool = False, at: datetime | None = None) -> dict[str, Any]:
    """`upstream status` 的数据：spike §6(b) 的判定 + §5 的信号。默认离线、只读。"""
    now = at or now_beijing()
    record = load_upstream()
    holder = run_lock_holder()
    running = bool(holder and holder.get("holder") == "update")
    start = game_day_start(now)
    try:
        last_success = datetime.fromisoformat(str(record.get("last_success_at") or ""))
    except ValueError:
        last_success = None
    fresh = bool(last_success and last_success >= start)
    problems = pinned_problems(config)
    unsettled = inconsistency(record, update_running=running)
    cli, core = read_maa_versions(config)
    manifest = MAA_CACHE_DIR / "core-manifest-beta.json"
    data: dict[str, Any] = {
        "schema_version": UPSTREAM_SCHEMA_VERSION,
        "checked_at": now.isoformat(),
        "running": running,
        "lock": {
            "held": holder is not None or running,
            "holder": holder or {},
            "text": lock_holder_text(holder),
        },
        "pinned": {"ok": not problems, "problems": problems},
        "consistent": {"ok": not unsettled, "reason": unsettled},
        "fresh": fresh,
        "game_day_start": start.isoformat(),
        "last_success_at": record.get("last_success_at") or "",
        "last": record,
        "versions": {
            "maa_cli": cli,
            "maa_core": core,
            "maa_core_recorded": str(config.get("maa_core_version") or ""),
            "resource_last_updated": _json_field(MAA_DATA_DIR / "resource" / "version.json", "last_updated"),
            "maa_resource_head": resource_head(),
            "beta_core_latest": _json_field(manifest, "version"),
            "beta_core_checked_at": _mtime(manifest),
        },
        "update_blocked": update_gate(config, now) or (
            "上游更新正在跑" if running else ""
        ),
    }
    blocked = (
        "maa-cli 的更新源被改了：" + "；".join(problems) if problems else unsettled
    )
    data["block_reason"] = blocked
    if running:
        data["verdict"] = "running"
    elif blocked:
        data["verdict"] = "blocked"
    elif not fresh:
        data["verdict"] = "stale"
    else:
        data["verdict"] = "ok"
    if online:
        signals = online_signals(config)
        signals["maa_cli_outdated"] = bool(signals["maa_cli_latest"] and cli
                                           and signals["maa_cli_latest"] != cli)
        signals["maa_resource_outdated"] = bool(
            signals["maa_resource_remote_head"]
            and data["versions"]["maa_resource_head"]
            and signals["maa_resource_remote_head"] != data["versions"]["maa_resource_head"]
        )
        data["online"] = signals
    return data


def status_text(data: Mapping[str, Any]) -> str:
    verdict = data.get("verdict")
    versions = data.get("versions") or {}
    tail = f"maa-cli {versions.get('maa_cli') or '未知'} · MaaCore {versions.get('maa_core') or '未知'}"
    if verdict == "running":
        return f"⏳ 上游更新正在跑（{tail}）"
    if verdict == "blocked":
        return f"⛔ {data.get('block_reason')}（{tail}）"
    if verdict == "stale":
        return f"🕓 本游戏日还没成功更新过（{tail}）"
    return f"✅ 上游一致、今天已更新（{tail}）"


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "update" and argv[2] in SOURCE_LABELS:
        config = load_config()
        source = argv[2]
        if source != "plan_card":
            reason = update_gate(config)
            if reason:
                previous = load_upstream()
                _write_upstream({**previous, "last_skip": {
                    "at": now_beijing().isoformat(), "source": source, "detail": reason}})
                print(reason, file=sys.stderr)
                return 1
        result = run_update(config, source)
        print(result.get("summary") or result.get("detail") or "")
        return 0 if result.get("status") != "failed" else 1
    print("用法：maa_upstream.py update <plan_card|gui|manual>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
