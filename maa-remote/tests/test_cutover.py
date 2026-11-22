"""Phase 3 S3-6 生产切线与一键回滚脚本（`daemon/cutover.py`）离线演练单测。

全程仅在独立临时 HOME 内运行，绝不触碰真实 `~/.hermes`、`~/.wados-maa`、macOS defaults 或 launchd。
"""

from __future__ import annotations

import fcntl
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "daemon"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import cutover  # noqa: E402
import maa_common  # noqa: E402

_DEVICE_GUARDS: list = []
_MODULE_PATCHES: list = []


def setUpModule() -> None:
    _DEVICE_GUARDS[:] = _isolation.guard_devices()
    _MODULE_PATCHES[:] = _helpers.start_module_patches()


def tearDownModule() -> None:
    _helpers.stop_patches(_MODULE_PATCHES)
    for item in reversed(_DEVICE_GUARDS):
        item.stop()
    _isolation.assert_shared_home_clean()


class FakeDefaults:
    def __init__(self, initial: dict[tuple[str, str], str] | None = None) -> None:
        self.store: dict[tuple[str, str], str] = dict(initial or {})
        self.writes: list[tuple[str, str, str]] = []

    def read(self, domain: str, key: str) -> tuple[bool, str | None]:
        if (domain, key) in self.store:
            return True, self.store[(domain, key)]
        return False, None

    def write(self, domain: str, key: str, value: str) -> None:
        self.store[(domain, key)] = value
        self.writes.append((domain, key, value))


class FakeLaunchctl:
    def __init__(self, fail_labels: set[str] | None = None) -> None:
        self.fail_labels = set(fail_labels or set())
        self.booted_out: list[str] = []

    def bootout(self, label: str) -> tuple[bool, str]:
        self.booted_out.append(label)
        if label in self.fail_labels:
            return False, "mock bootout failure"
        return True, "stopped"


