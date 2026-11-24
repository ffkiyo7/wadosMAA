"""Phase 4 S4-1：iOS 无线自动续签的状态机、守卫、`main` 锁定、有效期核验与告警（全部离线）。"""

from __future__ import annotations

import json
import plistlib
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import maa_api  # noqa: E402
import maa_common  # noqa: E402
import maa_daemon  # noqa: E402
import maa_ios_resign as resign  # noqa: E402
from maa_common import BEIJING  # noqa: E402

NOW = datetime(2026, 11, 28, 22, 0, tzinfo=BEIJING)
APP_ID = "DY725KK25V." + resign.BUNDLE_ID
UDID = "00008150-001C28941138401C"


def tearDownModule() -> None:
    _isolation.assert_shared_home_clean()


def profile_xml(uuid: str, expires: datetime, *, app_id: str = APP_ID, team: str = "TEAM123") -> str:
    doc = {
        "TeamIdentifier": [team],
        "UUID": uuid,
        "CreationDate": (expires - timedelta(days=7)).astimezone(timezone.utc).replace(tzinfo=None),
        "ExpirationDate": expires.astimezone(timezone.utc).replace(tzinfo=None),
        "Entitlements": {"application-identifier": app_id},
    }
    return plistlib.dumps(doc).decode("utf-8")


class FakeRunner:
    """按 argv 分派的假外部命令。`profiles` 把文件名映射到描述文件 XML。"""

    def __init__(self, case: ResignTestCase) -> None:
        self.case = case
        self.calls: list[list[str]] = []
        self.profiles: dict[str, str] = {}
        self.branch = "main"
        self.dirty = ""
        self.build_code = 0
        self.build_output = "** BUILD SUCCEEDED **"
        self.new_profile: str | None = None
        self.install_code = 0

    def __call__(self, argv: list[str], *, timeout: float, cwd: Path | None = None) -> tuple[int, str]:
        self.calls.append(list(argv))
        if argv[:3] == ["/usr/bin/security", "cms", "-D"]:
            name = Path(argv[-1]).name
            if name == "embedded.mobileprovision":
                return (0, self.new_profile) if self.new_profile else (1, "")
            xml = self.profiles.get(name)
            return (0, xml) if xml else (1, "")
        if argv[0] == "/usr/bin/git" and "rev-parse" in argv:
            return 0, self.branch + "\n"
        if argv[0] == "/usr/bin/git" and "status" in argv:
            return 0, self.dirty
        if argv[0] == "/usr/bin/xcodebuild":
            if self.build_code == 0 and self.new_profile:
                app = self.case.derived / resign.APP_RELATIVE
                app.mkdir(parents=True, exist_ok=True)
                (app / "embedded.mobileprovision").write_text("x", encoding="utf-8")
            return self.build_code, self.build_output
        if argv[:4] == ["/usr/bin/xcrun", "devicectl", "device", "install"]:
            return self.install_code, "App installed" if self.install_code == 0 else "device locked"
        raise AssertionError(f"未预期的命令：{argv}")

    def ran(self, head: str) -> bool:
        return any(call[0] == head for call in self.calls)


