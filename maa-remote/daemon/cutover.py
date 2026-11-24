#!/usr/bin/env python3
"""Wado's MAA 生产切线与一键回滚脚本（Phase 3 S3-6 / SPEC §3.8）。

职责（严格按 S3-6 执行）：
1. 安全前置检查：
   - 确认 `~/.hermes/state/maa/run.lock`（及 `activity_watch.lock`、`~/.wados-maa/state/maa/run.lock`）空闲；
   - 确认距下一场定时任务（早/晚场计划卡与日常、仓库对表）> 30 分钟；
   - 按规则识别 MAA cron 与按钮，校验数量与 Spec 基线（5 活跃 MAA cron / 17 非 MAA cron / 18 MAA 按钮 / 14 非 MAA 按钮）严格一致，不一致一律拒绝并报告。
2. 全量前置备份至 `~/.wados-maa/backups/cutover-<YYYYMMDDTHHMMSS>/`：
   - `~/.hermes/state/maa/`、`~/.hermes/state/agent-book/buttons.json`、`~/.hermes/cron/jobs.json`、
     `~/.hermes/scripts/maa_*.py`、`~/.hermes/skills/games/maa-operator/`、`RemoteHermesHome` 原值。
3. 单步停旧入口：
   - 持 `cron/.jobs.lock` 暂停 5 条活跃 MAA cron（保留 17 条非 MAA cron 与既有停用项不动）；
   - 停用 Hermes MAA skill（`SKILL.md` → `SKILL.md.disabled`）；
   - 持 `agent-book/state.lock` 原子读改写 `buttons.json`，仅删 18 条 MAA 按钮键（保留 14 条非 MAA 业务键）；
   - 将 `~/.hermes/scripts/maa_*.py` 替换为立即非零退出的拒绝桩。
4. 状态与绝对路径迁移：
   - 复制 `~/.hermes/state/maa/` 至 `~/.wados-maa/state/maa/`；
   - 重写 `runs/index.jsonl` 与 `last_run.json` 中全部 `.hermes/state/maa/` 绝对路径为 `.wados-maa/state/maa/`；
   - 确认 `daemon/daemon.json` 中 `depot_enabled: false`。
5. 切换 Mac GUI 偏好：`defaults write io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome '~/.wados-maa'`。
6. 一键回滚（`--rollback <backup_dir>`）：
   - 核对无持锁 → `launchctl bootout` 停新 LaunchAgent → 还原旧脚本、持 `agent-book/state.lock` 还原 `buttons.json`、
     持 `cron/.jobs.lock` 恢复 5 条 MAA cron、还原 skill 与 `RemoteHermesHome='~/.hermes'` → 保留 `~/.wados-maa` 原样绝不删除。
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Protocol

REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPTS_PATH = REPO_ROOT / "scripts"
if str(SCRIPTS_PATH) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_PATH))

import maa_common  # noqa: E402
import maa_daemon  # noqa: E402

MANIFEST_SCHEMA_VERSION = 1

EXPECTED_ACTIVE_MAA_CRONS = 5
EXPECTED_NON_MAA_CRONS = 17
EXPECTED_MAA_BUTTONS = 18
EXPECTED_NON_MAA_BUTTONS = 14
MIN_SESSION_LEAD_MINUTES = 30

GUI_DEFAULTS_DOMAIN = "io.github.ffkiyo7.MaaRemoteGui"
GUI_DEFAULTS_KEY = "RemoteHermesHome"
TARGET_GUI_HOME_VALUE = "~/.wados-maa"
LEGACY_GUI_HOME_VALUE = "~/.hermes"

LAUNCH_AGENT_LABELS = (
    "io.github.ffkiyo7.wados-maa.daemon",
    "io.github.ffkiyo7.wados-maa.cloudflared",
)

STUB_MARKER = "WADOS_MAA_CUTOVER_STUB"
REFUSAL_STUB_SOURCE = f"""#!/usr/bin/env python3
# {STUB_MARKER}
\"\"\"旧 ~/.hermes/scripts/ MAA 入口已于生产切线停用，请改用 ~/.wados-maa。\"\"\"

import sys

