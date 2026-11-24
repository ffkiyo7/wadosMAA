"""游戏中途退出（不变量 #68，2026-11-25 手动场）：认出、停下、重开、接着跑、战报。"""
from __future__ import annotations

import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Any, cast
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

# 必须先于任何 scripts/ 模块：把 HOME 换成临时目录，碰真实 home / 外网当场炸。
import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_common  # noqa: E402
import maa_daily  # noqa: E402
import maa_playcover  # noqa: E402

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


# 2026-11-25 手动场的骨架：StartUp 点到加载界面时游戏退了，之后只剩截图失败。
EXIT_IN_STARTUP_LOG = [
    "Detected connection with PlayTools",
    "Game is already running!",
    "StartUp Start",
    *["ScreencapFailed"] * 5,
]
EXIT_LINE = "游戏中途退出（00:23:29 发现，游戏进程 9001 退出了），MaaCore 不会重连，已停掉 maa run。没有崩溃报告。"

# 刷理智打到一半游戏退了：基建在它之前跑完（汇总里 Completed），后面都没开始。
EXIT_IN_FIGHT_LOG = [
    "StartUp Start",
    "StartUp Completed",
    "Infrast Start",
    "Infrast Completed",
    "Fight Start",
    "Mission started (3 times, use 63 sanity)",
    "Summary",
    "----------------------------------------",
    "[启动国服] 08:00:10 - 08:00:40 (30s) Completed",
    "----------------------------------------",
    "[基建换班] 08:00:40 - 08:03:00 (2m 20s) Completed",
    "----------------------------------------",
    "[刷理智] 08:03:00 - Unfinished",
    "Fight OS-9 3 times, drops:",
    "1. 固源岩 × 2",
    "total drops: 固源岩 × 2",
    "----------------------------------------",
    "[公开招募] Unstarted",
    "----------------------------------------",
    "[信用商店] Unstarted",
    "----------------------------------------",
    "[领取奖励] Unstarted",
    "----------------------------------------",
    "[返回主界面] Unstarted",
    "Error: Interrupted by user!",
]

RESUMED_LOG = [
    "StartUp Start",
    "StartUp Completed",
    "Fight Start",
    "Fight Completed",
    "Summary",
    "----------------------------------------",
    "[启动国服] 08:05:10 - 08:05:40 (30s) Completed",
    "----------------------------------------",
    "[刷理智] 08:05:40 - 08:09:00 (3m 20s) Completed",
    "Fight OS-9 5 times, drops:",
    "1. 固源岩 × 4",
    "total drops: 固源岩 × 4",
    "----------------------------------------",
    "[公开招募] 08:09:00 - 08:10:00 (1m) Completed",
    "----------------------------------------",
    "[信用商店] 08:10:00 - 08:10:30 (30s) Completed",
    "----------------------------------------",
    "[领取奖励] 08:10:30 - 08:10:50 (20s) Completed",
    "----------------------------------------",
    "[返回主界面] 08:10:50 - 08:11:00 (10s) Completed",
]


def _plan(**overrides: Any) -> maa_common.Plan:
    return cast(maa_common.Plan, {**maa_common.normalize_plan({"stage": "OS-9"}), "annihilation": True, **overrides})


class GameExitWatchTests(unittest.TestCase):
    def _watch(self, *answers: Any) -> maa_playcover.GameExitWatch:
        probe = MagicMock(side_effect=list(answers))
        return maa_playcover.GameExitWatch(cast(maa_common.Config, {}), probe=probe)

    def test_the_first_sighting_is_the_baseline_and_the_same_process_is_fine(self) -> None:
        watch = self._watch([9001], [9001], [9001, 9002])
        self.assertEqual([watch.check(), watch.check(), watch.check()], ["", "", ""])
        self.assertEqual(watch.baseline, [9001])

    def test_a_vanished_process_is_an_exit(self) -> None:
        watch = self._watch([9001], [])
        watch.check()
        self.assertEqual(watch.check(), "游戏进程 9001 退出了")

    def test_a_replaced_process_is_an_exit(self) -> None:
        # 11-25：旧进程退出、被 `open -a` 拉起一个新的，pgrep 看到的是另一个 PID。
        watch = self._watch([9001], [10371])
        watch.check()
        self.assertEqual(watch.check(), "游戏进程从 9001 换成了 10371")

    def test_an_unknown_answer_is_never_an_exit(self) -> None:
        watch = self._watch([9001], None, RuntimeError("pgrep 坏了"), [9001])
        self.assertEqual([watch.check() for _ in range(4)], ["", "", "", ""])

    def test_no_game_at_start_waits_for_the_first_sighting(self) -> None:
        watch = self._watch([], [], [9001], [])
        self.assertEqual([watch.check() for _ in range(3)], ["", "", ""])
        self.assertEqual(watch.check(), "游戏进程 9001 退出了")


