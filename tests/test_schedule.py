"""早晚场时间可配置（K6）：`config.session_schedule`、各处闸门、`schedule` 命令和 cron 同步。

`hermes` 一律打桩：单测绝不跑真 `hermes cron`（它会改 `$HERMES_HOME/cron/jobs.json`）。
"""
from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from typing import Any
from unittest.mock import patch
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import deploy  # noqa: E402
import maa_action  # noqa: E402
import maa_common  # noqa: E402
import maa_plan_card  # noqa: E402
import maa_schedule  # noqa: E402
from _helpers import BEIJING  # noqa: E402

_DEVICE_GUARDS: list = []
_MODULE_PATCHES: list = []
UTC = ZoneInfo("Etc/UTC")


def setUpModule() -> None:
    _DEVICE_GUARDS[:] = _isolation.guard_devices()
    _MODULE_PATCHES[:] = _helpers.start_module_patches()


def tearDownModule() -> None:
    _helpers.stop_patches(_MODULE_PATCHES)
    for item in reversed(_DEVICE_GUARDS):
        item.stop()
    _isolation.assert_shared_home_clean()


def schedule(am: str = "08:00", pm: str = "22:00", *, am_on: bool = True, pm_on: bool = True) -> dict:
    return {
        "session_schedule": {
            "am": {"time": am, "enabled": am_on},
            "pm": {"time": pm, "enabled": pm_on},
        }
    }


def job(job_id: str, script: str, phase: str, expr: str, *, paused: bool = False) -> dict:
    return {
        "id": job_id,
        "script": script,
        "workdir": f"/somewhere/state/maa/{phase}",
        "schedule": {"kind": "cron", "expr": expr},
        "enabled": not paused,
        "state": "paused" if paused else "scheduled",
    }


LIVE_JOBS = [
    job("card-am", "maa_plan_card.py", "am", "50 23 * * *"),
    job("card-pm", "maa_plan_card.py", "pm", "50 13 * * *"),
    job("daily-am", "maa_daily.py", "am", "0 0 * * *"),
    job("daily-pm", "maa_daily.py", "pm", "0 14 * * *"),
    job("depot", "maa_depot.py", "", "30 20 * * *"),
]


