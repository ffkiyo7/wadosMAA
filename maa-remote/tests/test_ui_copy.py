"""界面文案守门（REVIEW_2026-11-09 §3.5）：普通界面上只出现游戏里的词和日常用语。

扫两处给人看的字：
- `gui/MeoAsstMac/Remote/**/*.swift` 里的字符串字面量：含中文的全部算，外加 `Text(` / `Label(` /
  `Button(` / `.help(` / `title:` / `help:` / `sub:` / `rows:` 等界面调用那一行上的英文字面量；
- `maa_action.py` 里 `dispatch_gui` 会走到的回执 `message`（Wado's MAA 原样显示，Discord 也用）；
- `maa_daily.py` 写进 `runs/<场>.progress.json` 的步骤名和恢复说明（`PROGRESS_STEPS` / `PROGRESS_NOTES`，GUI 原样显示）。

命中禁用词就红，报出「文件:行号 词 原文」。开发者区、诊断信息用注释圈起来跳过：

    // copy-guard: developer   …   // copy-guard: end   （开发者区、复制诊断信息，可以用技术词）
    … // copy-guard: ignore                             （这一行的字面量不是给人看的，例如数据键）

GUI 已经退成纯 maa-remote 前端（REVIEW §4 P1-6），不再有整文件白名单和 `legacy` 段。

正则够用就行，不写 Swift 解析器。
"""

from __future__ import annotations

import ast
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import _isolation  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SWIFT_ROOT = REPO / "gui" / "MeoAsstMac" / "Remote"
ACTION = REPO / "maa-remote" / "scripts" / "maa_action.py"
DAILY = REPO / "maa-remote" / "scripts" / "maa_daily.py"
# 进度文件里给人看的字：这些模块级常量里的每个字符串字面量都算。
PROGRESS_CONSTANTS = ("PROGRESS_STEPS", "PROGRESS_NOTES")

BANNED = (
    "锁", "派发", "闸门", "上游", "cron", "Hermes", "HERMES", "maa-remote", "maa-cli", "MaaCore",
    "MaaResource", "MaaTools", "进程", "token", "回执", "退出码", "schema", "不变量", "PLAN_",
    "开跑", "定时场", "场次", "清理智", "开始唤醒", "熔断", "链条", "持久默认", "导航不过去", "prts",
    "run.lock", "手动场",
)

# 文件里的局部白名单（设置页的开发者区、诊断信息）用上面的 copy-guard 注释圈，不在这里列。

UI_CALL = re.compile(
    r"\b(Text|Label|Button|Toggle|Picker|TextField|DatePicker|Menu|FieldLabel|SectionTitle|PageHeader|"
    r"NoticeLine|GameButton|GameConfirm|FormRow|FormGroup|LabeledContent|Section)\(|"
    r"\.(help|alert|navigationTitle|confirmationDialog)\(|\b(title|help|sub|rows|caption|text):"
)
CJK = re.compile(r"[㐀-鿿]")
GUARD = re.compile(r"//\s*copy-guard:\s*(developer|end|ignore)\b")
# 已经不认的旧标记：出现了就说明有人把旧代码的豁免带回来了。
RETIRED_GUARD = re.compile(r"//\s*copy-guard:\s*legacy\b")

# `dispatch_gui` 直接调的函数之外，这些函数返回的字也会原样出现在 GUI 上（闸门原因、按钮回执）。
EXTRA_ACTION_FUNCTIONS = {
    "dispatch_blocker", "_copilot_blackout_reason", "min_lead_reason", "depot_window_reason",
    "manual_run_blackout_reason", "_schedule_write", "_local_run_switches", "copilot_cancel",
    "copilot_status", "run_cancel",
    # 首页场卡改计划走的是 Discord 也用的这几条（`dispatch()`），失败原因原样显示。
    "set_stage", "skip_today", "fight_today", "_confirmation", "_reject_phase",
}


def swift_literals(line: str) -> tuple[list[str], str]:
    """一行里的字符串字面量（插值 `\\(...)` 里的代码去掉，里面嵌的字面量单独算）和去掉注释后的代码。"""
    literals: list[str] = []
    code: list[str] = []
    i, n = 0, len(line)

    def read_string(start: int) -> int:
        """从开引号后一位读到闭引号，返回闭引号后一位。"""
        buf: list[str] = []
        j = start
        while j < n:
            ch = line[j]
            if ch == "\\" and j + 1 < n and line[j + 1] == "(":
                j = read_code(j + 2, depth_stop=True)
                continue
            if ch == "\\" and j + 1 < n:
                buf.append(line[j : j + 2])
                j += 2
                continue
            if ch == '"':
                literals.append("".join(buf))
                return j + 1
            buf.append(ch)
            j += 1
        literals.append("".join(buf))
        return n

    def read_code(start: int, depth_stop: bool) -> int:
        """读代码；`depth_stop` 时读到配对的右括号为止（插值）。"""
        depth = 0
        j = start
        while j < n:
            ch = line[j]
            if ch == '"':
                j = read_string(j + 1)
                continue
            if not depth_stop and line.startswith("//", j):
                return n
            if depth_stop:
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    if depth == 0:
                        return j + 1
                    depth -= 1
            else:
                code.append(ch)
            j += 1
        return n

    read_code(i, depth_stop=False)
    return literals, "".join(code)


def banned_in(text: str) -> list[str]:
    """全小写的英文词不分大小写（Token、Cron 也算）；带大写的按原样比（PLAN_ 不误伤 maa_plan_card）。"""
    hits = []
    for word in BANNED:
        if word.isascii() and word == word.lower():
            if word in text.lower():
                hits.append(word)
        elif word in text:
            hits.append(word)
    return hits