class ProbeGamePidsTests(unittest.TestCase):
    def _probe(self, run: Any) -> list[int] | None:
        fake = SimpleNamespace(run=run, SubprocessError=subprocess.SubprocessError)
        with patch.object(maa_playcover, "subprocess", fake):
            return maa_playcover.probe_game_pids(cast(maa_common.Config, {}))

    def test_pgrep_answers_map_to_pids_empty_or_unknown(self) -> None:
        def answer(code: int, out: str = "") -> Any:
            return lambda *_a, **_k: SimpleNamespace(returncode=code, stdout=out)

        self.assertEqual(self._probe(answer(0, "9001\n9002\n")), [9001, 9002])
        self.assertEqual(self._probe(answer(1)), [])
        self.assertIsNone(self._probe(answer(2)))

    def test_a_timeout_is_unknown_not_an_exit(self) -> None:
        def boom(*_a: Any, **_k: Any) -> Any:
            raise subprocess.TimeoutExpired("pgrep", 2)

        self.assertIsNone(self._probe(boom))


class CrashReportTests(unittest.TestCase):
    def test_only_reports_after_the_run_started_newest_first(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            app = root / "Arknights.app"
            app.mkdir()
            reports = root / "reports"
            reports.mkdir()
            for name, mtime in (("Arknights-old.ips", 100), ("Arknights-a.ips", 300), ("Arknights-b.ips", 400)):
                path = reports / name
                path.write_text("{}", encoding="utf-8")
                os.utime(path, (mtime, mtime))
            (reports / "Other-new.ips").write_text("{}", encoding="utf-8")
            config = cast(maa_common.Config, {"playcover_app_path": str(app)})
            found = maa_playcover.crash_reports_since(config, 200, directory=reports)
            missing = maa_playcover.crash_reports_since(config, 200, directory=root / "nope")
        self.assertEqual([Path(p).name for p in found], ["Arknights-b.ips", "Arknights-a.ips"])
        self.assertEqual(missing, [])


class _NeverEndingProcess:
    """`maa run` 的桩：不自己退出，直到被 terminate。"""

    def __init__(self, stdout: str = "") -> None:
        self.stdout = io.StringIO(stdout)
        self.stderr = io.StringIO("")
        self.terminated = False

    def poll(self) -> int | None:
        return 0 if self.terminated else None

    def terminate(self) -> None:
        self.terminated = True

    def kill(self) -> None:
        self.terminated = True

    def wait(self, timeout: float | None = None) -> int:
        return -15 if self.terminated else 0


class RunMaaGameExitTests(unittest.TestCase):
    def test_an_exit_stops_maa_run_before_any_window_rescue(self) -> None:
        process = _NeverEndingProcess("ScreencapFailed\n" * 3)
        watch = MagicMock()
        # 拉起时记基线，第一次巡检就发现进程没了。
        watch.check.side_effect = ["", "游戏进程 9001 退出了"]
        with (
            tempfile.TemporaryDirectory() as raw,
            patch.object(maa_daily.subprocess, "Popen", return_value=process),
            patch.object(maa_daily.time, "sleep"),
            patch.object(maa_playcover, "settle_game_window") as settle,
            patch.object(maa_playcover, "crash_reports_since", return_value=["/r/Arknights-1.ips"]),
        ):
            log_path = Path(raw) / "run.log"
            code, _out, err = maa_daily.run_maa(
                cast(maa_common.Config, {"maa_bin": "/maa"}),
                log_path, "token", "", "",
                game_watch=watch,
            )
            log = log_path.read_text(encoding="utf-8")
        self.assertEqual(code, maa_daily.GAME_EXITED_CODE)
        self.assertTrue(process.terminated)
        # 游戏已经不在了：不许再 `open -a` 把它悄悄拉起来（11-25 就是这么卡死的）。
        settle.assert_not_called()
        self.assertEqual(maa_daily.game_exit_count(err), 1)
        self.assertIn("游戏进程 9001 退出了", log)
        self.assertIn("崩溃报告：/r/Arknights-1.ips", log)

    def test_without_a_watch_nothing_probes_the_game(self) -> None:
        # 不传 watch 时一次 pgrep 都不跑（单测、补跑以外的调用方都靠这个）。
        process = SimpleNamespace(
            stdout=io.StringIO("Summary\n"), stderr=io.StringIO(""), poll=lambda: 0, wait=lambda timeout=None: 0
        )
        with tempfile.TemporaryDirectory() as raw, patch.object(
            maa_daily.subprocess, "Popen", return_value=process
        ):
            code, _out, _err = maa_daily.run_maa(
                cast(maa_common.Config, {"maa_bin": "/maa"}), Path(raw) / "run.log", "token", "", ""
            )
        self.assertEqual(code, 0)


class GameExitPlanTests(unittest.TestCase):
    def test_an_exit_during_startup_reruns_the_whole_plan(self) -> None:
        plan = _plan()
        resumed = maa_daily.game_exit_plan(plan, EXIT_IN_STARTUP_LOG)
        self.assertEqual(resumed["tasks"], plan["tasks"])
        self.assertTrue(resumed["annihilation"])
        self.assertTrue(resumed["farming"])

    def test_finished_chains_are_dropped_and_annihilation_is_not_reentered(self) -> None:
        resumed = maa_daily.game_exit_plan(_plan(), EXIT_IN_FIGHT_LOG)
        tasks = resumed["tasks"]
        self.assertFalse(tasks["infrast"])
        self.assertTrue(tasks["fight"] and tasks["recruit"] and tasks["mall"] and tasks["award"])
        self.assertTrue(resumed["farming"])
        self.assertFalse(resumed["annihilation"])
        # 快照里的关卡、理智药都不动（#10）。
        self.assertEqual(resumed["stage"], "OS-9")
        toml = maa_daily.render_daily_toml(resumed, cast(maa_common.Config, {}))
        self.assertNotIn("基建换班", toml)
        self.assertNotIn("每日剿灭", toml)
        self.assertIn("刷理智", toml)
        self.assertIn("stone = 0", toml)

    def test_a_finished_fight_with_annihilation_started_drops_the_fight_switch(self) -> None:
        lines = [*EXIT_IN_FIGHT_LOG[:7], "[刷理智] 08:03:00 - 08:06:00 (3m) Completed"]
        resumed = maa_daily.game_exit_plan(_plan(), lines)
        self.assertFalse(resumed["tasks"]["fight"])

    def test_streaming_completed_alone_does_not_count(self) -> None:
        # 剿灭和刷理智都是 Fight，流式的「Fight Completed」分不清是哪块，只认汇总。
        lines = ["StartUp Completed", "Fight Start", "Fight Completed", "Mall Start", "Mall Completed"]
        resumed = maa_daily.game_exit_plan(_plan(), lines)
        self.assertTrue(resumed["farming"])
        self.assertTrue(resumed["tasks"]["mall"])


class ResilientGameExitTests(unittest.TestCase):
    def _resilient(self, attempts: list[tuple[int, list[str], list[str]]], config: dict[str, Any] | None = None):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            log_path = root / "run.log"
            task_path = root / "daily.toml"
            task_path.write_text("原计划", encoding="utf-8")
            with (
                patch.object(maa_daily, "run_maa", side_effect=attempts) as runner,
                patch.object(maa_daily.time, "sleep"),
                patch.object(maa_playcover, "restart_game", return_value=[]) as restart,
                patch.object(maa_playcover, "settle_game_window", return_value="") as settle,
                patch.object(maa_playcover, "wait_for_game"),
            ):
                result = maa_daily.run_maa_resilient(
                    cast(maa_common.Config, {"maa_run_timeout": 3000, **(config or {})}),
                    log_path, "token", "1", "2", _plan(),
                    task_path=task_path,
                )
            self.runner, self.restart, self.settle = runner, restart, settle
            self.task_text = task_path.read_text(encoding="utf-8")
            self.log_text = log_path.read_text(encoding="utf-8") if log_path.exists() else ""
        return result

    def test_restart_and_resume_only_what_is_left(self) -> None:
        code, out, err, retries, offline = self._resilient(
            [(maa_daily.GAME_EXITED_CODE, EXIT_IN_FIGHT_LOG, [EXIT_LINE]), (0, RESUMED_LOG, [])]
        )
        self.assertEqual((code, retries, offline), (0, 0, 0))
        self.restart.assert_called_once()
        # 重启后摆窗，但摆窗自己不再重启一次。
        self.assertFalse(self.settle.call_args.kwargs.get("allow_restart", False))
        # 任务文件只剩没跑完的：基建跑完了，剿灭开过头了。
        self.assertNotIn("基建换班", self.task_text)
        self.assertNotIn("每日剿灭", self.task_text)
        self.assertIn("刷理智", self.task_text)
        self.assertIn("接着跑第 1 趟：刷理智、公招、商店、领奖", "".join(err))
        # 两趟的输出都交回去：基建的 Completed 在第一趟里。
        self.assertIn("[基建换班] 08:00:40 - 08:03:00 (2m 20s) Completed", out)
        self.assertIn("[公开招募] 08:09:00 - 08:10:00 (1m) Completed", out)
        self.assertTrue(self.runner.call_args_list[1].kwargs["append"])
        # 每趟都带着自己的进程看门狗。
        for call in self.runner.call_args_list:
            self.assertIsInstance(call.kwargs["game_watch"], maa_playcover.GameExitWatch)

    def test_gives_up_after_the_limit(self) -> None:
        code, _out, err, _retries, _offline = self._resilient(
            [(maa_daily.GAME_EXITED_CODE, EXIT_IN_STARTUP_LOG, [EXIT_LINE])] * 2
        )
        self.assertEqual(code, maa_daily.GAME_EXITED_CODE)
        self.assertEqual(self.runner.call_count, 2)
        self.restart.assert_called_once()
        self.assertTrue(any(maa_daily.GAME_EXIT_GAVE_UP in line for line in err))
        self.assertEqual(maa_daily.game_exit_count(err), 2)

    def test_a_zero_limit_never_restarts(self) -> None:
        code, *_rest = self._resilient(
            [(maa_daily.GAME_EXITED_CODE, EXIT_IN_STARTUP_LOG, [EXIT_LINE])], {"game_exit_retry_limit": 0}
        )
        self.assertEqual(code, maa_daily.GAME_EXITED_CODE)
        self.restart.assert_not_called()
        self.assertEqual(self.task_text, "原计划")

    def test_a_game_exit_is_never_mistaken_for_a_connect_failure(self) -> None:
        # 退出那趟满屏 ScreencapFailed，但返回码是我们写的 126：不走「摆窗重开」那条路。
        self.assertEqual(maa_daily.connect_failed(EXIT_IN_STARTUP_LOG, maa_daily.GAME_EXITED_CODE), "")


class GameExitReportTests(unittest.TestCase):
    def test_startup_says_the_game_exited_instead_of_blaming_maatools(self) -> None:
        summary = maa_daily.extract_summary(EXIT_IN_STARTUP_LOG, [EXIT_LINE], plan=_plan(), ok=False)
        startup = next(line for line in summary.splitlines() if "登录与首登领取" in line)
        self.assertIn("游戏中途退出", startup)
        self.assertNotIn("MaaTools", startup)

    def test_two_attempts_merge_into_one_report(self) -> None:
        lines = EXIT_IN_FIGHT_LOG + [EXIT_LINE] + RESUMED_LOG
        summary = maa_daily.extract_summary(lines, [], plan=_plan(annihilation=False), ok=True)
        rows = {line.split("：")[0]: line for line in summary.splitlines()}
        self.assertIn("✅ 完成", rows["🏭 基建换班"])
        self.assertIn("✅ 完成", rows["🎫 公开招募"])
        fight = rows["⚔️ 刷理智"]
        self.assertIn("✅ 完成", fight)
        # 两段汇总的次数和掉落加起来：3 + 5 次，固源岩 2 + 4。
        self.assertIn("8 次", fight)
        self.assertIn("固源岩 ×6", fight)
        self.assertEqual(
            maa_daily._drop_pairs(maa_daily.farming_sections(lines)), [("固源岩", 6)]
        )

    def test_failure_and_notes(self) -> None:
        base: dict[str, Any] = dict(
            startup_error="", offline_gave_up=False, connect_gave_up=True, timed_out=False,
            proxy_batches=0, return_code=maa_daily.GAME_EXITED_CODE, home_verified=None,
            cleanup_errors=[], inventory_error="",
        )
        self.assertEqual(maa_daily.daily_failure(**base, game_exit_gave_up=True), "game_exited")
        self.assertEqual(maa_daily.daily_failure(**{**base, "offline_gave_up": True}, game_exit_gave_up=True), "offline")
        payload = maa_daily.report_payload(
            ok=True, phase="am", plan=_plan(), duration=600, summary="", screenshot_ok=True,
            screenshot_error="", cleanup_errors=[], home_verified=True, game_exits=1,
        )
        note = next(f for f in payload["embeds"][0]["fields"] if f["name"] == "备注")
        self.assertIn("游戏中途退出过 1 次", note["value"])


class CopilotGameExitTests(unittest.TestCase):
    def test_the_watchdog_stops_copilot_when_the_game_exits(self) -> None:
        import maa_copilot_worker as worker

        process = _NeverEndingProcess()
        watch = MagicMock()
        watch.check.side_effect = ["", "游戏进程 9001 退出了"]
        clock = iter(range(0, 1000, 10))
        with (
            tempfile.TemporaryDirectory() as raw,
            patch.object(worker, "SCRIPTS_DIR", Path(raw)),
            patch.object(worker.subprocess, "Popen", return_value=process),
            patch.object(worker.time, "sleep"),
            patch.object(worker.time, "monotonic", side_effect=lambda: next(clock)),
        ):
            log_path = Path(raw) / "copilot.log"
            code, _taps = worker._run_copilot_with_watchdog(
                cast(maa_common.Config, {}), ["maa", "copilot"], None, log_path, {},
                timeout=600, game_watch=watch,
            )
            log = log_path.read_text(encoding="utf-8")
        self.assertEqual(code, maa_daily.GAME_EXITED_CODE)
        self.assertTrue(process.terminated)
        self.assertIn("游戏中途退出", log)

    def test_an_exit_ends_the_round_without_battle_settling(self) -> None:
        import maa_copilot_worker as worker

        with (
            tempfile.TemporaryDirectory() as raw,
            patch.object(worker, "_prepare_op_file", return_value=("maa://1", False)),
            patch.object(worker, "_navigate_to_stage", return_value=(True, "")),
            patch.object(worker, "_run_copilot_with_watchdog", return_value=(maa_daily.GAME_EXITED_CODE, 0)),
        ):
            log_path = Path(raw) / "copilot.log"
            log_path.write_text("", encoding="utf-8")
            outcome, detail = worker._fight_one(
                cast(maa_common.Config, {"maa_bin": "/bin/maa"}),
                {"stage": "SR-5", "stage_id": "act54side_05", "mode": "normal", "candidate": {"id": 1}},
                {},
                log_path,
            )
        self.assertEqual(outcome, "exited")
        self.assertIn("游戏中途退出", detail)


class GameExitInvariantTests(unittest.TestCase):
    def test_every_maa_run_in_the_daily_chain_carries_a_watch(self) -> None:
        # #68：日常里每一处真跑 maa run 的地方都要盯游戏进程。
        import inspect

        for func in (maa_daily.run_maa_resilient, maa_daily._salvage_run, maa_daily._fallback_fight_run):
            with self.subTest(func=func.__name__):
                self.assertIn("game_watch=maa_playcover.GameExitWatch(config)", inspect.getsource(func))

    def test_the_restart_still_has_one_implementation(self) -> None:
        import inspect

        source = inspect.getsource(maa_daily.run_maa_resilient)
        self.assertNotIn("close_game", source)
        self.assertNotIn("launch_game", source)



if __name__ == "__main__":
    unittest.main()