def _build_fixture_home(
    home: Path,
    *,
    active_maa_crons: int = 5,
    inactive_maa_crons: int = 2,
    non_maa_crons: int = 16,
    maa_buttons: int = 18,
    non_maa_buttons: int = 14,
) -> cutover.CutoverPaths:
    paths = cutover.CutoverPaths.from_home(home)
    for d in (
        paths.hermes_state_maa / "runs",
        paths.hermes_state_maa / "copilot",
        paths.hermes_buttons.parent,
        paths.hermes_cron_jobs.parent,
        paths.hermes_scripts,
        paths.hermes_skill_dir,
        paths.wados_home / "daemon",
    ):
        d.mkdir(parents=True, exist_ok=True)

    # 1. config.json（早场 08:00、晚场 22:00）
    maa_common.atomic_write_json(
        paths.hermes_state_maa / "config.json",
        {
            "schema_version": 1,
            "session_schedule": {
                "am": {"time": "08:00", "enabled": True},
                "pm": {"time": "22:00", "enabled": True},
            },
        },
    )
    maa_common.atomic_write_json(paths.hermes_state_maa / "defaults.json", {"stage": "1-7"})
    maa_common.atomic_write_json(
        paths.hermes_state_maa / "copilot" / "roster.json",
        {"fetched_at": "2026-11-21T08:00:00+08:00", "chars": {}},
    )

    # 2. last_run.json 与 runs/index.jsonl（含真实形态的 .hermes/state/maa 绝对路径）
    hermes_runs = paths.hermes_state_maa / "runs"
    maa_common.atomic_write_json(
        paths.hermes_state_maa / "last_run.json",
        {
            "schema_version": 1,
            "run_id": "2026-11-21-am-080005",
            "status": "success",
            "snapshot": str(hermes_runs / "2026-11-21-am.json"),
            "log": str(hermes_runs / "2026-11-21-am.log"),
            "screenshot": str(hermes_runs / "2026-11-21-am.png"),
            "report": str(hermes_runs / "2026-11-21-am-report.json"),
            "progress": str(hermes_runs / "2026-11-21-am.progress.json"),
        },
    )
    (hermes_runs / "2026-11-21-am-report.json").write_text('{"ok": true}\n', encoding="utf-8")
    index_rows = [
        {
            "schema_version": 1,
            "id": "2026-11-20-pm-220001",
            "kind": "daily",
            "status": "success",
            "log": str(hermes_runs / "2026-11-20-pm.log"),
            "report": str(hermes_runs / "2026-11-20-pm-report.json"),
            "progress": str(hermes_runs / "2026-11-20-pm.progress.json"),
        },
        {
            "schema_version": 1,
            "id": "2026-11-21-am-080005",
            "kind": "daily",
            "status": "success",
            "log": str(hermes_runs / "2026-11-21-am.log"),
            "report": str(hermes_runs / "2026-11-21-am-report.json"),
            "progress": str(hermes_runs / "2026-11-21-am.progress.json"),
        },
    ]
    (hermes_runs / "index.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False) for r in index_rows) + "\n",
        encoding="utf-8",
    )

    # 3. cron/jobs.json（按 Spec 基线：5 活跃 MAA + 2 已停 MAA + 16 非 MAA）
    active_specs = [
        ("03d5e98ce8d4", "MAA 计划卡·早", "maa_plan_card.py", str(paths.hermes_state_maa / "am"), "2026-11-21T23:50:00+00:00"),
        ("50cd1fb095f2", "MAA 日常·早", "maa_daily.py", str(paths.hermes_state_maa / "am"), "2026-11-22T00:00:00+00:00"),
        ("4f48cf619d9f", "MAA 日常·晚", "maa_daily.py", str(paths.hermes_state_maa / "pm"), "2026-11-21T14:00:00+00:00"),
        ("3ba48fb85d0b", "MAA 活动作业监控", "maa_activity_watch.py", None, "2026-11-21T06:15:00+00:00"),
        ("75e3d662fbfc", "MAA 计划卡·晚", "maa_plan_card.py", str(paths.hermes_state_maa / "pm"), "2026-11-21T13:50:00+00:00"),
    ]
    jobs: list[dict[str, Any]] = []
    for i in range(active_maa_crons):
        cid, name, script, workdir, nxt = active_specs[i % len(active_specs)]
        if i >= len(active_specs):
            cid = f"extra-maa-{i}"
            name = f"MAA 额外任务 {i}"
        jobs.append(
            {
                "id": cid,
                "name": name,
                "script": script,
                "workdir": workdir,
                "enabled": True,
                "state": "scheduled",
                "paused_at": None,
                "paused_reason": None,
                "next_run_at": nxt,
            }
        )
    inactive_specs = [
        ("b2f15f13589f", "MAA 仓库对表", "maa_depot.py", "paused"),
        ("acaef055726c", "MAA 早场前抄 YW-EX（一次性）", "maa_copilot_morning.sh", "completed"),
    ]
    for i in range(inactive_maa_crons):
        cid, name, script, state = inactive_specs[i % len(inactive_specs)]
        jobs.append(
            {
                "id": cid,
                "name": name,
                "script": script,
                "workdir": None,
                "enabled": False,
                "state": state,
                "paused_at": "2026-11-06T03:49:02+00:00" if state == "paused" else None,
                "paused_reason": None,
                "next_run_at": None,
            }
        )
    for i in range(non_maa_crons):
        jobs.append(
            {
                "id": f"non-maa-{i:02d}",
                "name": f"非 MAA 任务 {i}",
                "script": f"other_task_{i}.py",
                "workdir": None,
                "enabled": i != 0,
                "state": "paused" if i == 0 else "scheduled",
                "paused_at": None,
                "paused_reason": None,
                "next_run_at": "2026-11-21T12:00:00+00:00",
            }
        )
    maa_common.atomic_write_json(
        paths.hermes_cron_jobs,
        {"jobs": jobs, "updated_at": "2026-11-21T05:00:00+00:00"},
    )

    # 4. agent-book/buttons.json（18 MAA + 14 非 MAA）
    buttons: dict[str, Any] = {}
    for i in range(maa_buttons):
        prefix = "hermes:btn:maa-copilot:tok:" if i < 9 else "hermes:btn:maa-roguelike:" if i < 16 else "hermes:btn:maa:pm:"
        buttons[f"{prefix}k{i}"] = {"kind": "exec", "script": "maa_action.py", "args": ["plan", "show"]}
    for i in range(non_maa_buttons):
        key = f"hermes:btn:agent-book:{i}:complete" if i < non_maa_buttons - 1 else "hermes:btn:luxraykit-pr:merge:117"
        buttons[key] = {"kind": "exec", "script": "agent_book_action.py", "args": [str(i)]}
    maa_common.atomic_write_json(paths.hermes_buttons, buttons)

    # 5. scripts/maa_*.py 与非 MAA 脚本
    for name in ("maa_action.py", "maa_daily.py", "maa_plan_card.py"):
        p = paths.hermes_scripts / name
        p.write_text(f"#!/usr/bin/env python3\nprint('LIVE {name}')\n", encoding="utf-8")
        p.chmod(0o755)
    other_script = paths.hermes_scripts / "luxraykit_watchdog.py"
    other_script.write_text("#!/usr/bin/env python3\nprint('OTHER')\n", encoding="utf-8")

    # 6. Hermes MAA skill
    (paths.hermes_skill_dir / "SKILL.md").write_text("# maa-operator\n", encoding="utf-8")

    # 7. 新目录已有 daemon.json（故意设 depot_enabled=True，验证切线强制置回 False）
    maa_common.atomic_write_json(paths.wados_daemon_config, {"schema_version": 1, "depot_enabled": True})

    return paths


class CutoverTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="wados-cutover-")
        self.addCleanup(self._tmp.cleanup)
        self.home = Path(self._tmp.name) / "simhome"
        self.home.mkdir()
        # 北京时间 14:00（距 21:50 计划卡 470 分钟，距 07:50 超过 17 小时，完全处于安全窗口）
        self.safe_now = datetime(2026, 11, 21, 14, 0, 0, tzinfo=maa_common.BEIJING)

    def test_dry_run_prints_plan_and_mutates_nothing(self) -> None:
        paths = _build_fixture_home(self.home)
        defaults = FakeDefaults({(cutover.GUI_DEFAULTS_DOMAIN, cutover.GUI_DEFAULTS_KEY): "~/.hermes"})

        before_jobs = paths.hermes_cron_jobs.read_text(encoding="utf-8")
        before_buttons = paths.hermes_buttons.read_text(encoding="utf-8")
        before_action = (paths.hermes_scripts / "maa_action.py").read_text(encoding="utf-8")

        res = cutover.run_cutover(paths, dry_run=True, now=self.safe_now, defaults=defaults)
        self.assertTrue(res["ok"])
        self.assertTrue(res["dry_run"])
        self.assertEqual(res["counts"]["active_maa_crons"], 5)
        self.assertEqual(res["counts"]["non_maa_crons"], 16)
        self.assertEqual(res["counts"]["maa_buttons"], 18)
        self.assertEqual(res["counts"]["non_maa_buttons"], 14)

        # dry-run 绝不写盘、不建备份、不改 defaults
        self.assertEqual(paths.hermes_cron_jobs.read_text(encoding="utf-8"), before_jobs)
        self.assertEqual(paths.hermes_buttons.read_text(encoding="utf-8"), before_buttons)
        self.assertEqual((paths.hermes_scripts / "maa_action.py").read_text(encoding="utf-8"), before_action)
        self.assertTrue((paths.hermes_skill_dir / "SKILL.md").is_file())
        self.assertFalse(paths.wados_backups.exists())
        self.assertEqual(defaults.writes, [])

        # 验证可读报告包含改动清单与数量摘要
        text = cutover._format_cutover_report(res)
        self.assertIn("DRY-RUN", text)
        self.assertIn("5/5", text)
        self.assertIn("16/16", text)
        self.assertIn("18/18", text)
        self.assertIn("14/14", text)

    def test_full_cutover_verify_and_rollback_roundtrip(self) -> None:
        paths = _build_fixture_home(self.home)
        defaults = FakeDefaults({(cutover.GUI_DEFAULTS_DOMAIN, cutover.GUI_DEFAULTS_KEY): "~/.hermes"})
        launchctl = FakeLaunchctl()

        orig_action_text = (paths.hermes_scripts / "maa_action.py").read_text(encoding="utf-8")
        orig_other_script = (paths.hermes_scripts / "luxraykit_watchdog.py").read_text(encoding="utf-8")
        orig_jobs = json.loads(paths.hermes_cron_jobs.read_text(encoding="utf-8"))["jobs"]
        orig_non_maa_jobs = [j for j in orig_jobs if not cutover.is_maa_cron(j)]
        orig_buttons = json.loads(paths.hermes_buttons.read_text(encoding="utf-8"))
        orig_non_maa_buttons = {k: v for k, v in orig_buttons.items() if not cutover.is_maa_button(k, v)}

        # 1. 执行切线
        res = cutover.run_cutover(paths, dry_run=False, now=self.safe_now, defaults=defaults)
        self.assertTrue(res["ok"], res.get("errors"))
        self.assertTrue(res["executed"])
        backup_dir = Path(res["backup_dir"])
        self.assertTrue(backup_dir.is_dir())
        self.assertTrue((backup_dir / "manifest.json").is_file())
        self.assertTrue((backup_dir / "buttons.json").is_file())
        self.assertTrue((backup_dir / "jobs.json").is_file())
        self.assertTrue((backup_dir / "state_maa" / "last_run.json").is_file())

        # 2. 校验 5 条活跃 MAA cron 已暂停，16 条非 MAA cron 完好无损
        after_jobs = json.loads(paths.hermes_cron_jobs.read_text(encoding="utf-8"))["jobs"]
        active_maa, inactive_maa, non_maa = cutover.classify_crons(after_jobs)
        self.assertEqual(len(active_maa), 0)
        self.assertEqual(len(inactive_maa), 7)
        self.assertEqual(non_maa, orig_non_maa_jobs)

        # 3. 校验 skill 已停用
        self.assertFalse((paths.hermes_skill_dir / "SKILL.md").exists())
        self.assertTrue((paths.hermes_skill_dir / "SKILL.md.disabled").is_file())

        # 4. 校验 18 条 MAA 按钮已删除，14 条非 MAA 按钮完好无损
        after_buttons = json.loads(paths.hermes_buttons.read_text(encoding="utf-8"))
        self.assertEqual(after_buttons, orig_non_maa_buttons)
        self.assertEqual(len(after_buttons), 14)

        # 5. 校验旧 maa_*.py 被置为拒绝桩，且实际执行立即非零退出并提示迁移至 ~/.wados-maa
        for name in ("maa_action.py", "maa_daily.py", "maa_plan_card.py"):
            proc = subprocess.run(
                [sys.executable, str(paths.hermes_scripts / name)],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("~/.wados-maa", proc.stderr)
        # 非 MAA 脚本不受影响
        self.assertEqual((paths.hermes_scripts / "luxraykit_watchdog.py").read_text(encoding="utf-8"), orig_other_script)

        # 6. 校验状态目录迁移 & index.jsonl / last_run.json 路径全部改写
        migrated_lr = json.loads((paths.wados_state_maa / "last_run.json").read_text(encoding="utf-8"))
        for field in ("snapshot", "log", "screenshot", "report", "progress"):
            self.assertIn(".wados-maa/state/maa/", migrated_lr[field])
            self.assertNotIn(".hermes/state/maa/", migrated_lr[field])
        migrated_index_text = (paths.wados_state_maa / "runs" / "index.jsonl").read_text(encoding="utf-8")
        self.assertNotIn(".hermes/state/maa/", migrated_index_text)
        self.assertIn(".wados-maa/state/maa/", migrated_index_text)
        self.assertEqual(res["path_rewrites"]["index_lines_rewritten"], 2)
        self.assertEqual(res["path_rewrites"]["last_run_replacements"], 5)

        # 7. 校验 daemon.json depot_enabled: false
        daemon_cfg = json.loads(paths.wados_daemon_config.read_text(encoding="utf-8"))
        self.assertFalse(daemon_cfg["depot_enabled"])

        # 8. 校验 Mac GUI RemoteHermesHome 切到 ~/.wados-maa
        self.assertEqual(
            defaults.store[(cutover.GUI_DEFAULTS_DOMAIN, cutover.GUI_DEFAULTS_KEY)],
            "~/.wados-maa",
        )

        # 模拟切线期间非 MAA 按钮新增/修改了一条，验证回滚不会冲掉它
        live_buttons = json.loads(paths.hermes_buttons.read_text(encoding="utf-8"))
        live_buttons["hermes:btn:luxraykit-pr:merge:999"] = {"kind": "exec", "script": "luxraykit_pr_action.py"}
        maa_common.atomic_write_json(paths.hermes_buttons, live_buttons)

        # 9. 执行一键回滚
        rb = cutover.run_rollback(
            paths,
            backup_dir,
            now=self.safe_now,
            defaults=defaults,
            launchctl=launchctl,
        )
        self.assertTrue(rb["ok"], rb.get("errors"))
        self.assertEqual(launchctl.booted_out, list(cutover.LAUNCH_AGENT_LABELS))

        # 校验旧脚本恢复原样且可执行
        self.assertEqual((paths.hermes_scripts / "maa_action.py").read_text(encoding="utf-8"), orig_action_text)
        restored_proc = subprocess.run(
            [sys.executable, str(paths.hermes_scripts / "maa_action.py")],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        self.assertEqual(restored_proc.returncode, 0)
        self.assertIn("LIVE maa_action.py", restored_proc.stdout)

        # 校验 5 条 MAA cron 恢复活跃，16 条非 MAA 完好
        rb_jobs = json.loads(paths.hermes_cron_jobs.read_text(encoding="utf-8"))["jobs"]
        rb_active, rb_inactive, rb_non = cutover.classify_crons(rb_jobs)
        self.assertEqual(len(rb_active), 5)
        self.assertEqual(len(rb_inactive), 2)
        self.assertEqual(rb_non, orig_non_maa_jobs)

        # 校验 18 条 MAA 按钮已还原，且非 MAA 新按钮保留
        rb_buttons = json.loads(paths.hermes_buttons.read_text(encoding="utf-8"))
        rb_maa_keys, rb_non_keys = cutover.classify_buttons(rb_buttons)
        self.assertEqual(len(rb_maa_keys), 18)
        self.assertIn("hermes:btn:luxraykit-pr:merge:999", rb_non_keys)

        # 校验 skill 与 Mac GUI 偏好还原
        self.assertTrue((paths.hermes_skill_dir / "SKILL.md").is_file())
        self.assertFalse((paths.hermes_skill_dir / "SKILL.md.disabled").exists())
        self.assertEqual(
            defaults.store[(cutover.GUI_DEFAULTS_DOMAIN, cutover.GUI_DEFAULTS_KEY)],
            "~/.hermes",
        )

        # 校验 ~/.wados-maa 原样保留绝不删除
        self.assertTrue(paths.wados_home.is_dir())
        self.assertTrue((paths.wados_state_maa / "last_run.json").is_file())
        self.assertTrue(backup_dir.is_dir())

    def test_refuses_when_counts_mismatch_spec_5_16_18_14(self) -> None:
        cases = [
            ("active_maa_crons=4", {"active_maa_crons": 4}),
            ("non_maa_crons=15", {"non_maa_crons": 15}),
            ("maa_buttons=17", {"maa_buttons": 17}),
            ("non_maa_buttons=13", {"non_maa_buttons": 13}),
        ]
        for label, overrides in cases:
            with self.subTest(case=label):
                case_home = self.home / label.replace("=", "_")
                case_home.mkdir()
                paths = _build_fixture_home(case_home, **overrides)
                defaults = FakeDefaults()
                res = cutover.run_cutover(paths, dry_run=False, now=self.safe_now, defaults=defaults)
                self.assertFalse(res["ok"])
                self.assertTrue(any("数量与 Spec 不一致" in e for e in res["errors"]))
                self.assertFalse(paths.wados_backups.exists())
                self.assertEqual(defaults.writes, [])

    def test_refuses_when_run_lock_held_or_next_session_within_30_minutes(self) -> None:
        # 1. run.lock 被占用 → 拒绝切线
        paths1 = _build_fixture_home(self.home / "locked")
        defaults1 = FakeDefaults()
        paths1.hermes_run_lock.write_text('{"holder":"daily","pid":12345}', encoding="utf-8")
        with paths1.hermes_run_lock.open("a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                res = cutover.run_cutover(paths1, dry_run=False, now=self.safe_now, defaults=defaults1)
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        self.assertFalse(res["ok"])
        self.assertTrue(any("run.lock" in e for e in res["errors"]))
        self.assertFalse(paths1.wados_backups.exists())

        # 2. 距早场计划卡（07:50）不足 30 分钟（07:35）→ 拒绝切线
        paths2 = _build_fixture_home(self.home / "soon")
        defaults2 = FakeDefaults()
        soon_now = datetime(2026, 11, 21, 7, 35, 0, tzinfo=maa_common.BEIJING)
        res2 = cutover.run_cutover(paths2, dry_run=False, now=soon_now, defaults=defaults2)
        self.assertFalse(res2["ok"])
        self.assertTrue(any("安全窗口" in e for e in res2["errors"]))
        self.assertFalse(paths2.wados_backups.exists())

        # 3. 回滚时若新目录 run.lock 被占用 → 拒绝回滚且不调用 bootout
        paths3 = _build_fixture_home(self.home / "rb_locked")
        defaults3 = FakeDefaults()
        launchctl3 = FakeLaunchctl()
        cut = cutover.run_cutover(paths3, dry_run=False, now=self.safe_now, defaults=defaults3)
        self.assertTrue(cut["ok"])
        paths3.wados_run_lock.write_text('{"holder":"daily","pid":999}', encoding="utf-8")
        with paths3.wados_run_lock.open("a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                rb = cutover.run_rollback(
                    paths3,
                    Path(cut["backup_dir"]),
                    now=self.safe_now,
                    defaults=defaults3,
                    launchctl=launchctl3,
                )
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        self.assertFalse(rb["ok"])
        self.assertTrue(any("run.lock" in e for e in rb["errors"]))
        self.assertEqual(launchctl3.booted_out, [])

    def test_cli_main_dry_run_cutover_and_rollback(self) -> None:
        import contextlib
        import io

        cli_home = self.home / "cli_home"
        cli_home.mkdir()
        _build_fixture_home(cli_home)
        defaults = FakeDefaults({(cutover.GUI_DEFAULTS_DOMAIN, cutover.GUI_DEFAULTS_KEY): "~/.hermes"})
        launchctl = FakeLaunchctl()

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cutover.main(
                ["--home", str(cli_home), "--dry-run", "--json"],
                defaults=defaults,
                clock=lambda: self.safe_now,
            )
        self.assertEqual(rc, 0)
        dry_doc = json.loads(buf.getvalue())
        self.assertTrue(dry_doc["ok"])
        self.assertTrue(dry_doc["dry_run"])

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cutover.main(
                ["--home", str(cli_home), "--json"],
                defaults=defaults,
                clock=lambda: self.safe_now,
            )
        self.assertEqual(rc, 0)
        cut_doc = json.loads(buf.getvalue())
        self.assertTrue(cut_doc["executed"])
        backup_dir = cut_doc["backup_dir"]

        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = cutover.main(
                ["--home", str(cli_home), "--rollback", backup_dir, "--json"],
                defaults=defaults,
                launchctl=launchctl,
                clock=lambda: self.safe_now,
            )
        self.assertEqual(rc, 0)
        rb_doc = json.loads(buf.getvalue())
        self.assertTrue(rb_doc["ok"])
        self.assertTrue(rb_doc["wados_home_preserved"])

        # 同时传 --dry-run 与 --rollback 应返回退出码 2
        err_buf = io.StringIO()
        with contextlib.redirect_stderr(err_buf):
            rc_bad = cutover.main(["--home", str(cli_home), "--dry-run", "--rollback", backup_dir])
        self.assertEqual(rc_bad, 2)


if __name__ == "__main__":
    unittest.main()
