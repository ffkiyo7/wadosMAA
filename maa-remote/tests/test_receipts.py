"""`maa_action.py` 的回执三段（§12.1）：`code` 给程序、`message` 给玩家、`detail` 给开发者。

- 静态：GUI 会调到的每条命令，每个 `return` 都是 `done(code, message…)` / `refuse(…)`，
  或者转给另一条这样的命令；`code` 是固定的小写短码。`message` 的禁用词由 `test_ui_copy` 扫。
- 运行：走 `main()` 打出来的那一行 JSON 带 `ok` / `code` / `message`；`detail` 只在有的时候出现，
  GUI 调用时不进 `message`，Discord 调用时接在 `message` 后面（Discord 只读 `ok` / `message`）。
"""
from __future__ import annotations

import ast
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
from test_ui_copy import banned_in  # noqa: E402

ACTION = ROOT / "scripts" / "maa_action.py"
CODE_RE = re.compile(r"^[a-z][a-z_]{1,39}$")
# 首页场卡、状态条的「停止」、抄作业页的「取消」走的是 Discord 也用的 `dispatch()`。
GUI_SHARED = {"set_stage", "skip_today", "fight_today", "run_cancel", "copilot_cancel"}
# 只做转交、不自己造回执的辅助函数。
FORWARDERS = {"_reject_phase", "_schedule_write", "config_patch"}

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


def _functions() -> dict[str, ast.FunctionDef]:
    tree = ast.parse(ACTION.read_text(encoding="utf-8"))
    return {node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)}


def gui_functions() -> set[str]:
    functions = _functions()
    # 只算 `return xxx(...)` 的 xxx：`if` 里的 `valid_phase()` 这种判断不是命令。
    called = {
        node.value.func.id
        for node in ast.walk(functions["dispatch_gui"])
        if isinstance(node, ast.Return) and isinstance(node.value, ast.Call)
        and isinstance(node.value.func, ast.Name)
    }
    return (called & set(functions)) | GUI_SHARED


def _own_returns(node: ast.FunctionDef) -> list[ast.Return]:
    """这个函数自己的 return（不算里面嵌套定义的函数）。"""
    found: list[ast.Return] = []
    stack: list[ast.AST] = list(node.body)
    while stack:
        item = stack.pop()
        if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            continue
        if isinstance(item, ast.Return):
            found.append(item)
        stack.extend(ast.iter_child_nodes(item))
    return found


class ReceiptShapeTests(unittest.TestCase):
    def test_every_gui_command_returns_a_coded_receipt(self) -> None:
        functions = _functions()
        names = gui_functions() | FORWARDERS
        problems: list[str] = []
        codes: set[str] = set()
        for name in sorted(names):
            for node in _own_returns(functions[name]):
                value = node.value
                where = f"{name}():{node.lineno}"
                if not (isinstance(value, ast.Call) and isinstance(value.func, ast.Name)):
                    problems.append(f"{where} 不是 done()/refuse()")
                    continue
                callee = value.func.id
                if callee in names:
                    continue  # 转给另一条带码的命令
                if callee not in {"done", "refuse"}:
                    problems.append(f"{where} 调的是 {callee}()")
                    continue
                first = value.args[0] if value.args else None
                if isinstance(first, ast.Constant) and isinstance(first.value, str):
                    if not CODE_RE.fullmatch(first.value):
                        problems.append(f"{where} code {first.value!r} 不是小写短码")
                    codes.add(first.value)
                elif not (isinstance(first, ast.Call) and isinstance(first.func, ast.Name)
                          and first.func.id == "reply_code"):
                    problems.append(f"{where} code 不是字面量")
                if len(value.args) < 2:
                    problems.append(f"{where} 没有 message")
        self.assertEqual(problems, [], "\n".join(problems))
        # GUI 按码分支的几条，改名就是改接口（§12.1）。
        self.assertLessEqual({"session_soon", "busy", "blocked", "update_blocked"}, codes)

    def test_the_gui_set_covers_what_the_app_calls(self) -> None:
        self.assertLessEqual(
            {"config_get", "config_set", "defaults_set", "plan_today", "run_local", "copilot_preview",
             "copilot_go", "schedule_set", "schedule_toggle", "upstream_update", "run_cancel"},
            gui_functions(),
        )


class ReceiptOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.config_path = root / "config.json"
        maa_common.atomic_write_json(self.config_path, {"schema_version": 1, "recruit_times": 4})
        for item in (
            patch.object(maa_common, "CONFIG_PATH", self.config_path),
            patch.object(maa_common, "state_lock", return_value=contextlib.nullcontext()),
            patch.object(maa_action, "state_lock", return_value=contextlib.nullcontext()),
            patch.object(maa_action, "load_config", maa_common.load_config),
            patch.object(maa_action, "DEFAULTS_PATH", root / "defaults.json"),
            patch.object(maa_action, "run_lock_holder", return_value=None),
        ):
            item.start()
            self.addCleanup(item.stop)

    def run_main(self, *argv: str, source: str = "gui") -> dict:
        out = io.StringIO()
        with patch.dict("os.environ", {"MAA_ACTION_SOURCE": source}), contextlib.redirect_stdout(out):
            maa_action.main(["maa_action.py", *argv])
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 1, lines)
        return json.loads(lines[0])

    def assert_receipt(self, receipt: dict) -> None:
        self.assertIsInstance(receipt["ok"], bool)
        self.assertRegex(receipt["code"], CODE_RE)
        self.assertTrue(receipt["message"])
        self.assertEqual(banned_in(receipt["message"]), [], receipt["message"])
        if "detail" in receipt:
            self.assertTrue(receipt["detail"])

    def test_gui_commands_print_code_and_message(self) -> None:
        cases = [
            (("config", "get"), True, "config"),
            (("config", "set", "recruit_times", "3"), True, "config_saved"),
            (("config", "set", "recruit_times", "{"), False, "bad_value"),
            (("config", "set", "recruit_times", "9"), False, "bad_value"),
            (("defaults", "show"), True, "defaults"),
            (("defaults", "set", "task", "mall", "off"), True, "defaults_saved"),
            (("defaults", "set", "nonsense", "x"), False, "bad_args"),
            (("schedule", "set", "now", "08:00"), False, "bad_phase"),
            (("plan", "set-stage", "1-7", "now"), False, "bad_phase"),
            (("plan", "skip-today", "maybe", "am"), False, "bad_value"),
            (("run", "cancel"), False, "not_running"),
            (("copilot", "go", "bad"), False, "preview_expired"),
        ]
        for argv, ok, code in cases:
            with self.subTest(argv=argv):
                receipt = self.run_main(*argv)
                self.assert_receipt(receipt)
                self.assertEqual((receipt["ok"], receipt["code"]), (ok, code), receipt)

    def test_detail_stays_out_of_the_gui_message_but_reaches_discord(self) -> None:
        receipt = self.run_main("defaults", "set", "nonsense", "x")
        self.assertIn("defaults set stage", receipt["detail"])
        self.assertNotIn("defaults set", receipt["message"])
        discord = self.run_main("defaults", "set", "nonsense", "x", source="discord")
        self.assertIn(receipt["message"], discord["message"])
        self.assertIn(receipt["detail"], discord["message"])

    def test_a_crash_is_a_plain_sentence_with_the_exception_in_detail(self) -> None:
        with patch.object(maa_action, "config_get", side_effect=TypeError("boom")):
            receipt = self.run_main("config", "get")
        self.assert_receipt(receipt)
        self.assertEqual((receipt["ok"], receipt["code"]), (False, "error"))
        self.assertNotIn("TypeError", receipt["message"])
        self.assertEqual(receipt["detail"], "TypeError: boom")

    def test_discord_only_commands_still_get_a_generic_code(self) -> None:
        receipt = self.run_main("copilot", "auto", "maybe", source="discord")
        self.assertEqual((receipt["ok"], receipt["code"]), (False, "failed"))
        self.assertNotIn("detail", receipt)
        unknown = self.run_main("nope", source="discord")
        self.assertEqual(unknown["code"], "unknown_command")

    def test_a_huge_detail_keeps_the_discord_line_under_the_runner_limit(self) -> None:
        reply = maa_action.refuse("failed_hard", "没成功。", detail="x" * 50_000)
        with patch.object(maa_action, "copilot_auto", return_value=reply):
            out = io.StringIO()
            with patch.dict("os.environ", {"MAA_ACTION_SOURCE": "discord"}), contextlib.redirect_stdout(out):
                maa_action.main(["maa_action.py", "copilot", "auto", "on"])
        self.assertLess(len(out.getvalue().encode("utf-8")), 8192)
        self.assertEqual(json.loads(out.getvalue())["code"], "failed_hard")


if __name__ == "__main__":
    unittest.main()