class SessionScheduleTests(unittest.TestCase):
    def test_validation_accepts_each_half_day_and_rejects_the_rest(self) -> None:
        ok = maa_common.validate_session_schedule(schedule("05:00", "23:59")["session_schedule"])
        self.assertEqual(ok["am"]["time"], "05:00")
        bad = [
            schedule("04:59"),  # 早场不早于 05:00（换日 + Depot）
            schedule("12:00"),  # 早场在上午
            schedule(pm="11:59"),  # 晚场在下午
            schedule("8:00"),  # 格式
            schedule(pm="24:00"),
            {"am": {"time": "08:00"}},  # 少一场
            {**schedule()["session_schedule"], "now": {"time": "09:00"}},
            {"am": {"time": "08:00", "enabled": "yes"}, "pm": {"time": "22:00"}},
            {"am": {"time": "08:00", "extra": 1}, "pm": {"time": "22:00"}},
            "08:00",
        ]
        for value in bad:
            with self.subTest(value=value), self.assertRaises(ValueError):
                raw = value.get("session_schedule", value) if isinstance(value, dict) else value
                maa_common.validate_session_schedule(raw)

    def test_reading_is_lenient_per_session(self) -> None:
        # 一场写坏只退回那一场的默认，另一场照用配置；缺键 = 默认。
        config = {"session_schedule": {"am": {"time": "99:99"}, "pm": {"time": "21:30", "enabled": False}}}
        result = maa_common.session_schedule(config)
        self.assertEqual(result["am"], {"time": "08:00", "enabled": True})
        self.assertEqual(result["pm"], {"time": "21:30", "enabled": False})
        self.assertEqual(maa_common.session_schedule({}), maa_common.DEFAULT_SESSION_SCHEDULE)
        self.assertEqual(maa_common.session_label(config, "pm"), "晚场 21:30")
        self.assertEqual(maa_common.session_label(config, "now"), "手动场")

    def test_disabled_sessions_never_count_as_upcoming(self) -> None:
        at = datetime(2026, 11, 6, 21, 40, tzinfo=BEIJING)
        self.assertEqual(maa_common.session_within(schedule(), 30, at), ("pm", "22:00"))
        self.assertIsNone(maa_common.session_within(schedule(pm_on=False), 30, at))

    def test_the_seed_carries_the_default_schedule(self) -> None:
        seed = json.loads((ROOT / "state" / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(
            maa_common.validate_session_schedule(seed["session_schedule"]),
            maa_common.DEFAULT_SESSION_SCHEDULE,
        )


class ConfiguredGateTests(unittest.TestCase):
    """三条时间闸门都跟着配置走，不再认 08:00 / 22:00。"""

    def test_every_time_gate_follows_the_configured_session(self) -> None:
        config: Any = {**schedule(pm="21:00"), "channel_id": "1"}
        near_new = datetime(2026, 11, 6, 20, 45, tzinfo=BEIJING)
        near_old = datetime(2026, 11, 6, 21, 45, tzinfo=BEIJING)
        gates = {
            "manual": lambda at: maa_action.manual_run_blackout_reason(config, at),
            "copilot": lambda at: maa_action._copilot_blackout_reason(config, at),
            "min_lead": lambda at: maa_action.min_lead_reason(config, at),
        }
        for name, gate in gates.items():
            with self.subTest(gate=name):
                reason = gate(near_new)
                self.assertIsNotNone(reason)
                self.assertIn("晚场 21:00", str(reason))
                self.assertIsNone(gate(near_old))

    def test_a_disabled_session_opens_its_window(self) -> None:
        config: Any = schedule(pm_on=False)
        at = datetime(2026, 11, 6, 21, 50, tzinfo=BEIJING)
        self.assertIsNone(maa_action.manual_run_blackout_reason(config, at))
        self.assertIsNone(maa_action._copilot_blackout_reason(config, at))

    def test_labels_and_card_footer_follow_the_configuration(self) -> None:
        config: Any = schedule("07:30", "21:15", pm_on=False)
        with patch.object(maa_action, "load_config", return_value=config):
            self.assertEqual(maa_action.phase_label("am"), "早场（07:30）")
        with patch.object(maa_plan_card, "load_config", return_value=config):
            self.assertEqual(maa_plan_card.phase_title("pm"), "晚场 21:15")
        footer_config: Any = {**config, "copilot_blackout_minutes": 25}
        self.assertEqual(
            maa_plan_card.copilot_card_footer(footer_config),
            "抄作业与日常互斥 · 07:30 前 25 分钟不接受",
        )

    def test_no_script_still_hard_codes_the_session_hours(self) -> None:
        for path in sorted((ROOT / "scripts").glob("*.py")):
            source = path.read_text(encoding="utf-8")
            with self.subTest(script=path.name):
                self.assertNotIn("(8, 22)", source)
                self.assertNotIn('"早场 08:00"', source)
                self.assertNotIn('"晚场 22:00"', source)


class CronExpressionTests(unittest.TestCase):
    def test_beijing_times_become_hermes_timezone_cron(self) -> None:
        at = datetime(2026, 11, 6, 12, 0, tzinfo=BEIJING)
        self.assertEqual(maa_schedule.cron_expr("08:00", -10, UTC, at), "50 23 * * *")
        self.assertEqual(maa_schedule.cron_expr("22:00", 0, UTC, at), "0 14 * * *")
        self.assertEqual(maa_schedule.cron_expr("08:05", 0, BEIJING, at), "5 8 * * *")

    def test_timezone_resolution_matches_hermes(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            (home / "config.yaml").write_text("model: x\ntimezone: Etc/UTC\n", encoding="utf-8")
            with patch.dict("os.environ", {"HERMES_TIMEZONE": ""}):
                self.assertEqual(str(maa_schedule.hermes_timezone(home)), "Etc/UTC")
            with patch.dict("os.environ", {"HERMES_TIMEZONE": "Asia/Tokyo"}):
                self.assertEqual(str(maa_schedule.hermes_timezone(home)), "Asia/Tokyo")


class CronSyncTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.jobs_path = Path(self._tmp.name) / "jobs.json"
        self.write_jobs(LIVE_JOBS)
        self.calls: list[list[str]] = []
        for item in (
            patch.object(maa_schedule, "jobs_path", lambda: self.jobs_path),
            patch.object(maa_schedule, "hermes_timezone", lambda home=None: UTC),
            patch.object(maa_schedule, "run_hermes", lambda hermes, args: self.calls.append(args)),
        ):
            item.start()
            self.addCleanup(item.stop)

    def write_jobs(self, jobs: list[dict]) -> None:
        self.jobs_path.write_text(json.dumps({"jobs": jobs}), encoding="utf-8")

    def test_jobs_are_found_by_script_and_workdir(self) -> None:
        found = maa_schedule.session_jobs()
        self.assertEqual({key: value["id"] for key, value in found.items()}, {
            ("am", "maa_plan_card.py"): "card-am",
            ("pm", "maa_plan_card.py"): "card-pm",
            ("am", "maa_daily.py"): "daily-am",
            ("pm", "maa_daily.py"): "daily-pm",
        })

    def test_two_candidates_for_one_slot_refuse_instead_of_guessing(self) -> None:
        self.write_jobs([*LIVE_JOBS, job("dup", "maa_daily.py", "am", "0 1 * * *")])
        with self.assertRaisesRegex(RuntimeError, "不知道该改哪个"):
            maa_schedule.session_jobs()
        # 跑完的一次性任务不算候选。
        done = job("old", "maa_daily.py", "am", "0 1 * * *")
        done["state"] = "completed"
        self.write_jobs([*LIVE_JOBS, done])
        self.assertEqual(maa_schedule.session_jobs()[("am", "maa_daily.py")]["id"], "daily-am")

    def test_a_time_change_edits_both_jobs_and_never_unpauses(self) -> None:
        paused = [dict(item, enabled=False, state="paused") for item in LIVE_JOBS]
        self.write_jobs(paused)
        notes = maa_schedule.sync_phase(schedule(pm="21:30"), "pm", "hermes")
        self.assertEqual(self.calls, [
            ["edit", "card-pm", "--schedule", "20 13 * * *"],
            ["edit", "daily-pm", "--schedule", "30 13 * * *"],
        ])
        self.assertEqual(len(notes), 2)

    def test_toggling_pauses_or_resumes_only_that_session(self) -> None:
        maa_schedule.sync_phase(schedule(am_on=False), "am", "hermes", toggle=True)
        self.assertEqual(self.calls, [["pause", "card-am"], ["pause", "daily-am"]])
        self.calls.clear()
        self.write_jobs([dict(item, enabled=False, state="paused") for item in LIVE_JOBS])
        maa_schedule.sync_phase(schedule(), "am", "hermes", toggle=True)
        self.assertEqual(self.calls, [["resume", "card-am"], ["resume", "daily-am"]])

    def test_already_in_sync_is_a_no_op(self) -> None:
        self.assertEqual(maa_schedule.sync_phase(schedule(), "am", "hermes", toggle=True), [])
        self.assertEqual(self.calls, [])
        report = maa_schedule.schedule_report(schedule())
        self.assertTrue(all(
            task["in_sync"] for item in report["sessions"].values() for task in item["cron"].values()
        ))

    def test_a_missing_job_is_an_error_not_a_silent_skip(self) -> None:
        self.write_jobs([item for item in LIVE_JOBS if item["id"] != "daily-pm"])
        with self.assertRaisesRegex(RuntimeError, "找不到晚场日常"):
            maa_schedule.sync_phase(schedule(pm="21:00"), "pm", "hermes")


class ScheduleCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.config_path = root / "config.json"
        self.jobs_path = root / "jobs.json"
        maa_common.atomic_write_json(self.config_path, {"schema_version": 1, "channel_id": "1"})
        self.jobs_path.write_text(json.dumps({"jobs": LIVE_JOBS}), encoding="utf-8")
        self.calls: list[list[str]] = []
        for item in (
            patch.object(maa_common, "CONFIG_PATH", self.config_path),
            patch.object(maa_common, "state_lock", return_value=contextlib.nullcontext()),
            patch.object(maa_action, "load_config", maa_common.load_config),
            patch.object(maa_action, "_hermes_bin", lambda config: "hermes"),
            patch.object(maa_schedule, "jobs_path", lambda: self.jobs_path),
            patch.object(maa_schedule, "hermes_timezone", lambda home=None: UTC),
            patch.object(maa_schedule, "run_hermes", lambda hermes, args: self.calls.append(args)),
        ):
            item.start()
            self.addCleanup(item.stop)

    def run_main(self, *argv: str, source: str = "gui") -> dict:
        out = io.StringIO()
        with patch.dict("os.environ", {"MAA_ACTION_SOURCE": source}), contextlib.redirect_stdout(out):
            maa_action.main(["maa_action.py", *argv])
        return json.loads(out.getvalue())

    def test_set_writes_config_with_who_and_when_then_syncs_cron(self) -> None:
        receipt = self.run_main("schedule", "set", "pm", "21:30")
        self.assertTrue(receipt["ok"], receipt)
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertEqual(config["session_schedule"]["pm"], {"time": "21:30", "enabled": True})
        self.assertEqual(config["config_meta"]["session_schedule"]["source"], "gui")
        self.assertEqual(self.calls[0], ["edit", "card-pm", "--schedule", "20 13 * * *"])
        self.assertEqual(receipt["data"]["sessions"]["pm"]["time"], "21:30")

    def test_bad_time_writes_nothing(self) -> None:
        receipt = self.run_main("schedule", "set", "am", "03:00")
        self.assertFalse(receipt["ok"])
        self.assertNotIn("session_schedule", json.loads(self.config_path.read_text(encoding="utf-8")))
        self.assertEqual(self.calls, [])

    def test_cron_failure_is_reported_after_the_config_is_saved(self) -> None:
        def boom(hermes: str, args: list[str]) -> None:
            raise RuntimeError("hermes cron edit 失败：x")

        with patch.object(maa_schedule, "run_hermes", boom):
            receipt = self.run_main("schedule", "disable", "am")
        self.assertFalse(receipt["ok"])
        self.assertIn("同步 cron", receipt["message"])
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertFalse(config["session_schedule"]["am"]["enabled"])

    def test_schedule_commands_are_not_reachable_from_the_discord_dispatch(self) -> None:
        ok, _ = maa_action.dispatch(["schedule", "show"])
        self.assertFalse(ok)
        receipt = self.run_main("schedule", "show")
        self.assertTrue(receipt["ok"])
        self.assertIn("sessions", receipt["data"])


class DeployKeepsUserEditsTests(unittest.TestCase):
    def test_keys_recorded_in_config_meta_survive_deploy(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            hermes = root / "hermes"
            live = hermes / "state" / "maa"
            live.mkdir(parents=True)
            repo_state = root / "repo" / "state"
            repo_state.mkdir(parents=True)
            for name in ("defaults.json", "plan.json", "last_run.json"):
                (repo_state / name).write_text("{}", encoding="utf-8")
            seed = {"schema_version": 1, **schedule(), "retention_days": 14, "recruit_times": 4}
            (repo_state / "config.json").write_text(json.dumps(seed), encoding="utf-8")
            meta = {"session_schedule": {"source": "gui", "updated_at": "2026-11-06T12:00:00+08:00"}}
            (live / "config.json").write_text(json.dumps({
                "schema_version": 1,
                **schedule(pm="21:00"),
                "retention_days": 7,
                "config_meta": meta,
            }), encoding="utf-8")
            with patch.object(deploy, "ROOT", root / "repo"), patch.object(deploy, "HERMES_HOME", hermes):
                deploy.deploy_state("424242")
            result = json.loads((live / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(result["session_schedule"]["pm"]["time"], "21:00")  # 用户改过：保留
        self.assertEqual(result["retention_days"], 14)  # 没改过：仓库拥有
        self.assertEqual(result["config_meta"], meta)


if __name__ == "__main__":
    unittest.main()