def scan_swift() -> list[str]:
    problems: list[str] = []
    for path in sorted(SWIFT_ROOT.rglob("*.swift")):
        rel = path.relative_to(SWIFT_ROOT).as_posix()
        skipping: str | None = None
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            guard = GUARD.search(line)
            if guard and guard.group(1) == "developer":
                skipping = guard.group(1)
                continue
            if guard and guard.group(1) == "end":
                skipping = None
                continue
            if skipping or (guard and guard.group(1) == "ignore"):
                continue
            literals, code = swift_literals(line)
            ui_line = bool(UI_CALL.search(code))
            for literal in literals:
                if not (CJK.search(literal) or ui_line):
                    continue
                for word in banned_in(literal):
                    problems.append(f"{rel}:{number} 「{word}」 {literal!r}")
    return problems


def _strings(node: ast.AST) -> list[tuple[int, str]]:
    return [
        (item.lineno, item.value) for item in ast.walk(node)
        if isinstance(item, ast.Constant) and isinstance(item.value, str)
    ]


REPLY_BUILDERS = {"done", "refuse"}


def reply_call(node: ast.AST) -> bool:
    return isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in REPLY_BUILDERS


def scan_action() -> list[str]:
    tree = ast.parse(ACTION.read_text(encoding="utf-8"))
    functions = {
        node.name: node for node in tree.body if isinstance(node, ast.FunctionDef)
    }
    gui = functions["dispatch_gui"]
    names = {
        call.func.id
        for call in ast.walk(gui)
        if isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
    } | EXTRA_ACTION_FUNCTIONS
    problems: list[str] = []
    for name in sorted(names & set(functions)):
        for node in ast.walk(functions[name]):
            targets: list[ast.AST] = []
            if isinstance(node, ast.Return) and node.value is not None:
                value = node.value
                if isinstance(value, ast.Tuple) and len(value.elts) >= 2:
                    targets.append(value.elts[1])
                elif reply_call(value):
                    # `done(code, message, data, detail=…)`：只有 message 给人看；code 是给程序的短码，
                    # detail 是给开发者的原始信息，都不扫。
                    assert isinstance(value, ast.Call)
                    targets.extend(value.args[1:2])
                elif not isinstance(value, ast.Tuple):
                    targets.append(value)
            elif isinstance(node, ast.Raise) and isinstance(node.exc, ast.Call):
                targets.extend(node.exc.args)
            for target in targets:
                for lineno, text in _strings(target):
                    for word in banned_in(text):
                        problems.append(f"maa_action.py:{lineno} {name}() 「{word}」 {text!r}")
    return problems


def scan_progress() -> list[str]:
    tree = ast.parse(DAILY.read_text(encoding="utf-8"))
    problems: list[str] = []
    found: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names = [node.target.id]
        else:
            continue
        name = next((n for n in names if n in PROGRESS_CONSTANTS), None)
        if name is None or node.value is None:
            continue
        found.add(name)
        for lineno, text in _strings(node.value):
            # PROGRESS_STEPS 里的 TASK_STEPS key（StartUp / Fight2…）和步骤 key 不上界面。
            if text.isascii():
                continue
            for word in banned_in(text):
                problems.append(f"maa_daily.py:{lineno} {name} 「{word}」 {text!r}")
    missing = set(PROGRESS_CONSTANTS) - found
    if missing:
        problems.append(f"maa_daily.py 里找不到 {sorted(missing)}")
    return problems


def tearDownModule() -> None:
    # 这里只读源码，不碰 HOME；照全套测试的规矩（test_isolation）也查一遍。
    _isolation.assert_shared_home_clean()


class UiCopyTests(unittest.TestCase):
    def test_literal_scanner_handles_interpolation_and_comments(self) -> None:
        literals, code = swift_literals(
            'Text("今天 \\(a ?? "未知") 完成").help("x") // 注释里写 cron 不算'
        )
        self.assertEqual(literals, ["未知", "今天  完成", "x"])
        self.assertNotIn("cron", code)
        self.assertEqual(banned_in("crontab"), ["cron"])
        self.assertEqual(banned_in("刷理智"), [])

    @unittest.skipUnless(SWIFT_ROOT.is_dir(), "没有 gui/ 目录")
    def test_no_retired_guards(self) -> None:
        # 整文件白名单和 `copy-guard: legacy` 已随纯前端删掉，不许再加回来。
        hits = [
            f"{path.relative_to(SWIFT_ROOT).as_posix()}:{number}"
            for path in sorted(SWIFT_ROOT.rglob("*.swift"))
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1)
            if RETIRED_GUARD.search(line)
        ]
        self.assertEqual(hits, [], "还有 copy-guard: legacy：\n" + "\n".join(hits))

    @unittest.skipUnless(SWIFT_ROOT.is_dir(), "没有 gui/ 目录")
    def test_gui_copy_has_no_implementation_words(self) -> None:
        problems = scan_swift()
        self.assertEqual(problems, [], "界面上出现了实现层的词：\n" + "\n".join(problems))

    def test_progress_notes_have_no_implementation_words(self) -> None:
        problems = scan_progress()
        self.assertEqual(problems, [], "进度文件的文案里出现了实现层的词：\n" + "\n".join(problems))

    def test_gui_receipts_have_no_implementation_words(self) -> None:
        problems = scan_action()
        self.assertEqual(problems, [], "回执里出现了实现层的词：\n" + "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