class ResignTestCase(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory(prefix="ios-resign-")
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.daemon_dir = base / "daemon"
        self.daemon_dir.mkdir()
        self.worktree = base / "deploy"
        (self.worktree / "ios" / "WadosMAAiOS.xcodeproj").mkdir(parents=True)
        self.derived = base / "dd"
        self.profiles_dir = base / "profiles"
        self.profiles_dir.mkdir()
        self.runner = FakeRunner(self)
        self.notes: list[tuple[str, str, str]] = []
        self.run_locked = False
        self.lan_ok = True
        self.device_ok = True
        self.clock_now = NOW
        self.write_config(UDID)

    def write_config(self, udid: str, **extra: Any) -> None:
        maa_common.atomic_write_json(
            self.daemon_dir / "daemon.json",
            {"ios_device_udid": udid, "ios_device_lan_ip": "192.168.50.201", **extra},
        )

    def write_state(self, **fields: Any) -> None:
        maa_common.atomic_write_json(self.daemon_dir / "resign.json", fields)

    def state(self) -> dict[str, Any]:
        return json.loads((self.daemon_dir / "resign.json").read_text(encoding="utf-8"))

    def add_cached_profile(self, name: str, expires: datetime, *, app_id: str = APP_ID) -> Path:
        path = self.profiles_dir / f"{name}.mobileprovision"
        path.write_text("cms", encoding="utf-8")
        self.runner.profiles[path.name] = profile_xml(name, expires, app_id=app_id)
        return path

    def env(self) -> resign.Env:
        def notifier(title: str, body: str, *, level: str, url: str, notification_id: str) -> bool:
            self.assertEqual(notification_id, "ios-resign")
            self.assertEqual(url, "wadosmaa://resign")
            self.notes.append((title, body, level))
            return True

        return resign.Env(
            state_path=self.daemon_dir / "resign.json",
            lock_path=self.daemon_dir / "resign.lock",
            config_path=self.daemon_dir / "daemon.json",
            log_dir=self.daemon_dir / "logs",
            worktree=self.worktree,
            derived_data=self.derived,
            profiles_dir=self.profiles_dir,
            runner=self.runner,
            clock=lambda: self.clock_now,
            run_lock_probe=lambda: self.run_locked,
            notifier=notifier,
            lan_probe=lambda _ip: self.lan_ok,
            device_probe=lambda _udid: self.device_ok,
        )

    def signed_days_ago(self, days: float, *, valid_days: float = 7) -> None:
        signed = NOW - timedelta(days=days)
        self.write_state(
            last_signed_at=signed.isoformat(),
            expiration_date=(signed + timedelta(days=valid_days)).isoformat(),
        )


class DueTests(ResignTestCase):
    def test_due_thresholds(self) -> None:
        def state(days: float) -> dict[str, str]:
            signed = NOW - timedelta(days=days)
            return {"last_signed_at": signed.isoformat(), "expiration_date": (signed + timedelta(days=7)).isoformat()}

        self.assertEqual(resign.due_reason({}, NOW), "还没有签名记录")
        self.assertEqual(resign.due_reason(state(4.9), NOW), "")
        self.assertEqual(resign.due_reason(state(5), NOW), "离到期不足 48 小时")
        # 只记了签名时间：按满 5 天算
        self.assertEqual(
            resign.due_reason({"last_signed_at": (NOW - timedelta(hours=120)).isoformat()}, NOW),
            "距上次签名满 5 天",
        )
        # 描述文件只剩 1 天：哪怕刚签过也到期
        short = {"last_signed_at": NOW.isoformat(), "expiration_date": (NOW + timedelta(hours=47)).isoformat()}
        self.assertEqual(resign.due_reason(short, NOW), "离到期不足 48 小时")

    def test_alert_threshold_is_day_six_and_a_half(self) -> None:
        signed = NOW - timedelta(hours=155)
        self.assertFalse(resign.alert_due({"last_signed_at": signed.isoformat()}, NOW))
        signed = NOW - timedelta(hours=156)
        self.assertTrue(resign.alert_due({"last_signed_at": signed.isoformat()}, NOW))
        self.assertTrue(resign.alert_due({"expiration_date": (NOW + timedelta(hours=11)).isoformat()}, NOW))

    def test_public_status(self) -> None:
        fresh = {"last_signed_at": NOW.isoformat(), "expiration_date": (NOW + timedelta(days=7)).isoformat()}
        self.assertEqual(resign.public_status(fresh, NOW, running=False), "ok")
        self.assertEqual(resign.public_status(fresh, NOW, running=True), "running")
        self.assertEqual(resign.public_status({}, NOW, running=False), "due")
        self.assertEqual(resign.public_status({"last_result": "failed"}, NOW, running=False), "failed")
        self.assertEqual(resign.public_status({"last_result": "skipped"}, NOW, running=False), "due")

    def test_device_online_parses_devicectl(self) -> None:
        def doc(tunnel: str) -> dict[str, Any]:
            return {
                "result": {
                    "devices": [
                        {
                            "identifier": "FE667877-5229-5F85-9E01-F975FE983491",
                            "hardwareProperties": {"udid": UDID},
                            "connectionProperties": {"pairingState": "paired", "tunnelState": tunnel},
                        }
                    ]
                }
            }

        self.assertTrue(resign.device_online(doc("disconnected"), UDID))
        self.assertTrue(resign.device_online(doc("connected"), UDID))
        self.assertFalse(resign.device_online(doc("unavailable"), UDID))
        self.assertFalse(resign.device_online(doc("connected"), "other"))
        self.assertFalse(resign.device_online({}, UDID))

    def test_bootstrap_from_cached_profile(self) -> None:
        self.add_cached_profile("old", NOW - timedelta(days=3))
        self.add_cached_profile("new", NOW + timedelta(days=3))
        self.add_cached_profile("probe", NOW + timedelta(days=6), app_id="DY725KK25V.io.github.ffkiyo7.WadosP0Probe")
        state = resign.bootstrap_state(
            self.daemon_dir / "resign.json", now=NOW, profiles_dir=self.profiles_dir, runner=self.runner
        )
        self.assertEqual(state["profile_uuid"], "new")
        self.assertEqual(resign._parse_time(state["expiration_date"]), NOW + timedelta(days=3))
        self.assertEqual(state["status"], "ok")


class GuardTests(ResignTestCase):
    def test_not_configured_without_udid(self) -> None:
        self.write_config("")
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "not_configured")
        self.assertFalse(self.runner.calls)

    def test_auto_not_due_does_nothing(self) -> None:
        self.signed_days_ago(1)
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "not_due")
        self.assertFalse(self.runner.ran("/usr/bin/xcodebuild"))

    def test_auto_guards_skip_quietly(self) -> None:
        for setup, detail in (
            (lambda: None, "App 正在使用"),
            (lambda: setattr(self, "run_locked", True), "正在跑游戏"),
            (lambda: setattr(self, "lan_ok", False), "手机不在局域网"),
        ):
            with self.subTest(detail=detail):
                self.run_locked = False
                self.lan_ok = True
                self.signed_days_ago(5.5)
                setup()
                res = resign.perform(self.env(), trigger="auto", app_active=detail == "App 正在使用")
                self.assertEqual(res["code"], "skipped")
                self.assertEqual(self.state()["last_probe_detail"], detail)
                self.assertEqual(self.state()["status"], "due")
                self.assertFalse(self.runner.ran("/usr/bin/xcodebuild"))
        self.assertEqual(self.notes, [])

    def test_alert_once_a_day_after_day_six_and_a_half(self) -> None:
        self.signed_days_ago(6.6)
        self.lan_ok = False
        resign.perform(self.env(), trigger="auto")
        resign.perform(self.env(), trigger="auto")
        self.assertEqual([n[2] for n in self.notes], ["timeSensitive"])
        self.clock_now = NOW + timedelta(days=1)
        resign.perform(self.env(), trigger="auto")
        self.assertEqual(len(self.notes), 2)

    def test_device_offline_is_transient(self) -> None:
        self.signed_days_ago(5.5)
        self.device_ok = False
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "device_offline")
        st = self.state()
        self.assertEqual(st["last_result"], "skipped")
        self.assertEqual(st["status"], "due")
        self.assertEqual(self.notes, [])

    def test_manual_refused_while_game_runs(self) -> None:
        self.signed_days_ago(1)
        self.run_locked = True
        res = resign.perform(self.env(), trigger="ios")
        self.assertEqual(res["code"], "run_locked")

    def test_lock_prevents_concurrent_runs(self) -> None:
        self.signed_days_ago(5.5)
        holder = resign._try_lock(self.daemon_dir / "resign.lock")
        self.addCleanup(holder.close)
        self.assertTrue(resign.is_locked(self.daemon_dir / "resign.lock"))
        res = resign.perform(self.env(), trigger="ios")
        self.assertEqual(res["code"], "running")

    def test_worktree_must_be_clean_main(self) -> None:
        self.signed_days_ago(5.5)
        self.runner.branch = "dev"
        res = resign.perform(self.env(), trigger="ios")
        self.assertEqual(res["code"], "worktree_invalid")
        self.assertIn("main", res["message"])
        self.assertFalse(self.runner.ran("/usr/bin/xcodebuild"))
        self.assertEqual(self.notes[-1][2], "timeSensitive")

        self.runner.branch = "main"
        self.runner.dirty = " M ios/WadosMAAiOS/App/WadosMAAApp.swift\n"
        res = resign.perform(self.env(), trigger="ios")
        self.assertEqual(res["code"], "worktree_invalid")

    def test_build_source_is_locked_to_deploy_worktree(self) -> None:
        self.assertEqual(resign.DEPLOY_WORKTREE.name, "wados-maa-deploy")
        self.assertEqual(resign.PROJECT_PATH, resign.DEPLOY_WORKTREE / "ios" / "WadosMAAiOS.xcodeproj")


