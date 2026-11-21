"""内置调度器（`maa_daemon.py`）与 `wados-maa-launcher.swift` 离线单测（S1-5）。"""

from __future__ import annotations

import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_common  # noqa: E402
import maa_daemon  # noqa: E402
from _helpers import BEIJING  # noqa: E402

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


class FakeProc:
    def __init__(self, pid: int, code: int | None = None) -> None:
        self.pid = pid
        self.code = code

    def poll(self) -> int | None:
        return self.code


class DaemonSchedulerTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="daemon-sched-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.state_path = self.root / "scheduler.json"
        self.daemon_cfg_path = self.root / "daemon.json"
        self.now = datetime(2026, 11, 21, 7, 50, tzinfo=BEIJING)
        self.config: dict[str, Any] = {
            "session_schedule": {
                "am": {"time": "08:00", "enabled": True},
                "pm": {"time": "22:00", "enabled": True},
            },
            "manual_run_blackout_minutes": 30,
        }
        self.run_locked = False
        self.watch_locked = False
        self.spawned: list[tuple[list[str], FakeProc]] = []
        self.signals: list[tuple[int, int]] = []
        self._next_pid = 10000

    def _make_scheduler(self) -> maa_daemon.DaemonScheduler:
        def spawner(argv: list[str]) -> FakeProc:
            self._next_pid += 1
            proc = FakeProc(self._next_pid, code=None)
            self.spawned.append((argv, proc))
            return proc

        return maa_daemon.DaemonScheduler(
            state_path=self.state_path,
            daemon_config_path=self.daemon_cfg_path,
            scripts_dir=self.root / "scripts",
            python_bin="/usr/bin/python3",
            clock=lambda: self.now,
            config_loader=lambda: self.config,
            run_lock_probe=lambda: self.run_locked,
            watch_lock_probe=lambda: self.watch_locked,
            spawner=spawner,
            signaler=lambda pid, sig: self.signals.append((pid, sig)),
        )

    def test_catchup_rules_same_day_2h_limit_midnight_and_blackout(self) -> None:
        # 1. 迟到 90 分钟且同一北京自然日、不在另一场保护窗 → 允许补跑
        sched = datetime(2026, 11, 21, 8, 0, tzinfo=BEIJING)
        decision, reason = maa_daemon.evaluate_catchup(
            "daily_am", sched, datetime(2026, 11, 21, 9, 30, tzinfo=BEIJING), self.config
        )
        self.assertEqual(decision, "run", reason)
        self.assertIn("补跑", reason)

        # 2. 迟到超过 2 小时 → missed
        decision, _ = maa_daemon.evaluate_catchup(
            "daily_am", sched, datetime(2026, 11, 21, 10, 1, tzinfo=BEIJING), self.config
        )
        self.assertEqual(decision, "missed")

        # 3. 跨零点（23:00 晚场次日 00:30，虽然仅过 1.5 小时但跨北京自然日）→ missed
        late_cfg = {
            "session_schedule": {
                "am": {"time": "08:00", "enabled": True},
                "pm": {"time": "23:00", "enabled": True},
            },
            "manual_run_blackout_minutes": 30,
        }
        decision, reason = maa_daemon.evaluate_catchup(
            "daily_pm",
            datetime(2026, 11, 21, 23, 0, tzinfo=BEIJING),
            datetime(2026, 11, 22, 0, 30, tzinfo=BEIJING),
            late_cfg,
        )
        self.assertEqual(decision, "missed")
        self.assertIn("跨北京自然日", reason)

        # 4. 挤入下一场保护窗口（am 11:00 迟到 1.5h 到 12:30，而 pm 设在 12:45，已进 30 分钟保护窗）→ missed
        tight_cfg = {
            "session_schedule": {
                "am": {"time": "11:00", "enabled": True},
                "pm": {"time": "12:45", "enabled": True},
            },
            "manual_run_blackout_minutes": 30,
        }
        decision, reason = maa_daemon.evaluate_catchup(
            "daily_am",
            datetime(2026, 11, 21, 11, 0, tzinfo=BEIJING),
            datetime(2026, 11, 21, 12, 30, tzinfo=BEIJING),
            tight_cfg,
        )
        self.assertEqual(decision, "missed")
        self.assertIn("保护窗口", reason)

    def test_same_session_catchup_runs_plan_card_strictly_before_daily(self) -> None:
        # 08:20 醒来：早场计划卡（07:50）与早场日常（08:00）均在 2 小时补跑窗内
        self.now = datetime(2026, 11, 21, 8, 20, tzinfo=BEIJING)
        sched = self._make_scheduler()

        first = sched.tick()
        self.assertIn("plan_card_am", first)
        self.assertNotIn("daily_am", first)

        # 计划卡还没跑完，下一拍绝不拉起 daily_am
        self.now = datetime(2026, 11, 21, 8, 21, tzinfo=BEIJING)
        self.assertNotIn("daily_am", sched.tick())

        # 计划卡退出后，下一拍立刻拉起 daily_am
        plan_proc = next(proc for argv, proc in self.spawned if "maa_plan_card.py" in argv[1])
        plan_proc.code = 0
        self.now = datetime(2026, 11, 21, 8, 22, tzinfo=BEIJING)
        third = sched.tick()
        self.assertEqual(third, ["daily_am"])

    def test_depot_defaults_disabled_and_respects_daemon_json(self) -> None:
        self.now = datetime(2026, 11, 21, 4, 30, tzinfo=BEIJING)
        sched = self._make_scheduler()
        self.assertNotIn("depot", sched.tick())

        maa_common.atomic_write_json(self.daemon_cfg_path, {"depot_enabled": True})
        self.assertIn("depot", sched.tick())

    def test_daily_hard_timeout_sends_sigint_then_sigkill_and_exempts_other_jobs(self) -> None:
        self.now = datetime(2026, 11, 21, 8, 0, tzinfo=BEIJING)
        # 标记 plan_card_am 已完成，让本拍直接拉起 daily_am 和 activity_watch
        maa_common.atomic_write_json(
            self.state_path,
            {"jobs": {"plan_card_am": {"last_slot": "2026-11-21T07:50"}}},
        )
        sched = self._make_scheduler()
        launched = sched.tick()
        self.assertIn("daily_am", launched)
        self.assertIn("activity_watch", launched)
        daily_pid = sched.active["daily_am"].proc.pid
        watch_pid = sched.active["activity_watch"].proc.pid

        # 过 59 分钟：未超时
        self.now = datetime(2026, 11, 21, 8, 59, tzinfo=BEIJING)
        sched.tick()
        self.assertEqual(self.signals, [])

        # 过 60 分钟：仅对 daily_am 发 SIGINT，绝不对非日常任务发信号
        self.now = datetime(2026, 11, 21, 9, 0, tzinfo=BEIJING)
        sched.tick()
        self.assertEqual(self.signals, [(daily_pid, signal.SIGINT)])
        self.assertNotIn(watch_pid, [pid for pid, _ in self.signals])

        # 宽限 89 秒内不 SIGKILL
        self.now = datetime(2026, 11, 21, 9, 1, 29, tzinfo=BEIJING)
        sched.tick()
        self.assertEqual(len(self.signals), 1)

        # 宽限满 90 秒仍未退出 → SIGKILL
        self.now = datetime(2026, 11, 21, 9, 1, 30, tzinfo=BEIJING)
        sched.tick()
        self.assertEqual(self.signals[-1], (daily_pid, signal.SIGKILL))

    def test_restart_does_not_reenter_when_run_lock_is_held_by_surviving_run(self) -> None:
        """守护进程重启后内存 active 为空，但 run.lock 仍被运行中场次持有 → 绝不重复派发。"""
        self.now = datetime(2026, 11, 21, 8, 5, tzinfo=BEIJING)
        maa_common.atomic_write_json(
            self.state_path,
            {"jobs": {"plan_card_am": {"last_slot": "2026-11-21T07:50"}}},
        )
        self.run_locked = True
        sched = self._make_scheduler()
        launched = sched.tick()
        self.assertNotIn("daily_am", launched)

        # 模拟外部场次未写 last_slot 仍在跑，锁释放前始终不重入
        self.now = self.now + timedelta(minutes=1)
        self.assertNotIn("daily_am", sched.tick())

    def test_activity_watch_only_runs_current_slot_without_catching_up_history(self) -> None:
        self.now = datetime(2026, 11, 21, 10, 35, tzinfo=BEIJING)
        sched = self._make_scheduler()
        launched = sched.tick()
        self.assertEqual(launched, ["activity_watch"])
        # 同一 15 分钟槽位内下一拍不重跑
        self.now = datetime(2026, 11, 21, 10, 44, tzinfo=BEIJING)
        sched.active["activity_watch"].proc.code = 0
        self.assertEqual(sched.tick(), [])
        # 进入 10:45 新槽位才跑一次
        self.now = datetime(2026, 11, 21, 10, 45, tzinfo=BEIJING)
        self.assertEqual(sched.tick(), ["activity_watch"])

    def test_launcher_swift_compiles_cleanly_and_plist_has_abandon_process_group(self) -> None:
        plist_text = (ROOT / "daemon" / "io.github.ffkiyo7.wados-maa.daemon.plist").read_text(encoding="utf-8")
        self.assertIn("<key>AbandonProcessGroup</key>", plist_text)
        self.assertIn("<true/>", plist_text)
        for env_key in ("WADOS_MAA_HOME", "PATH", "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
            self.assertIn(f"<key>{env_key}</key>", plist_text)
        if shutil.which("swiftc"):
            out = self.root / "wados-maa-launcher"
            proc = subprocess.run(
                [
                    "swiftc",
                    "-O",
                    "-warnings-as-errors",
                    str(ROOT / "daemon" / "wados-maa-launcher.swift"),
                    "-o",
                    str(out),
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=180,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            run = subprocess.run(
                [str(out), sys.executable, "-c", "print('ok-launcher')"],
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(run.stdout.strip(), "ok-launcher")


if __name__ == "__main__":
    unittest.main()
