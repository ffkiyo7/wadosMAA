"""Wado's MAA 的抄作业预览（K13）：`copilot preview` 只搜不派发，`copilot go` 确认后才派发。"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

import _isolation  # noqa: E402
import _helpers  # noqa: E402
import maa_action  # noqa: E402
import maa_copilot  # noqa: E402
import maa_copilot_worker  # noqa: E402
import maa_skland  # noqa: E402
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


def candidate(cid: int, *, ratio: float = 1.0, gaps=(), soft=()) -> dict:
    return {"id": cid, "title": f"作业{cid}", "uploader": "u", "ratio": ratio, "gaps": list(gaps),
            "soft_gaps": list(soft), "views": 1, "rating_ratio": 0.9, "minimum_required": "v4"}


CANDIDATES = [
    candidate(1, ratio=1.0, soft=["技能等级不足"]),  # 排在最前但有软缺口：不能选
    candidate(2),
    candidate(3, ratio=0.8, gaps=["缺 W"]),
    candidate(4),
]


class CopilotPreviewTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        root = Path(self._tmp.name)
        self.previews = root / "previews"
        self.searches = root / "searches"
        self.scripts = root / "scripts"
        for path in (self.previews, self.searches, self.scripts):
            path.mkdir()
        (self.scripts / "maa_copilot_worker.py").write_text("")
        self.now = datetime(2026, 11, 6, 15, 0, tzinfo=BEIJING)
        self.blocker = ""
        self.published: list[tuple] = []
        self.dispatched: list[str] = []
        self.refresh_error: Exception | None = None

        def refresh() -> None:
            if self.refresh_error:
                raise self.refresh_error

        for item in (
            patch.object(maa_copilot, "PREVIEWS_DIR", self.previews),
            patch.object(maa_copilot, "SEARCH_LOCK_PATH", root / "search.lock"),
            patch.object(maa_copilot, "ensure_private_dirs", lambda: None),
            patch.object(maa_copilot, "search_copilots", lambda *a, **k: [dict(c) for c in CANDIDATES]),
            patch.object(maa_copilot, "load_roster", return_value={}),
            patch.object(maa_skland, "refresh_roster", side_effect=refresh),
            patch.object(maa_copilot_worker, "_stage_cost", return_value=12),
            patch.object(maa_action, "load_config", return_value={}),
            patch.object(maa_action, "WATCH_PATH", root / "watch.json"),
            patch.object(maa_action, "_expand_copilot_targets", lambda names, *a: (
                [{"stage": names[0], "stage_id": "act54side_05", "modes": ["normal", "raid"]}], "", "")),
            patch.object(maa_action, "dispatch_blocker", lambda *a: self.blocker),
            patch.object(maa_action, "now_beijing", lambda: self.now),
            patch.object(maa_action, "SCRIPTS_DIR", self.scripts),
            patch.object(maa_action, "_search_path", lambda token: self.searches / f"{token}.json"),
            patch.object(maa_action, "publish_round", side_effect=lambda *a, **k: self.published.append(a) or "555"),
            patch.object(maa_action, "dispatch_batch", side_effect=self.dispatched.append),
            patch.dict("os.environ", {"MAA_ACTION_SOURCE": "gui"}),
        ):
            item.start()
            self.addCleanup(item.stop)

    def test_preview_lists_every_candidate_and_picks_the_first_perfect_one(self) -> None:
        ok, message, data = maa_action.copilot_preview("SR-5")
        self.assertTrue(ok, message)
        self.assertEqual(data["best_id"], 2)
        self.assertEqual([c["id"] for c in data["candidates"]], [1, 2, 3, 4])
        self.assertEqual([c["perfect"] for c in data["candidates"]], [False, True, False, True])
        self.assertEqual(data["candidates"][2]["gaps"], ["缺 W"])
        self.assertEqual(self.published, [])
        self.assertEqual(self.dispatched, [])  # 只搜不派发
        self.assertEqual(list(self.searches.iterdir()), [])  # 不碰 searches/（watcher 会当成一轮）

    def test_go_dispatches_the_chosen_perfect_candidate_once(self) -> None:
        _, _, data = maa_action.copilot_preview("SR-5")
        ok, message, result = maa_action.copilot_go(data["token"], "4")
        self.assertTrue(ok, message)
        self.assertEqual(self.dispatched, [result["token"]])
        state = json.loads((self.searches / f"{result['token']}.json").read_text(encoding="utf-8"))
        self.assertEqual(state["status"], "queued")
        self.assertEqual([e["mode"] for e in state["entries"]], ["normal", "raid"])
        self.assertEqual({e["candidate"]["id"] for e in state["entries"]}, {4})
        self.assertEqual(state["message_id"], "555")
        self.assertEqual(state["source"], "gui")
        # 同一次预览不能派两次。
        ok, _, _ = maa_action.copilot_go(data["token"])
        self.assertFalse(ok)
        self.assertEqual(len(self.dispatched), 1)

    def test_go_without_a_choice_takes_the_best_and_never_an_imperfect_one(self) -> None:
        _, _, data = maa_action.copilot_preview("SR-5")
        for chosen in ("1", "3", "99"):
            with self.subTest(chosen=chosen):
                ok, message, _ = maa_action.copilot_go(data["token"], chosen)
                self.assertFalse(ok)
                self.assertIn("完全满足", message)
        ok, _, result = maa_action.copilot_go(data["token"])
        self.assertTrue(ok)
        self.assertEqual(result["candidate_id"], 2)

    def test_go_goes_through_the_one_gate_and_writes_nothing_when_blocked(self) -> None:
        _, _, data = maa_action.copilot_preview("SR-5")
        self.blocker = "距晚场 22:00 不足 25 分钟"
        ok, message, result = maa_action.copilot_go(data["token"])
        self.assertFalse(ok)
        self.assertIn("不足 25 分钟", message)
        self.assertEqual(result["blocked"], self.blocker)
        self.assertEqual((self.published, self.dispatched), ([], []))
        self.assertEqual(list(self.searches.iterdir()), [])

    def test_an_expired_preview_cannot_be_dispatched(self) -> None:
        _, _, data = maa_action.copilot_preview("SR-5")
        self.now += maa_copilot.PREVIEW_TTL + timedelta(seconds=1)
        ok, message, _ = maa_action.copilot_go(data["token"])
        self.assertFalse(ok)
        self.assertIn("过期", message)

    def test_preview_never_downgrades_when_skland_fails(self) -> None:
        self.refresh_error = RuntimeError("cred 过期")
        ok, message, data = maa_action.copilot_preview("SR-5")
        self.assertFalse(ok)
        self.assertIn("不降级", message)
        self.assertEqual(list(self.previews.iterdir()), [])

    def test_preview_and_go_are_gui_only(self) -> None:
        for argv in (["copilot", "preview", "SR-5"], ["copilot", "go", "a" * 12]):
            ok, _ = maa_action.dispatch(argv)
            self.assertFalse(ok)
        self.assertIsNotNone(maa_action.dispatch_gui(["copilot", "go", "zz"]))


class GuiListTests(unittest.TestCase):
    def test_run_choices_share_the_plan_card_source(self) -> None:
        choices = [("上次作战关卡", "", "x"), ("1-7 · 固源岩", "1-7", "y")]
        with patch.object(maa_action, "load_config", return_value={}), patch(
            "maa_plan_card._stage_choices", return_value=choices
        ), patch.object(maa_action, "is_run_locked", return_value=False), patch.object(
            maa_action, "manual_run_blackout_reason", return_value="距早场 08:00 不足 30 分钟"
        ):
            ok, _, data = maa_action.run_choices()
        self.assertTrue(ok)
        self.assertEqual([c["stage"] for c in data["choices"]], ["", "1-7"])
        self.assertIn("annihilation", data["switches"])
        self.assertIn("不足", data["blackout"])

    def test_copilot_stages_share_the_card_source(self) -> None:
        rows = [{"stage": "SR-5", "status": "todo"}]
        with patch.object(maa_action, "load_config", return_value={}), patch(
            "maa_plan_card.copilot_card_stages", return_value=(rows, True)
        ):
            ok, _, data = maa_action.copilot_stages()
        self.assertTrue(ok)
        self.assertEqual(data["stages"], rows)
        self.assertTrue(data["in_activity"])
        for argv in (["run", "choices"], ["copilot", "stages"]):
            self.assertFalse(maa_action.dispatch(argv)[0])


class SharedPerfectRuleTests(unittest.TestCase):
    def test_pick_and_preview_share_one_rule(self) -> None:
        source = (ROOT / "scripts" / "maa_copilot.py").read_text(encoding="utf-8")
        self.assertEqual(source.count('get("ratio") == 1.0'), 1)
        self.assertTrue(maa_copilot.is_perfect(candidate(1)))
        self.assertFalse(maa_copilot.is_perfect(candidate(1, soft=["x"])))
        self.assertFalse(maa_copilot.is_perfect(candidate(1, ratio=0.99)))


if __name__ == "__main__":
    unittest.main()