sys.stderr.write(
    "Wado's MAA 已迁移至 ~/.wados-maa，旧 ~/.hermes/scripts/ 入口已停用并拒绝执行。\\n"
)
raise SystemExit(2)
"""

TRANSIENT_LOCK_NAMES = frozenset({"run.lock", "last_run.lock", "activity_watch.lock", "index.lock"})
SESSION_CRON_SCRIPTS = frozenset({"maa_plan_card.py", "maa_daily.py", "maa_depot.py"})


class DefaultsBackend(Protocol):
    def read(self, domain: str, key: str) -> tuple[bool, str | None]: ...
    def write(self, domain: str, key: str, value: str) -> None: ...


class LaunchctlBackend(Protocol):
    def bootout(self, label: str) -> tuple[bool, str]: ...


class SystemDefaultsBackend:
    """调用 macOS `/usr/bin/defaults` 读写 Mac GUI 偏好设置。"""

    def read(self, domain: str, key: str) -> tuple[bool, str | None]:
        proc = subprocess.run(
            ["/usr/bin/defaults", "read", domain, key],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        if proc.returncode != 0:
            return False, None
        return True, proc.stdout.strip()

    def write(self, domain: str, key: str, value: str) -> None:
        proc = subprocess.run(
            ["/usr/bin/defaults", "write", domain, key, value],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "").strip()
            raise RuntimeError(f"defaults write 失败（rc={proc.returncode}）：{detail}")


class SystemLaunchctlBackend:
    """调用 macOS `/bin/launchctl bootout` 停用用户级 LaunchAgent。"""

    def bootout(self, label: str) -> tuple[bool, str]:
        target = f"gui/{os.getuid()}/{label}"
        proc = subprocess.run(
            ["/bin/launchctl", "bootout", target],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        output = (proc.stderr or proc.stdout or "").strip()
        # rc=3 (No such process) 或 rc=113 (Could not find specified service) 视为已停止
        if proc.returncode in (0, 3, 113):
            return True, output or ("stopped" if proc.returncode == 0 else "not_loaded")
        return False, f"rc={proc.returncode} {output}".strip()


@dataclasses.dataclass
class CutoverPaths:
    home: Path
    hermes_home: Path
    wados_home: Path

    @classmethod
    def from_home(cls, home: Path) -> CutoverPaths:
        resolved = home.expanduser().resolve()
        return cls(
            home=resolved,
            hermes_home=resolved / ".hermes",
            wados_home=resolved / ".wados-maa",
        )

    @property
    def hermes_state_maa(self) -> Path:
        return self.hermes_home / "state" / "maa"

    @property
    def hermes_run_lock(self) -> Path:
        return self.hermes_state_maa / "run.lock"

    @property
    def hermes_watch_lock(self) -> Path:
        return self.hermes_state_maa / "activity_watch.lock"

    @property
    def hermes_buttons(self) -> Path:
        return self.hermes_home / "state" / "agent-book" / "buttons.json"

    @property
    def hermes_agent_book_lock(self) -> Path:
        return self.hermes_home / "state" / "agent-book" / "state.lock"

    @property
    def hermes_cron_jobs(self) -> Path:
        return self.hermes_home / "cron" / "jobs.json"

    @property
    def hermes_cron_lock(self) -> Path:
        return self.hermes_home / "cron" / ".jobs.lock"

    @property
    def hermes_scripts(self) -> Path:
        return self.hermes_home / "scripts"

    @property
    def hermes_skill_dir(self) -> Path:
        return self.hermes_home / "skills" / "games" / "maa-operator"

    @property
    def wados_state_maa(self) -> Path:
        return self.wados_home / "state" / "maa"

    @property
    def wados_run_lock(self) -> Path:
        return self.wados_state_maa / "run.lock"

    @property
    def wados_daemon_config(self) -> Path:
        return self.wados_home / "daemon" / "daemon.json"

    @property
    def wados_backups(self) -> Path:
        return self.wados_home / "backups"


# ---------------------------------------------------------------------------
# 识别规则与锁/前置检查
# ---------------------------------------------------------------------------


def is_maa_cron(job: Mapping[str, Any]) -> bool:
    """按规则识别 Hermes cron 是否属于 MAA。"""
    script_name = Path(str(job.get("script") or "")).name.lower()
    if script_name.startswith("maa_"):
        return True
    workdir = str(job.get("workdir") or "").replace("\\", "/")
    if "/state/maa" in workdir or workdir.endswith("/state/maa"):
        return True
    name = str(job.get("name") or "").strip()
    return name == "MAA" or name.startswith("MAA ")


def is_maa_button(key: str, entry: Any) -> bool:
    """按规则识别 `buttons.json` 键是否属于 MAA。"""
    if key.startswith(("hermes:btn:maa:", "hermes:btn:maa-")):
        return True
    if isinstance(entry, Mapping):
        script_name = Path(str(entry.get("script") or "")).name.lower()
        if script_name.startswith("maa_"):
            return True
    return False


def classify_crons(jobs: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """返回 `(活跃 MAA cron, 已停用 MAA cron, 非 MAA cron)`。"""
    active_maa: list[dict[str, Any]] = []
    inactive_maa: list[dict[str, Any]] = []
    non_maa: list[dict[str, Any]] = []
    for job in jobs:
        if is_maa_cron(job):
            if bool(job.get("enabled")):
                active_maa.append(job)
            else:
                inactive_maa.append(job)
        else:
            non_maa.append(job)
    return active_maa, inactive_maa, non_maa


def classify_buttons(buttons: Mapping[str, Any]) -> tuple[list[str], list[str]]:
    """返回 `(MAA 按钮键列表, 非 MAA 按钮键列表)`（均排序）。"""
    maa_keys: list[str] = []
    non_maa_keys: list[str] = []
    for key in sorted(buttons.keys()):
        if is_maa_button(key, buttons[key]):
            maa_keys.append(key)
        else:
            non_maa_keys.append(key)
    return maa_keys, non_maa_keys


@contextlib.contextmanager
def _exclusive_file_lock(lock_path: Path) -> Iterator[None]:
    """阻塞持有指定 flock 锁文件，用于原子读改写共享文件。"""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def probe_flock(lock_path: Path) -> tuple[bool, dict[str, Any] | None]:
    """非阻塞探测锁文件是否被占用，返回 `(is_locked, holder_info)`。"""
    if not lock_path.exists():
        return False, None
    with lock_path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder: dict[str, Any] | None = None
            try:
                raw = lock_path.read_text(encoding="utf-8").strip()
                parsed = json.loads(raw) if raw else None
                if isinstance(parsed, dict):
                    holder = parsed
            except (OSError, ValueError):
                pass
            return True, holder
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return False, None


def _parse_iso_dt(raw: Any) -> datetime | None:
    text = str(raw or "").strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt


def find_next_session(
    *,
    now: datetime,
    config: Mapping[str, Any],
    active_maa_crons: list[dict[str, Any]],
) -> dict[str, Any] | None:
    """找出距离 `now` 最近的下一场定时任务（早/晚计划卡与日常及活跃非高频 MAA cron）。"""
    moment = now.astimezone(maa_common.BEIJING)
    candidates: list[tuple[datetime, str]] = []

    # 1. 基于 config.json 的 session_schedule 计算早/晚场计划卡与日常下次时刻
    schedule = maa_common.session_schedule(config)
    for phase in ("am", "pm"):
        slot = schedule[phase]
        if not slot.get("enabled"):
            continue
        hour_s, minute_s = str(slot["time"]).split(":")
        daily_dt = moment.replace(hour=int(hour_s), minute=int(minute_s), second=0, microsecond=0)
        if daily_dt < moment:
            daily_dt += timedelta(days=1)
        candidates.append((daily_dt, f"daily_{phase}"))

        plan_dt = moment.replace(hour=int(hour_s), minute=int(minute_s), second=0, microsecond=0) - timedelta(
            minutes=maa_common.PLAN_CARD_LEAD_MINUTES
        )
        if plan_dt < moment:
            plan_dt += timedelta(days=1)
        candidates.append((plan_dt, f"plan_card_{phase}"))

    # 2. 基于 jobs.json 中活跃的非高频 MAA cron（plan_card/daily/depot）的 next_run_at
    for job in active_maa_crons:
        script_name = Path(str(job.get("script") or "")).name.lower()
        if script_name not in SESSION_CRON_SCRIPTS:
            continue
        nxt = _parse_iso_dt(job.get("next_run_at"))
        if nxt is None:
            continue
        nxt_bj = nxt.astimezone(maa_common.BEIJING)
        if nxt_bj >= moment:
            label = str(job.get("name") or job.get("id") or script_name)
            candidates.append((nxt_bj, f"cron:{label}"))

    if not candidates:
        return None
    earliest_dt, earliest_label = min(candidates, key=lambda item: item[0])
    minutes_until = (earliest_dt - moment).total_seconds() / 60.0
    return {
        "label": earliest_label,
        "at": earliest_dt.isoformat(),
        "minutes_until": round(minutes_until, 2),
    }


# ---------------------------------------------------------------------------
# 路径改写与文件拷贝辅助
# ---------------------------------------------------------------------------


def _rewrite_path_string(text: str, hermes_state: Path, wados_state: Path) -> tuple[str, int]:
    """将字符串中的 `.hermes/state/maa` 替换为 `.wados-maa/state/maa`，返回 `(新串, 替换次数)`。"""
    count = 0
    old_abs = str(hermes_state)
    new_abs = str(wados_state)
    if old_abs in text:
        count += text.count(old_abs)
        text = text.replace(old_abs, new_abs)
    if ".hermes/state/maa/" in text:
        count += text.count(".hermes/state/maa/")
        text = text.replace(".hermes/state/maa/", ".wados-maa/state/maa/")
    elif text.endswith(".hermes/state/maa"):
        count += 1
        text = text[: -len(".hermes/state/maa")] + ".wados-maa/state/maa"
    return text, count


def _rewrite_json_paths(obj: Any, hermes_state: Path, wados_state: Path) -> tuple[Any, int]:
    if isinstance(obj, str):
        return _rewrite_path_string(obj, hermes_state, wados_state)
    if isinstance(obj, list):
        total = 0
        out_list: list[Any] = []
        for item in obj:
            new_item, c = _rewrite_json_paths(item, hermes_state, wados_state)
            total += c
            out_list.append(new_item)
        return out_list, total
    if isinstance(obj, dict):
        total = 0
        out_dict: dict[str, Any] = {}
        for k, v in obj.items():
            new_v, c = _rewrite_json_paths(v, hermes_state, wados_state)
            total += c
            out_dict[k] = new_v
        return out_dict, total
    return obj, 0


def rewrite_migrated_state_paths(hermes_state: Path, wados_state: Path) -> dict[str, int]:
    """重写迁移后 `runs/index.jsonl` 与 `last_run.json` 中的 `.hermes/state/maa/` 绝对路径。"""
    stats = {"index_lines_rewritten": 0, "index_replacements": 0, "last_run_replacements": 0}

    index_path = wados_state / "runs" / "index.jsonl"
    if index_path.is_file():
        raw_lines = index_path.read_text(encoding="utf-8").splitlines()
        out_lines: list[str] = []
        for line in raw_lines:
            if not line.strip():
                out_lines.append(line)
                continue
            try:
                parsed = json.loads(line)
            except json.JSONDecodeError:
                new_line, count = _rewrite_path_string(line, hermes_state, wados_state)
                if count > 0:
                    stats["index_lines_rewritten"] += 1
                    stats["index_replacements"] += count
                out_lines.append(new_line)
                continue
            rewritten, count = _rewrite_json_paths(parsed, hermes_state, wados_state)
            if count > 0:
                stats["index_lines_rewritten"] += 1
                stats["index_replacements"] += count
                out_lines.append(json.dumps(rewritten, ensure_ascii=False, separators=(",", ":")))
            else:
                out_lines.append(line)
        maa_common.atomic_write_text(index_path, "\n".join(out_lines) + ("\n" if out_lines else ""), mode=0o600)

    last_run_path = wados_state / "last_run.json"
    if last_run_path.is_file():
        raw_doc = maa_common.load_json(last_run_path, None)
        if isinstance(raw_doc, dict):
            rewritten_doc, count = _rewrite_json_paths(raw_doc, hermes_state, wados_state)
            stats["last_run_replacements"] = count
            if count > 0:
                maa_common.atomic_write_json(last_run_path, rewritten_doc)

    return stats


def _copy_state_tree(src: Path, dst: Path) -> int:
    """复制 `state/maa` 目录树（跳过瞬态 `.lock` 文件，保留文件权限），返回复制的文件数。"""
    copied = 0
    if not src.is_dir():
        return 0
    dst.mkdir(parents=True, exist_ok=True)
    for root, dirs, files in os.walk(src):
        rel_root = Path(root).relative_to(src)
        target_dir = dst / rel_root
        target_dir.mkdir(parents=True, exist_ok=True)
        for d in dirs:
            (target_dir / d).mkdir(parents=True, exist_ok=True)
        for filename in files:
            if filename in TRANSIENT_LOCK_NAMES:
                continue
            src_file = Path(root) / filename
            if not src_file.is_file():
                continue
            dst_file = target_dir / filename
            shutil.copy2(src_file, dst_file)
            copied += 1
    return copied


def _load_jobs_doc(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    if not path.is_file():
        raise FileNotFoundError(f"找不到 Hermes cron 文件：{path}")
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), list):
        raise ValueError(f"jobs.json 格式异常（缺少 jobs 列表）：{path}")
    jobs = [j for j in doc["jobs"] if isinstance(j, dict)]
    if len(jobs) != len(doc["jobs"]):
        raise ValueError(f"jobs.json 包含非对象条目：{path}")
    return doc, jobs


def _load_buttons_doc(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise FileNotFoundError(f"找不到按钮登记表：{path}")
    doc = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise ValueError(f"buttons.json 格式异常（必须为 JSON 对象）：{path}")
    return doc


# ---------------------------------------------------------------------------
# 巡检、切线与回滚核心流程
# ---------------------------------------------------------------------------


def inspect_cutover(
    paths: CutoverPaths,
    *,
    now: datetime | None = None,
    defaults: DefaultsBackend | None = None,
    min_lead_minutes: int = MIN_SESSION_LEAD_MINUTES,
) -> dict[str, Any]:
    """只读巡检全部前置条件与改动清单（供 `--dry-run` 与正式切线共用）。"""
    moment = (now or maa_common.now_beijing()).astimezone(maa_common.BEIJING)
    defaults_be = defaults or SystemDefaultsBackend()
    errors: list[str] = []

    # 1. 锁检查
    hermes_locked, hermes_holder = probe_flock(paths.hermes_run_lock)
    if hermes_locked:
        errors.append(f"旧目录 run.lock 正被占用（{hermes_holder or '未知持有者'}），拒绝切线。")
    watch_locked, _ = probe_flock(paths.hermes_watch_lock)
    if watch_locked:
        errors.append("旧目录 activity_watch.lock 正被占用，拒绝切线。")
    wados_locked, wados_holder = probe_flock(paths.wados_run_lock)
    if wados_locked:
        errors.append(f"新目录 run.lock 正被占用（{wados_holder or '未知持有者'}），拒绝切线。")

    # 2. 识别 MAA cron 并严格校验 5 / 17
    active_maa: list[dict[str, Any]] = []
    inactive_maa: list[dict[str, Any]] = []
    non_maa: list[dict[str, Any]] = []
    try:
        _jobs_doc, jobs = _load_jobs_doc(paths.hermes_cron_jobs)
        active_maa, inactive_maa, non_maa = classify_crons(jobs)
        if len(active_maa) != EXPECTED_ACTIVE_MAA_CRONS or len(non_maa) != EXPECTED_NON_MAA_CRONS:
            errors.append(
                f"cron 数量与 Spec 不一致：活跃 MAA cron 预期 {EXPECTED_ACTIVE_MAA_CRONS} 实际 {len(active_maa)}，"
                f"非 MAA cron 预期 {EXPECTED_NON_MAA_CRONS} 实际 {len(non_maa)}"
                f"（另有已停用 MAA cron {len(inactive_maa)} 条）。"
            )
    except (OSError, ValueError) as exc:
        errors.append(f"无法读取 Hermes cron：{exc}")

    # 3. 识别 MAA 按钮并严格校验 18 / 14
    maa_buttons: list[str] = []
    non_maa_buttons: list[str] = []
    try:
        buttons_doc = _load_buttons_doc(paths.hermes_buttons)
        maa_buttons, non_maa_buttons = classify_buttons(buttons_doc)
        if len(maa_buttons) != EXPECTED_MAA_BUTTONS or len(non_maa_buttons) != EXPECTED_NON_MAA_BUTTONS:
            errors.append(
                f"按钮数量与 Spec 不一致：MAA 按钮预期 {EXPECTED_MAA_BUTTONS} 实际 {len(maa_buttons)}，"
                f"非 MAA 按钮预期 {EXPECTED_NON_MAA_BUTTONS} 实际 {len(non_maa_buttons)}。"
            )
    except (OSError, ValueError) as exc:
        errors.append(f"无法读取 buttons.json：{exc}")

    # 4. 距下一场定时任务 > 30 分钟检查
    cfg_raw = maa_common.load_json(paths.hermes_state_maa / "config.json", {})
    cfg = cfg_raw if isinstance(cfg_raw, dict) else {}
    next_session = find_next_session(now=moment, config=cfg, active_maa_crons=active_maa)
    if next_session is not None and float(next_session["minutes_until"]) <= float(min_lead_minutes):
        errors.append(
            f"距下一场定时任务（{next_session['label']} @ {next_session['at']}）仅剩 "
            f"{next_session['minutes_until']} 分钟，不满足 > {min_lead_minutes} 分钟安全窗口。"
        )

    # 5. 待置桩脚本与待停用 skill
    scripts_to_stub = (
        sorted(p.name for p in paths.hermes_scripts.glob("maa_*.py") if p.is_file())
        if paths.hermes_scripts.is_dir()
        else []
    )
    if not scripts_to_stub:
        errors.append(f"未在 {paths.hermes_scripts} 找到任何 maa_*.py 脚本。")

    skill_md = paths.hermes_skill_dir / "SKILL.md"
    skill_present = skill_md.is_file()

    # 6. 统计待改写路径数量（只读预估）
    index_hits = 0
    index_path = paths.hermes_state_maa / "runs" / "index.jsonl"
    if index_path.is_file():
        for line in index_path.read_text(encoding="utf-8").splitlines():
            _new, c = _rewrite_path_string(line, paths.hermes_state_maa, paths.wados_state_maa)
            index_hits += c
    last_run_hits = 0
    lr_raw = maa_common.load_json(paths.hermes_state_maa / "last_run.json", None)
    if isinstance(lr_raw, dict):
        _new_lr, last_run_hits = _rewrite_json_paths(lr_raw, paths.hermes_state_maa, paths.wados_state_maa)

    # 7. Mac GUI 偏好当前值
    gui_exists, gui_current = defaults_be.read(GUI_DEFAULTS_DOMAIN, GUI_DEFAULTS_KEY)

    return {
        "ok": not errors,
        "errors": errors,
        "checked_at": moment.isoformat(),
        "hermes_home": str(paths.hermes_home),
        "wados_home": str(paths.wados_home),
        "locks": {
            "hermes_run_locked": hermes_locked,
            "hermes_watch_locked": watch_locked,
            "wados_run_locked": wados_locked,
        },
        "next_session": next_session,
        "counts": {
            "active_maa_crons": len(active_maa),
            "inactive_maa_crons": len(inactive_maa),
            "non_maa_crons": len(non_maa),
            "maa_buttons": len(maa_buttons),
            "non_maa_buttons": len(non_maa_buttons),
            "expected": {
                "active_maa_crons": EXPECTED_ACTIVE_MAA_CRONS,
                "non_maa_crons": EXPECTED_NON_MAA_CRONS,
                "maa_buttons": EXPECTED_MAA_BUTTONS,
                "non_maa_buttons": EXPECTED_NON_MAA_BUTTONS,
            },
        },
        "plan": {
            "crons_to_pause": [
                {"id": j.get("id"), "name": j.get("name"), "script": j.get("script")}
                for j in active_maa
            ],
            "inactive_maa_crons_untouched": [
                {"id": j.get("id"), "name": j.get("name"), "state": j.get("state")}
                for j in inactive_maa
            ],
            "non_maa_crons_preserved": [
                {"id": j.get("id"), "name": j.get("name")}
                for j in non_maa
            ],
            "buttons_to_remove": maa_buttons,
            "buttons_preserved": non_maa_buttons,
            "scripts_to_stub": scripts_to_stub,
            "skill_to_disable": str(skill_md) if skill_present else None,
            "path_rewrites_estimated": {
                "index_jsonl": index_hits,
                "last_run_json": last_run_hits,
            },
            "daemon_depot_enabled_target": False,
            "gui_defaults": {
                "domain": GUI_DEFAULTS_DOMAIN,
                "key": GUI_DEFAULTS_KEY,
                "before": gui_current if gui_exists else None,
                "after": TARGET_GUI_HOME_VALUE,
            },
        },
    }


def _allocate_backup_dir(backups_root: Path, moment: datetime) -> Path:
    maa_common.ensure_private_dir(backups_root)
    base = f"cutover-{moment.strftime('%Y%m%dT%H%M%S')}"
    candidate = backups_root / base
    seq = 1
    while candidate.exists():
        candidate = backups_root / f"{base}-{seq}"
        seq += 1
    maa_common.ensure_private_dir(candidate)
    return candidate


def run_cutover(
    paths: CutoverPaths,
    *,
    dry_run: bool = False,
    now: datetime | None = None,
    defaults: DefaultsBackend | None = None,
    min_lead_minutes: int = MIN_SESSION_LEAD_MINUTES,
) -> dict[str, Any]:
    """执行（或 dry-run 演练）S3-6 生产切线流程。"""
    moment = (now or maa_common.now_beijing()).astimezone(maa_common.BEIJING)
    defaults_be = defaults or SystemDefaultsBackend()

    report = inspect_cutover(
        paths,
        now=moment,
        defaults=defaults_be,
        min_lead_minutes=min_lead_minutes,
    )
    report["dry_run"] = dry_run
    if dry_run or not report["ok"]:
        return report

    # Step 2: 全量前置备份
    backup_dir = _allocate_backup_dir(paths.wados_backups, moment)
    state_files_backed_up = _copy_state_tree(paths.hermes_state_maa, backup_dir / "state_maa")

    with _exclusive_file_lock(paths.hermes_agent_book_lock):
        buttons_backup_bytes = paths.hermes_buttons.read_bytes()
    maa_common.atomic_write_text(
        backup_dir / "buttons.json",
        buttons_backup_bytes.decode("utf-8"),
        mode=0o600,
    )

    with _exclusive_file_lock(paths.hermes_cron_lock):
        jobs_backup_bytes = paths.hermes_cron_jobs.read_bytes()
    maa_common.atomic_write_text(
        backup_dir / "jobs.json",
        jobs_backup_bytes.decode("utf-8"),
        mode=0o600,
    )

    backup_scripts_dir = backup_dir / "scripts"
    maa_common.ensure_private_dir(backup_scripts_dir)
    stubbed_scripts: list[str] = list(report["plan"]["scripts_to_stub"])
    for name in stubbed_scripts:
        shutil.copy2(paths.hermes_scripts / name, backup_scripts_dir / name)

    skill_md = paths.hermes_skill_dir / "SKILL.md"
    skill_disabled = False
    if skill_md.is_file():
        backup_skill_dir = backup_dir / "skills" / "maa-operator"
        maa_common.ensure_private_dir(backup_skill_dir)
        shutil.copy2(skill_md, backup_skill_dir / "SKILL.md")

    gui_exists, gui_before = defaults_be.read(GUI_DEFAULTS_DOMAIN, GUI_DEFAULTS_KEY)
    paused_cron_ids = [str(item["id"]) for item in report["plan"]["crons_to_pause"]]
    removed_button_keys = list(report["plan"]["buttons_to_remove"])

    # Step 3a: 持 cron/.jobs.lock 暂停 5 条活跃 MAA cron（17 条非 MAA cron 完整不动）
    paused_at_utc = moment.astimezone(timezone.utc).isoformat()
    with _exclusive_file_lock(paths.hermes_cron_lock):
        jobs_doc, jobs = _load_jobs_doc(paths.hermes_cron_jobs)
        cur_active, _cur_inactive, cur_non = classify_crons(jobs)
        if len(cur_active) != EXPECTED_ACTIVE_MAA_CRONS or len(cur_non) != EXPECTED_NON_MAA_CRONS:
            raise RuntimeError(
                f"加锁后 cron 数量发生变化：活跃 MAA={len(cur_active)}，非 MAA={len(cur_non)}"
            )
        target_ids = set(paused_cron_ids)
        for job in jobs_doc["jobs"]:
            if str(job.get("id") or "") in target_ids:
                job["enabled"] = False
                job["state"] = "paused"
                job["paused_at"] = paused_at_utc
                job["paused_reason"] = "migrated_to_wados_maa"
        if "updated_at" in jobs_doc:
            jobs_doc["updated_at"] = paused_at_utc
        maa_common.atomic_write_json(paths.hermes_cron_jobs, jobs_doc)

    # Step 3b: 停用 Hermes MAA skill
    if skill_md.is_file():
        os.replace(skill_md, paths.hermes_skill_dir / "SKILL.md.disabled")
        skill_disabled = True

    # Step 3c: 持 agent-book/state.lock 原子删除 18 条 MAA 按钮（14 条非 MAA 按钮完整不动）
    with _exclusive_file_lock(paths.hermes_agent_book_lock):
        buttons_doc = _load_buttons_doc(paths.hermes_buttons)
        cur_maa_btns, cur_non_btns = classify_buttons(buttons_doc)
        if len(cur_maa_btns) != EXPECTED_MAA_BUTTONS or len(cur_non_btns) != EXPECTED_NON_MAA_BUTTONS:
            raise RuntimeError(
                f"加锁后按钮数量发生变化：MAA={len(cur_maa_btns)}，非 MAA={len(cur_non_btns)}"
            )
        for key in removed_button_keys:
            buttons_doc.pop(key, None)
        maa_common.atomic_write_json(paths.hermes_buttons, buttons_doc)

    # Step 3d: 替换 ~/.hermes/scripts/maa_*.py 为拒绝桩
    for name in stubbed_scripts:
        target_script = paths.hermes_scripts / name
        maa_common.atomic_write_text(target_script, REFUSAL_STUB_SOURCE, mode=0o755)

    # Step 4: 复制 state/maa 并重写绝对路径，确认 depot_enabled: false
    migrated_files = _copy_state_tree(paths.hermes_state_maa, paths.wados_state_maa)
    rewrite_stats = rewrite_migrated_state_paths(paths.hermes_state_maa, paths.wados_state_maa)

    maa_common.ensure_private_dir(paths.wados_daemon_config.parent)
    daemon_cfg = maa_daemon.load_daemon_config(paths.wados_daemon_config)
    daemon_cfg["depot_enabled"] = False
    maa_common.atomic_write_json(paths.wados_daemon_config, daemon_cfg)
    os.chmod(paths.wados_daemon_config, 0o600)

    # Step 5: 切换 Mac GUI 偏好
    defaults_be.write(GUI_DEFAULTS_DOMAIN, GUI_DEFAULTS_KEY, TARGET_GUI_HOME_VALUE)

    # 写入备份清单 manifest.json（供 --rollback 精确还原）
    manifest: dict[str, Any] = {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "created_at": moment.isoformat(),
        "hermes_home": str(paths.hermes_home),
        "wados_home": str(paths.wados_home),
        "paused_cron_ids": paused_cron_ids,
        "removed_button_keys": removed_button_keys,
        "preserved_button_keys": list(report["plan"]["buttons_preserved"]),
        "stubbed_scripts": stubbed_scripts,
        "skill_disabled": skill_disabled,
        "state_files_backed_up": state_files_backed_up,
        "remote_hermes_home_before": {
            "exists": gui_exists,
            "value": gui_before,
        },
    }
    maa_common.atomic_write_json(backup_dir / "manifest.json", manifest)

    report["executed"] = True
    report["backup_dir"] = str(backup_dir)
    report["migrated_files"] = migrated_files
    report["path_rewrites"] = rewrite_stats
    report["skill_disabled"] = skill_disabled
    return report


def run_rollback(
    paths: CutoverPaths,
    backup_dir: Path,
    *,
    now: datetime | None = None,
    defaults: DefaultsBackend | None = None,
    launchctl: LaunchctlBackend | None = None,
) -> dict[str, Any]:
    """一键回滚（S3-6 步骤 6）：停新 LaunchAgent → 还原旧入口 → 保留 ~/.wados-maa 原样。"""
    moment = (now or maa_common.now_beijing()).astimezone(maa_common.BEIJING)
    defaults_be = defaults or SystemDefaultsBackend()
    launchctl_be = launchctl or SystemLaunchctlBackend()
    resolved_backup = backup_dir.expanduser().resolve()
    errors: list[str] = []

    manifest_path = resolved_backup / "manifest.json"
    if not manifest_path.is_file():
        return {
            "ok": False,
            "errors": [f"备份目录无效，缺少 manifest.json：{resolved_backup}"],
            "backup_dir": str(resolved_backup),
        }

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        return {
            "ok": False,
            "errors": [f"manifest.json 格式无效：{manifest_path}"],
            "backup_dir": str(resolved_backup),
        }

    # 1. 核对无持锁
    wados_locked, wados_holder = probe_flock(paths.wados_run_lock)
    if wados_locked:
        errors.append(f"新目录 run.lock 正被占用（{wados_holder or '未知持有者'}），拒绝回滚。")
    hermes_locked, hermes_holder = probe_flock(paths.hermes_run_lock)
    if hermes_locked:
        errors.append(f"旧目录 run.lock 正被占用（{hermes_holder or '未知持有者'}），拒绝回滚。")
    if errors:
        return {"ok": False, "errors": errors, "backup_dir": str(resolved_backup)}

    # 校验必需备份产物齐备
    for req in (resolved_backup / "jobs.json", resolved_backup / "buttons.json", resolved_backup / "scripts"):
        if not req.exists():
            errors.append(f"备份不完整，缺少：{req}")
    if errors:
        return {"ok": False, "errors": errors, "backup_dir": str(resolved_backup)}

    # 2. 停止新 LaunchAgent（daemon + cloudflared）
    bootout_results: dict[str, dict[str, Any]] = {}
    for label in LAUNCH_AGENT_LABELS:
        ok, detail = launchctl_be.bootout(label)
        bootout_results[label] = {"ok": ok, "detail": detail}
        if not ok:
            errors.append(f"停用 LaunchAgent 失败（{label}）：{detail}")
    if errors:
        return {
            "ok": False,
            "errors": errors,
            "bootout": bootout_results,
            "backup_dir": str(resolved_backup),
        }

    # 再次核对无持锁
    wados_locked_after, wados_holder_after = probe_flock(paths.wados_run_lock)
    if wados_locked_after:
        return {
            "ok": False,
            "errors": [f"停用守护进程后新目录 run.lock 仍被占用（{wados_holder_after or '未知持有者'}），拒绝回滚。"],
            "bootout": bootout_results,
            "backup_dir": str(resolved_backup),
        }

    # 3. 还原旧脚本 ~/.hermes/scripts/maa_*.py
    backup_scripts_dir = resolved_backup / "scripts"
    restored_scripts: list[str] = []
    paths.hermes_scripts.mkdir(parents=True, exist_ok=True)
    for src_script in sorted(backup_scripts_dir.glob("maa_*.py")):
        if not src_script.is_file():
            continue
        dst_script = paths.hermes_scripts / src_script.name
        mode = src_script.stat().st_mode & 0o777
        maa_common.atomic_write_text(
            dst_script,
            src_script.read_text(encoding="utf-8"),
            mode=mode or 0o755,
        )
        restored_scripts.append(src_script.name)

    # 4. 持 agent-book/state.lock 还原 buttons.json（合并还原被删 MAA 键，保护切线后非 MAA 键更新）
    backup_buttons = _load_buttons_doc(resolved_backup / "buttons.json")
    removed_keys = [str(k) for k in (manifest.get("removed_button_keys") or [])]
    restored_buttons: list[str] = []
    with _exclusive_file_lock(paths.hermes_agent_book_lock):
        if paths.hermes_buttons.is_file():
            current_buttons = _load_buttons_doc(paths.hermes_buttons)
        else:
            current_buttons = {}
        keys_to_restore = removed_keys or [k for k, v in backup_buttons.items() if is_maa_button(k, v)]
        for key in keys_to_restore:
            if key in backup_buttons:
                current_buttons[key] = backup_buttons[key]
                restored_buttons.append(key)
        maa_common.atomic_write_json(paths.hermes_buttons, current_buttons)

    # 5. 持 cron/.jobs.lock 还原 5 条 MAA cron（保留 17 条非 MAA cron 当前态）
    _backup_jobs_doc, backup_jobs = _load_jobs_doc(resolved_backup / "jobs.json")
    backup_jobs_by_id = {str(j.get("id") or ""): j for j in backup_jobs}
    paused_ids = [str(cid) for cid in (manifest.get("paused_cron_ids") or [])]
    restored_crons: list[str] = []
    with _exclusive_file_lock(paths.hermes_cron_lock):
        current_jobs_doc, _current_jobs = _load_jobs_doc(paths.hermes_cron_jobs)
        for idx, job in enumerate(current_jobs_doc["jobs"]):
            jid = str(job.get("id") or "")
            if jid in paused_ids and jid in backup_jobs_by_id:
                current_jobs_doc["jobs"][idx] = dict(backup_jobs_by_id[jid])
                restored_crons.append(jid)
        if "updated_at" in current_jobs_doc:
            current_jobs_doc["updated_at"] = moment.astimezone(timezone.utc).isoformat()
        maa_common.atomic_write_json(paths.hermes_cron_jobs, current_jobs_doc)

    # 6. 还原 Hermes MAA skill
    skill_md = paths.hermes_skill_dir / "SKILL.md"
    skill_disabled_path = paths.hermes_skill_dir / "SKILL.md.disabled"
    backup_skill_md = resolved_backup / "skills" / "maa-operator" / "SKILL.md"
    skill_restored = False
    if skill_disabled_path.is_file():
        os.replace(skill_disabled_path, skill_md)
        skill_restored = True
    elif backup_skill_md.is_file():
        paths.hermes_skill_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup_skill_md, skill_md)
        skill_restored = True

    # 7. 恢复 Mac GUI RemoteHermesHome='~/.hermes'
    before_meta = manifest.get("remote_hermes_home_before")
    target_gui = LEGACY_GUI_HOME_VALUE
    if isinstance(before_meta, dict) and before_meta.get("exists") and isinstance(before_meta.get("value"), str):
        val = before_meta["value"].strip()
        if val:
            target_gui = val
    defaults_be.write(GUI_DEFAULTS_DOMAIN, GUI_DEFAULTS_KEY, target_gui)

    # 8. 绝不删除 ~/.wados-maa
    return {
        "ok": True,
        "rolled_back_at": moment.isoformat(),
        "backup_dir": str(resolved_backup),
        "bootout": bootout_results,
        "restored_scripts": restored_scripts,
        "restored_buttons": restored_buttons,
        "restored_crons": restored_crons,
        "skill_restored": skill_restored,
        "gui_remote_hermes_home": target_gui,
        "wados_home_preserved": paths.wados_home.exists(),
    }


# ---------------------------------------------------------------------------
# 终端可读输出与 CLI 入口
# ---------------------------------------------------------------------------


def _format_cutover_report(result: Mapping[str, Any]) -> str:
    lines: list[str] = []
    mode = "DRY-RUN（未改动任何文件）" if result.get("dry_run") else "生产切线"
    lines.append(f"=== Wado's MAA {mode} ===")
    lines.append(f"检查时间：{result.get('checked_at')}")
    lines.append(f"旧目录：{result.get('hermes_home')}")
    lines.append(f"新目录：{result.get('wados_home')}")

    counts = result.get("counts") or {}
    exp = counts.get("expected") or {}
    lines.append(
        "数量核对："
        f"活跃 MAA cron {counts.get('active_maa_crons')}/{exp.get('active_maa_crons')}，"
        f"非 MAA cron {counts.get('non_maa_crons')}/{exp.get('non_maa_crons')}，"
        f"MAA 按钮 {counts.get('maa_buttons')}/{exp.get('maa_buttons')}，"
        f"非 MAA 按钮 {counts.get('non_maa_buttons')}/{exp.get('non_maa_buttons')}"
    )
    nxt = result.get("next_session")
    if isinstance(nxt, dict):
        lines.append(f"下一场定时任务：{nxt.get('label')} @ {nxt.get('at')}（约 {nxt.get('minutes_until')} 分钟后）")

    plan = result.get("plan") or {}
    lines.append("\n改动清单：")
    crons = plan.get("crons_to_pause") or []
    lines.append(f"  1. 暂停 MAA cron（{len(crons)} 条）：")
    for item in crons:
        lines.append(f"     - {item.get('id')}  {item.get('name')}  ({item.get('script')})")
    lines.append(
        f"     保留非 MAA cron：{len(plan.get('non_maa_crons_preserved') or [])} 条；"
        f"已停用 MAA cron：{len(plan.get('inactive_maa_crons_untouched') or [])} 条"
    )
    btns = plan.get("buttons_to_remove") or []
    lines.append(f"  2. 删除 MAA 按钮（{len(btns)} 条，保留非 MAA {len(plan.get('buttons_preserved') or [])} 条）：")
    for key in btns:
        lines.append(f"     - {key}")
    scripts = plan.get("scripts_to_stub") or []
    lines.append(f"  3. 置桩旧脚本（{len(scripts)} 个）：{', '.join(scripts)}")
    lines.append(f"  4. 停用 Hermes MAA skill：{plan.get('skill_to_disable') or '（未找到）'}")
    rewrites = result.get("path_rewrites") or plan.get("path_rewrites_estimated") or {}
    lines.append(f"  5. 状态迁移与路径改写：{json.dumps(rewrites, ensure_ascii=False)}")
    lines.append("  6. 确认 daemon.json depot_enabled = false")
    gui = plan.get("gui_defaults") or {}
    lines.append(f"  7. Mac GUI {gui.get('key')}：{gui.get('before')} → {gui.get('after')}")

    if result.get("backup_dir"):
        lines.append(f"\n回滚备份目录：{result['backup_dir']}")

    errors = result.get("errors") or []
    if errors:
        lines.append("\n拒绝执行原因：")
        for err in errors:
            lines.append(f"  [!] {err}")
    elif result.get("dry_run"):
        lines.append(
            f"\n结论：前置检查与 {EXPECTED_ACTIVE_MAA_CRONS}/{EXPECTED_NON_MAA_CRONS}/"
            f"{EXPECTED_MAA_BUTTONS}/{EXPECTED_NON_MAA_BUTTONS} 数量核对全部通过，可执行切线。"
        )
    else:
        lines.append("\n结论：生产切线已完成。")
    return "\n".join(lines)


def main(
    argv: list[str] | None = None,
    *,
    defaults: DefaultsBackend | None = None,
    launchctl: LaunchctlBackend | None = None,
    clock: Callable[[], datetime] | None = None,
) -> int:
    parser = argparse.ArgumentParser(description="Wado's MAA Phase 3 生产切线与一键回滚脚本（S3-6）")
    parser.add_argument("--home", default="", help="目标 HOME 目录（默认当前用户 HOME；演练请传临时目录）")
    parser.add_argument("--dry-run", action="store_true", help="仅检查前置条件并打印改动清单，不写盘")
    parser.add_argument("--rollback", default="", metavar="BACKUP_DIR", help="从指定备份目录一键回滚")
    parser.add_argument("--json", action="store_true", dest="as_json", help="以 JSON 输出结果")
    args = parser.parse_args(argv)

    if args.dry_run and args.rollback:
        print("不能同时指定 --dry-run 和 --rollback。", file=sys.stderr)
        return 2

    home = Path(args.home).expanduser() if args.home else Path.home()
    paths = CutoverPaths.from_home(home)
    now = clock() if clock is not None else maa_common.now_beijing()

    if args.rollback:
        result = run_rollback(
            paths,
            Path(args.rollback),
            now=now,
            defaults=defaults,
            launchctl=launchctl,
        )
        if args.as_json:
            print(json.dumps(result, ensure_ascii=False))
        else:
            if result.get("ok"):
                print(
                    f"回滚完成：恢复 {len(result['restored_crons'])} 条 MAA cron、"
                    f"{len(result['restored_buttons'])} 条 MAA 按钮、"
                    f"{len(result['restored_scripts'])} 个脚本，"
                    f"RemoteHermesHome={result['gui_remote_hermes_home']}，"
                    f"保留 {paths.wados_home}。"
                )
            else:
                for err in result.get("errors") or []:
                    print(f"[!] {err}", file=sys.stderr)
        return 0 if result.get("ok") else 1

    result = run_cutover(
        paths,
        dry_run=args.dry_run,
        now=now,
        defaults=defaults,
    )
    if args.as_json:
        print(json.dumps(result, ensure_ascii=False))
    else:
        print(_format_cutover_report(result))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