class BuildTests(ResignTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.signed_days_ago(5.5)
        self.old = self.add_cached_profile("old-uuid", NOW + timedelta(days=1.5))

    def test_success_moves_old_profile_installs_and_notifies(self) -> None:
        new_exp = NOW + timedelta(days=7)
        self.runner.new_profile = profile_xml("new-uuid", new_exp)
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "ok", res)

        self.assertFalse(self.old.exists(), "旧描述文件要先挪走再构建")
        build = next(c for c in self.runner.calls if c[0] == "/usr/bin/xcodebuild")
        self.assertIn("-allowProvisioningUpdates", build)
        self.assertIn("DEVELOPMENT_TEAM=TEAM123", build, "工程里没写团队，要从描述文件带过去")
        self.assertEqual(build[build.index("-project") + 1], str(self.worktree / "ios" / "WadosMAAiOS.xcodeproj"))
        install = next(c for c in self.runner.calls if c[:2] == ["/usr/bin/xcrun", "devicectl"])
        self.assertEqual(install[install.index("--device") + 1], UDID)

        st = self.state()
        self.assertEqual(st["status"], "ok")
        self.assertEqual(st["profile_uuid"], "new-uuid")
        self.assertEqual(resign._parse_time(st["expiration_date"]), new_exp)
        self.assertEqual(resign._parse_time(st["last_signed_at"]), NOW)
        self.assertEqual(self.notes, [("iOS App 已自动续签", "有效期至 12-05 22:00", "passive")])

    def test_team_from_config_wins(self) -> None:
        self.write_config(UDID, ios_team_id="CFGTEAM")
        self.runner.new_profile = profile_xml("new-uuid", NOW + timedelta(days=7))
        resign.perform(self.env(), trigger="cli")
        build = next(c for c in self.runner.calls if c[0] == "/usr/bin/xcodebuild")
        self.assertIn("DEVELOPMENT_TEAM=CFGTEAM", build)

    def test_no_team_anywhere_fails_without_touching_profiles(self) -> None:
        self.old.unlink()
        self.runner.calls.clear()
        res = resign.perform(self.env(), trigger="cli", force=True)
        self.assertEqual(res["code"], "no_team")
        self.assertFalse(self.runner.ran("/usr/bin/xcodebuild"))

    def test_expiration_must_move_later(self) -> None:
        self.runner.new_profile = profile_xml("same", NOW + timedelta(days=1.5))
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "not_extended")
        self.assertTrue(self.old.exists(), "失败时旧描述文件要挪回")
        self.assertFalse(any(c[:2] == ["/usr/bin/xcrun", "devicectl"] for c in self.runner.calls))
        st = self.state()
        self.assertEqual(st["status"], "failed")
        self.assertEqual(resign._parse_time(st["last_signed_at"]), NOW - timedelta(days=5.5))
        self.assertEqual(self.notes[-1][2], "timeSensitive")

    def test_account_failure_alerts(self) -> None:
        self.runner.build_code = 65
        self.runner.build_output = "error: No Accounts: Add a new account in Accounts settings."
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "account_failed")
        self.assertTrue(self.old.exists())
        self.assertEqual(self.notes[-1][2], "timeSensitive")

    def test_plain_build_failure_is_quiet_before_day_six_and_a_half(self) -> None:
        self.runner.build_code = 65
        self.runner.build_output = "error: compile failed"
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "build_failed")
        self.assertEqual(self.notes, [])
        self.assertIn("compile failed", (self.daemon_dir / "logs").joinpath(
            Path(self.state()["log_path"]).name).read_text(encoding="utf-8"))

    def test_install_failure_keeps_old_record(self) -> None:
        self.runner.new_profile = profile_xml("new-uuid", NOW + timedelta(days=7))
        self.runner.install_code = 1
        res = resign.perform(self.env(), trigger="auto")
        self.assertEqual(res["code"], "install_failed")
        st = self.state()
        self.assertEqual(st["last_result"], "skipped")
        self.assertEqual(st["status"], "due")
        self.assertEqual(resign._parse_time(st["last_signed_at"]), NOW - timedelta(days=5.5))
        self.assertEqual(self.notes, [])


