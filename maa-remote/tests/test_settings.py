"""可从外面改的配置（`maa_settings` + `maa_action config/defaults`，K3 / K5）。"""
from __future__ import annotations

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_action  # noqa: E402
import maa_common  # noqa: E402
import maa_daily  # noqa: E402
import maa_settings  # noqa: E402

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


class SettingsTableTests(unittest.TestCase):
    def test_defaults_match_the_seed(self) -> None:
        seed = json.loads((ROOT / "state" / "config.json").read_text(encoding="utf-8"))
        for item in maa_settings.FIELDS:
            if item.key in seed and item.kind not in ("stage_table", "number_table"):
                with self.subTest(key=item.key):
                    self.assertEqual(item.default, seed[item.key])

    def test_every_default_passes_its_own_validator(self) -> None:
        for item in maa_settings.FIELDS:
            with self.subTest(key=item.key):
                maa_settings.VALIDATORS[item.kind](item, item.default)

    def test_no_downgrade_switch_is_ever_editable(self) -> None:
        # K11 / 不变量 #1 #2 #15：碎石、吃药、助战、忽略练度一个都不许出现。
        forbidden = re.compile(r"stone|support|ignore|medicine(?!_expire_days)")
        for item in maa_settings.FIELDS:
            self.assertIsNone(forbidden.search(item.key), item.key)
        for key in ("stone", "medicine", "maa_bin", "maatools_address", "playcover_app_path",
                    "copilot_raid_switch_task", "activity_stages", "maa_core_version",
                    "channel_id", "schema_version", "config_meta"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                maa_settings.validate(key, "x")

    def test_session_times_only_change_through_schedule(self) -> None:
        with self.assertRaisesRegex(ValueError, "schedule"):
            maa_settings.validate("session_schedule", maa_common.DEFAULT_SESSION_SCHEDULE)

    def test_the_renderer_and_the_validator_share_one_whitelist(self) -> None:
        # 不变量 #51：能存进去的一定能渲染出来。
        self.assertIs(maa_daily.SAFE_MALL_ITEM_RE, maa_common.SAFE_MALL_ITEM_RE)
        self.assertEqual(maa_settings.validate("mall_buy_first", ["招聘许可", "龙门币", "招聘许可"]),
                         ["招聘许可", "龙门币"])
        for bad in (["a\"b"], ["x" * 21], [""], "龙门币", [1]):
            with self.subTest(value=bad), self.assertRaises(ValueError):
                maa_settings.validate("mall_blacklist", bad)

    def test_numbers_are_strict(self) -> None:
        self.assertEqual(maa_settings.validate("recruit_times", 3), 3)
        for bad in (5, -1, True, "3", 2.5):
            with self.subTest(value=bad), self.assertRaises(ValueError):
                maa_settings.validate("recruit_times", bad)
        self.assertEqual(maa_settings.validate("farming_activity_edge", 2), 2.0)
        with self.assertRaises(ValueError):
            maa_settings.validate("farming_activity_edge", float("nan"))
        with self.assertRaises(ValueError):
            maa_settings.validate("report_drops", 1)

    def test_tables_and_weights(self) -> None:
        self.assertEqual(maa_settings.validate("farming_stage_table", {"龙门币": "CE-6"}), {"龙门币": "CE-6"})
        with self.assertRaises(ValueError):
            maa_settings.validate("farming_stage_table", {"龙门币": "CE-6; rm"})
        with self.assertRaises(ValueError):
            maa_settings.validate("farming_weights", {"scarcity": 0, "gap": 0, "efficiency": 0})
        with self.assertRaises(ValueError):
            maa_settings.validate("farming_weights", {"scarcity": 1})
        with self.assertRaises(ValueError):
            maa_settings.validate("game_display_name", "a/b")


class ConfigCommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.config_path = root / "config.json"
        self.defaults_path = root / "defaults.json"
        maa_common.atomic_write_json(self.config_path, {"schema_version": 1, "recruit_times": 4})
        for item in (
            patch.object(maa_common, "CONFIG_PATH", self.config_path),
            patch.object(maa_common, "state_lock", return_value=contextlib.nullcontext()),
            patch.object(maa_action, "state_lock", return_value=contextlib.nullcontext()),
            patch.object(maa_action, "load_config", maa_common.load_config),
            patch.object(maa_action, "DEFAULTS_PATH", self.defaults_path),
        ):
            item.start()
            self.addCleanup(item.stop)

    def run_main(self, *argv: str, source: str = "gui") -> dict:
        out = io.StringIO()
        with patch.dict("os.environ", {"MAA_ACTION_SOURCE": source}), contextlib.redirect_stdout(out):
            maa_action.main(["maa_action.py", *argv])
        return json.loads(out.getvalue())

    def config(self) -> dict:
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def test_get_lists_fields_values_and_who_changed_them(self) -> None:
        self.run_main("config", "set", "recruit_times", "3")
        receipt = self.run_main("config", "get")
        data = receipt["data"]
        self.assertEqual(data["values"]["recruit_times"], 3)
        self.assertEqual(data["values"]["report_drops"], True)  # 缺省给默认
        self.assertEqual(data["meta"]["recruit_times"]["source"], "gui")
        self.assertIn("日常", data["groups"])
        self.assertTrue(all("label" in item for item in data["fields"]))

    def test_patch_is_all_or_nothing(self) -> None:
        receipt = self.run_main("config", "patch", json.dumps({"recruit_times": 2, "mall_blacklist": ["坏\"名"]}))
        self.assertFalse(receipt["ok"])
        self.assertEqual(self.config()["recruit_times"], 4)
        receipt = self.run_main("config", "patch", json.dumps({"recruit_times": 2, "award_mining": True}))
        self.assertTrue(receipt["ok"], receipt)
        self.assertEqual(self.config()["recruit_times"], 2)
        self.assertTrue(self.config()["award_mining"])
        self.assertEqual(set(self.config()["config_meta"]), {"recruit_times", "award_mining"})

    def test_bad_json_and_unknown_keys_write_nothing(self) -> None:
        before = self.config_path.read_text(encoding="utf-8")
        for argv in (("config", "set", "recruit_times", "{"), ("config", "set", "maa_bin", '"/bin/sh"'),
                     ("config", "patch", "[1]")):
            with self.subTest(argv=argv):
                self.assertFalse(self.run_main(*argv)["ok"])
        self.assertEqual(self.config_path.read_text(encoding="utf-8"), before)

    def test_discord_source_is_recorded_when_not_from_the_gui(self) -> None:
        self.run_main("config", "set", "recruit_times", "1", source="")
        self.assertEqual(self.config()["config_meta"]["recruit_times"]["source"], "discord")

    def test_config_commands_are_not_reachable_from_the_discord_dispatch(self) -> None:
        for argv in (["config", "get"], ["config", "set", "recruit_times", "1"], ["defaults", "show"]):
            ok, _ = maa_action.dispatch(argv)
            self.assertFalse(ok)

    def test_defaults_set_stage_and_tasks_keep_the_fixed_policy(self) -> None:
        receipt = self.run_main("defaults", "set", "stage", "CE-6")
        self.assertTrue(receipt["ok"], receipt)
        receipt = self.run_main("defaults", "set", "task", "mall", "off")
        self.assertTrue(receipt["ok"], receipt)
        written = json.loads(self.defaults_path.read_text(encoding="utf-8"))
        self.assertEqual(written["stage"], "CE-6")
        self.assertFalse(written["tasks"]["mall"])
        self.assertEqual((written["medicine"], written["stone"]), ("expiring", 0))
        self.assertEqual(written["source"], "gui")
        self.assertEqual(receipt["data"]["tasks"]["mall"], False)
        # 默认值进 effective_plan，药和碎石照旧强制。
        with patch.object(maa_common, "DEFAULTS_PATH", self.defaults_path), \
                patch.object(maa_common, "PLAN_PATH", Path(self._tmp.name) / "plan.json"):
            plan = maa_common.effective_plan(phase="am")
        self.assertEqual(plan["stage"], "CE-6")
        self.assertEqual(plan.get("stone"), 0)

    def test_defaults_set_rejects_everything_else(self) -> None:
        with patch.object(maa_action, "_activity_output_allows", return_value=False):
            for argv in (("defaults", "set", "stage", "rm -rf"), ("defaults", "set", "task", "stone", "on"),
                         ("defaults", "set", "medicine", "all"), ("defaults", "set", "task", "mall", "yes")):
                with self.subTest(argv=argv):
                    self.assertFalse(self.run_main(*argv)["ok"])
        self.assertFalse(self.defaults_path.exists())


if __name__ == "__main__":
    unittest.main()
