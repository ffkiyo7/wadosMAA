"""上游更新只有一份（`maa_upstream`，K17–K20 / 不变量 #60）：07:50 计划卡和 Wado's MAA 共用。"""
from __future__ import annotations

import contextlib
import json
import os
import re
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_action  # noqa: E402
import maa_common  # noqa: E402
import maa_daily  # noqa: E402
import maa_plan_card  # noqa: E402
import maa_upstream  # noqa: E402
from _helpers import BEIJING  # noqa: E402

_DEVICE_GUARDS: list = []
_MODULE_PATCHES: list = []

BREW = "/opt/homebrew/bin/brew"
CLI_TOML = """[core]
channel = "Beta"

[resource]
# 注释照抄线上那份
auto_update = false
warn_on_update_failure = false
backend = "git"  # 只认 git
"""
SHA_A = "a" * 40
SHA_B = "b" * 40


def setUpModule() -> None:
    _DEVICE_GUARDS[:] = _isolation.guard_devices()
    _MODULE_PATCHES[:] = _helpers.start_module_patches()


def tearDownModule() -> None:
    _helpers.stop_patches(_MODULE_PATCHES)
    for item in reversed(_DEVICE_GUARDS):
        item.stop()
    _isolation.assert_shared_home_clean()


class UpstreamTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.config_path = self.root / "config.json"
        maa_common.atomic_write_json(self.config_path, {"schema_version": 1})
        self.maa_config = self.root / "maa-cli"
        self.maa_config.mkdir()
        (self.maa_config / "cli.toml").write_text(CLI_TOML, encoding="utf-8")
        self.data_dir = self.root / "com.loong.maa"
        self.set_head(SHA_A)
        self.now = datetime(2026, 11, 6, 7, 50, tzinfo=BEIJING)
        self.lock_free = True
        self.holder: dict | None = None
        self.versions = ["maa-cli v0.7.5\nMaaCore v6.21.3\n"]
        self.cli_outdated = False
        self.fail: set[str] = set()
        self.calls: list[list[str]] = []
        self.envs: list[dict] = []
        self.merge = MagicMock()

        @contextlib.contextmanager
        def fake_lock(**_kwargs):
            yield self.lock_free

        for item in (
            patch.object(maa_upstream, "UPSTREAM_PATH", self.root / "upstream.json"),
            patch.object(maa_upstream, "CONFIG_PATH", self.config_path),
            patch.object(maa_upstream, "MAA_DATA_DIR", self.data_dir),
            patch.object(maa_upstream, "MAA_CACHE_DIR", self.root / "cache"),
            patch.object(maa_upstream, "run_lock", fake_lock),
            patch.object(maa_upstream, "run_lock_holder", lambda: self.holder),
            patch.object(maa_upstream, "merge_last_run", self.merge),
            patch.object(maa_upstream, "now_beijing", lambda: self.now),
            patch.object(maa_upstream.shutil, "which", return_value=BREW),
            patch.object(maa_upstream.subprocess, "run", side_effect=self.fake_run),
        ):
            item.start()
            self.addCleanup(item.stop)
        self.config: Any = {"maa_bin": "/maa", "maa_config_dir": str(self.maa_config),
                       "resource_update_timeout": 30}

    def set_head(self, sha: str) -> None:
        git = self.data_dir / "MaaResource" / ".git"
        (git / "refs" / "heads").mkdir(parents=True, exist_ok=True)
        (git / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
        (git / "refs" / "heads" / "main").write_text(sha + "\n", encoding="utf-8")

    def fake_run(self, argv, **kwargs):
        self.calls.append(list(argv))
        self.envs.append(kwargs.get("env") or {})
        if argv[:2] == ["/maa", "version"]:
            text = self.versions[0] if len(self.versions) == 1 else self.versions.pop(0)
            return SimpleNamespace(returncode=0, stdout=text, stderr="")
        if argv[:2] == [BREW, "outdated"]:
            self.assertIn("--json=v2", argv)
            if "brew" in self.fail:
                return SimpleNamespace(returncode=1, stdout="", stderr="Error: tap broken")
            if self.cli_outdated:
                # brew 的真实行为：点名查的 formula 有新版时退出码是 1（K19）。
                payload = {"formulae": [{"name": "maa-cli", "installed_versions": ["0.7.5"],
                                         "current_version": "0.7.8"}], "casks": []}
                return SimpleNamespace(returncode=1, stdout=json.dumps(payload), stderr="")
            return SimpleNamespace(returncode=0, stdout='{"formulae": [], "casks": []}', stderr="")
        if argv[:2] == [BREW, "upgrade"]:
            return SimpleNamespace(returncode=0, stdout="upgraded maa-cli", stderr="")
        if argv[:2] == ["/maa", "update"]:
            if "core" in self.fail:
                return SimpleNamespace(returncode=1, stdout="", stderr="network down")
            return SimpleNamespace(returncode=0, stdout="updated maa-core", stderr="")
        if argv[:2] == ["/maa", "hot-update"]:
            if "hot" in self.fail:
                return SimpleNamespace(returncode=1, stdout="", stderr="missing resource")
            self.set_head(SHA_B)
            return SimpleNamespace(returncode=0, stdout="updated hot resources", stderr="")
        raise AssertionError(argv)

    def record(self) -> dict:
        return json.loads((self.root / "upstream.json").read_text(encoding="utf-8"))


class RunUpdateTests(UpstreamTestCase):
    def test_an_outdated_maa_cli_is_upgraded_although_brew_exits_1(self) -> None:
        self.cli_outdated = True
        result = maa_upstream.run_update(self.config, "plan_card")
        self.assertTrue(result["ok"], result)
        self.assertTrue(result["changed"])
        self.assertIn([BREW, "upgrade", "--formula", maa_upstream.DEFAULT_MAA_CLI_FORMULA], self.calls)

    def test_an_unreadable_brew_answer_fails_only_the_cli_step(self) -> None:
        self.fail.add("brew")
        result = maa_upstream.run_update(self.config, "plan_card")
        self.assertFalse(result["ok"])
        self.assertFalse(result["steps"]["cli"]["ok"])
        self.assertTrue(result["steps"]["core"]["ok"])
        self.assertIn("tap broken", result["detail"])

    def test_a_core_upgrade_is_recorded_step_by_step_with_proxy_and_path(self) -> None:
        self.versions = ["maa-cli v0.7.5\nMaaCore v6.21.3\n", "maa-cli v0.7.5\nMaaCore v6.21.4\n"]
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://127.0.0.1:7890", "PATH": "/usr/bin"}):
            result = maa_upstream.run_update(self.config | {"maa_disable_proxy": True}, "gui")
        self.assertTrue(result["ok"], result)
        self.assertIn("MaaCore v6.21.3 → v6.21.4", result["summary"])
        record = self.record()
        self.assertEqual(record["schema_version"], maa_upstream.UPSTREAM_SCHEMA_VERSION)
        self.assertEqual((record["state"], record["source"]), ("done", "gui"))
        self.assertTrue(record["core_changed"] and record["hot_ok"])
        self.assertEqual((record["resource_head_before"], record["resource_head_after"]), (SHA_A, SHA_B))
        self.assertEqual(record["last_success_at"], self.now.isoformat())
        self.assertEqual(json.loads(self.config_path.read_text())["maa_core_version"], "v6.21.4")
        self.assertEqual(self.merge.call_args.args[0]["resource_update_status"], "ok")
        maa_envs = [env for call, env in zip(self.calls, self.envs) if call[0] == "/maa"]
        self.assertTrue(all("HTTPS_PROXY" in env for env in maa_envs))
        self.assertTrue(all("/opt/homebrew/bin" in env["PATH"].split(os.pathsep) for env in self.envs))

    def test_a_failed_core_update_never_advances_the_overlay(self) -> None:
        maa_upstream._write_upstream({"state": "done", "last_success_at": "2026-11-05T07:55:00+08:00"})
        self.fail.add("core")
        result = maa_upstream.run_update(self.config, "plan_card")
        self.assertEqual(result["status"], "failed")
        self.assertFalse(any(call[:2] == ["/maa", "hot-update"] for call in self.calls))
        self.assertEqual(self.record()["last_success_at"], "2026-11-05T07:55:00+08:00")
        self.assertEqual(self.merge.call_args.args[0]["resource_update_status"], "failed")

    def test_a_busy_lock_skips_without_touching_maa_or_hiding_the_last_result(self) -> None:
        maa_upstream._write_upstream({"state": "done", "core_changed": True, "hot_ok": False})
        self.lock_free = False
        self.holder = {"holder": "daily", "detail": "早场", "since": self.now.isoformat()}
        result = maa_upstream.run_update(self.config, "plan_card")
        self.assertEqual(result["status"], "skipped")
        self.assertIn("日常", result["summary"])
        self.assertEqual(self.calls, [])
        record = self.record()
        self.assertEqual(record["state"], "done")
        self.assertIn("日常", record["last_skip"]["detail"])
        self.assertTrue(maa_upstream.inconsistency(record))


class StatusTests(UpstreamTestCase):
    def test_pinned_cli_toml_is_read_without_tomllib(self) -> None:
        self.assertEqual(maa_upstream.pinned_problems(self.config), [])
        (self.maa_config / "cli.toml").write_text(CLI_TOML.replace('"Beta"', '"Stable"'))
        self.assertIn("channel", maa_upstream.pinned_problems(self.config)[0])
        (self.maa_config / "cli.toml").unlink()
        self.assertIn("找不到", maa_upstream.pinned_problems(self.config)[0])

    def test_hard_block_only_for_changed_source_or_half_updates(self) -> None:
        self.assertEqual(maa_upstream.hard_block(self.config), "")
        maa_upstream._write_upstream({"state": "done", "core_changed": True, "hot_ok": False,
                                      "core_after": "v6.21.4"})
        self.assertIn("MaaResource 却没跟上", maa_upstream.hard_block(self.config))
        maa_upstream._write_upstream({"state": "running"})
        self.assertIn("断了", maa_upstream.hard_block(self.config))
        self.holder = {"holder": "update"}
        self.assertEqual(maa_upstream.hard_block(self.config), "")
        (self.maa_config / "cli.toml").write_text(CLI_TOML.replace('"git"', '"libgit2"'))
        self.assertIn("deploy.py", maa_upstream.hard_block(self.config))
        # 失败、不新鲜都不挡跑（方案 B 的降级继续）。
        (self.maa_config / "cli.toml").write_text(CLI_TOML)
        maa_upstream._write_upstream({"state": "done", "ok": False, "core_changed": False})
        self.assertEqual(maa_upstream.hard_block(self.config), "")

    def test_fresh_means_this_game_day_after_04_00(self) -> None:
        self.now = datetime(2026, 11, 6, 15, 0, tzinfo=BEIJING)
        maa_upstream._write_upstream({"state": "done", "last_success_at": "2026-11-06T03:59:00+08:00"})
        data = maa_upstream.status(self.config, at=self.now)
        self.assertFalse(data["fresh"])
        self.assertEqual(data["verdict"], "stale")
        maa_upstream._write_upstream({"state": "done", "last_success_at": "2026-11-06T04:01:00+08:00"})
        data = maa_upstream.status(self.config, at=self.now)
        self.assertTrue(data["fresh"])
        self.assertEqual(data["verdict"], "ok")
        self.assertEqual(data["versions"]["maa_resource_head"], SHA_A)
        self.assertEqual(data["versions"]["maa_core"], "v6.21.3")
        # 凌晨 03:00 还算前一个游戏日。
        early = datetime(2026, 11, 7, 3, 0, tzinfo=BEIJING)
        self.assertEqual(maa_upstream.game_day_start(early), datetime(2026, 11, 6, 4, 0, tzinfo=BEIJING))

    def test_status_is_offline_by_default(self) -> None:
        maa_upstream.status(self.config, at=self.now)
        self.assertEqual(self.calls, [["/maa", "version"]])

    def test_resource_head_reads_packed_refs(self) -> None:
        git = self.data_dir / "MaaResource" / ".git"
        (git / "refs" / "heads" / "main").unlink()
        (git / "packed-refs").write_text(f"# pack-refs\n{SHA_B} refs/heads/main\n")
        self.assertEqual(maa_upstream.resource_head(), SHA_B)

    def test_gate_refuses_the_dev_copy_and_the_session_blackout(self) -> None:
        with patch.object(maa_upstream, "HERMES_HOME", self.root / "devhome"):
            self.assertIn("开发副本", maa_upstream.update_gate({}, self.now))
        with patch.object(maa_upstream, "HERMES_HOME", maa_upstream.LIVE_HERMES_HOME):
            self.assertIn("不足 30 分钟", maa_upstream.update_gate({}, self.now))
            self.assertEqual(maa_upstream.update_gate({}, self.now.replace(hour=14)), "")


class ProxyEnvTests(unittest.TestCase):
    def test_upstream_proxy_fills_in_only_for_update_calls(self) -> None:
        config: Any = {"upstream_proxy": "http://127.0.0.1:7890", "maa_disable_proxy": True}
        clean = {k: v for k, v in os.environ.items() if k not in maa_common.PROXY_ENV_KEYS}
        with patch.dict(os.environ, clean, clear=True):
            self.assertEqual(maa_common.maa_subprocess_env(config, keep_proxy=True)["HTTPS_PROXY"],
                             "http://127.0.0.1:7890")
            run_env = maa_common.maa_subprocess_env(config)
        self.assertFalse(any(key in run_env for key in maa_common.PROXY_ENV_KEYS))  # 不变量 #12


class SingleImplementationTests(unittest.TestCase):
    def test_only_maa_upstream_runs_the_update_commands(self) -> None:
        pattern = re.compile(r"""["'](hot-update|upgrade)["']|\[\s*["']update["']\s*,\s*["']--batch""")
        for script in sorted((ROOT / "scripts").glob("*.py")):
            if script.name == "maa_upstream.py":
                continue
            with self.subTest(script=script.name):
                self.assertIsNone(pattern.search(script.read_text(encoding="utf-8")))

    def test_daily_checks_upstream_before_launching_the_game(self) -> None:
        source = (ROOT / "scripts" / "maa_daily.py").read_text(encoding="utf-8")
        body = source[source.index("def execute("):]
        self.assertLess(body.index("upstream_hard_block(config)"), body.index("launch_game(config)"))
        self.assertGreater(body.index("upstream_hard_block(config)"), body.index("with run_lock("))

    def test_daily_reports_a_block_and_never_stays_silent(self) -> None:
        with patch.object(maa_daily, "merge_last_run") as merge, \
                patch.object(maa_daily, "discord_request") as request:
            maa_daily.report_upstream_block("t", "1", "am", "源被改了",
                                            datetime(2026, 11, 6, 8, 0, tzinfo=BEIJING))
        self.assertEqual(merge.call_args.args[0]["status"], "failed")
        self.assertIn("源被改了", request.call_args.args[3]["embeds"][0]["description"])


class PlanCardAndActionTests(unittest.TestCase):
    def test_plan_card_alerts_only_on_failure(self) -> None:
        for status, posts in (("failed", 1), ("skipped", 0), ("ok", 0)):
            with self.subTest(status=status), patch.object(
                maa_upstream, "run_update", return_value={"status": status, "detail": "x"}
            ) as run, patch.object(maa_plan_card, "discord_request") as request:
                maa_plan_card.check_and_update_upstream("t", "123", {})
            self.assertEqual(run.call_args.args[1], "plan_card")
            self.assertEqual(request.call_count, posts)

    def test_gui_update_refuses_in_the_dev_copy_without_spawning(self) -> None:
        with patch.object(maa_action, "load_config", return_value={}), patch.object(
            maa_upstream, "HERMES_HOME", Path("/nonexistent/devhome")
        ), patch.object(maa_action.subprocess, "Popen") as popen:
            ok, message, data = maa_action.upstream_update()
        self.assertFalse(ok)
        self.assertIn("开发副本", message)
        self.assertFalse(data["started"])
        popen.assert_not_called()

    def test_upstream_commands_are_gui_only(self) -> None:
        for argv in (["upstream", "status"], ["upstream", "update"]):
            self.assertFalse(maa_action.dispatch(argv)[0])
        self.assertIsNone(maa_action.dispatch_gui(["upstream", "status", "--bogus"]))


if __name__ == "__main__":
    unittest.main()