class EntryTests(ResignTestCase):
    def test_request_resign(self) -> None:
        spawned: list[list[str]] = []

        def call(if_due: bool, trigger: str = "shortcut") -> tuple[int, dict[str, Any]]:
            return resign.request_resign(
                if_due=if_due,
                trigger=trigger,
                daemon_dir=self.daemon_dir,
                scripts_dir=Path("/scripts"),
                python_bin="/py",
                now=NOW,
                spawner=spawned.append,
                run_lock_probe=lambda: self.run_locked,
            )

        self.signed_days_ago(1)
        st, res = call(True)
        self.assertEqual((st, res["code"], res["ok"]), (200, "not_due", True))
        self.assertEqual(spawned, [])

        st, res = call(False, "ios")
        self.assertEqual((st, res["code"]), (202, "started"))
        self.assertEqual(spawned[-1], ["/py", "/scripts/maa_ios_resign.py", "run", "--trigger", "ios"])

        self.signed_days_ago(5.5)
        st, res = call(True)
        self.assertEqual((st, res["code"]), (202, "started"))
        self.assertEqual(spawned[-1][-1], "shortcut")

        self.run_locked = True
        st, res = call(True)
        self.assertEqual((st, res["code"]), (409, "run_locked"))

        self.write_config("")
        st, res = call(True)
        self.assertEqual((st, res["code"]), (501, "not_configured"))

    def test_daemon_monitor_every_25_minutes(self) -> None:
        spawned: list[list[str]] = []

        class Proc:
            def poll(self) -> int:
                return 0

        def spawner(argv: list[str]) -> Proc:
            spawned.append(argv)
            return Proc()

        active = {"value": False}
        mon = maa_daemon.ResignMonitor(
            scripts_dir=Path("/scripts"),
            python_bin="/py",
            daemon_dir=self.daemon_dir,
            app_active=lambda: active["value"],
            spawner=spawner,
        )
        self.signed_days_ago(1)
        self.assertFalse(mon.tick(NOW))
        self.signed_days_ago(5.5)
        self.assertTrue(mon.tick(NOW))
        self.assertEqual(spawned[-1], ["/py", "/scripts/maa_ios_resign.py", "auto"])
        self.assertFalse(mon.tick(NOW + timedelta(minutes=24)))
        active["value"] = True
        self.assertTrue(mon.tick(NOW + timedelta(minutes=25)))
        self.assertEqual(spawned[-1][-1], "--app-active")

        self.write_config("")
        self.assertFalse(mon.tick(NOW + timedelta(hours=2)))

    def test_api_routes_role_to_trigger_and_tracks_app_activity(self) -> None:
        seen: list[tuple[bool, str]] = []
        ctx = maa_api.APIContext(
            home_dir=self.daemon_dir.parent,
            scripts_dir=ROOT / "scripts",
            state_dir=self.daemon_dir.parent / "state",
            runs_dir=self.daemon_dir.parent / "state" / "runs",
            daemon_dir=self.daemon_dir,
            secrets_path=self.daemon_dir / "secrets.json",
            rescue_html_path=self.daemon_dir / "rescue.html",
            resign_handler=lambda if_due, trigger: (seen.append((if_due, trigger)) or (202, {"ok": True})),
        )
        self.assertFalse(ctx.app_active())
        ctx.note_app_request()
        self.assertTrue(ctx.app_active())
        self.assertFalse(ctx.app_active(window=0))
        ctx.sse_opened()
        self.assertTrue(ctx.app_active(window=0))
        ctx.sse_closed()
        self.assertFalse(ctx.app_active(window=0))
        ctx.handle_resign(True, "shortcut")
        self.assertEqual(seen, [(True, "shortcut")])

        # S4-4：快照带上正在服务的指纹和预生成的下一张的指纹
        self.assertIsNone(ctx._read_tls())
        maa_common.atomic_write_json(
            self.daemon_dir / "active_tls.json",
            {"spki_sha256": "OLD=", "not_after": "2031-11-23T09:51:25+08:00"},
        )
        maa_common.atomic_write_json(self.daemon_dir / "tls_check.json", {"days_remaining": 1825.0})
        self.assertEqual(
            ctx._read_tls(),
            {
                "spki_sha256": "OLD=",
                "not_after": "2031-11-23T09:51:25+08:00",
                "days_remaining": 1825.0,
                "next_spki_sha256": None,
            },
        )
        (self.daemon_dir / "tls").mkdir()
        (self.daemon_dir / "tls" / "cert.next.pem").write_text("pem", encoding="utf-8")
        calls: list[Path] = []
        with patch.object(maa_api.maa_tls, "compute_spki_sha256", side_effect=lambda p: calls.append(p) or "NEW="):
            self.assertEqual(ctx._read_tls()["next_spki_sha256"], "NEW=")
            self.assertEqual(ctx._read_tls()["next_spki_sha256"], "NEW=")
        self.assertEqual(len(calls), 1, "同一张证书只算一次指纹")


if __name__ == "__main__":
    unittest.main()
