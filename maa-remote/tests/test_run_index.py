"""场次索引 `runs/index.jsonl`（不变量 #66，DEV_GUIDE §12.3）的单测。

只测 `maa_common` 里的追加 / 读 / 裁剪 / 清理；各结束路径有没有写，在 `test_daily.py`
（日常）和 `test_copilot_worker.py`（抄作业）里跟着各自的执行用例测。
"""

from __future__ import annotations

import ast
import contextlib
import io
import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tests"))

# 必须先于任何 scripts/ 模块：把 HOME 换成临时目录，碰真实 home / 外网当场炸。
import _isolation  # noqa: E402
import maa_common  # noqa: E402


def tearDownModule() -> None:
    _isolation.assert_shared_home_clean()


class RunIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        self.dir = Path(raw.name) / "runs"

    @property
    def path(self) -> Path:
        return self.dir / maa_common.RUN_INDEX_NAME

    def test_each_append_is_one_versioned_json_line(self) -> None:
        self.assertTrue(maa_common.append_run_index(self.dir, {"id": "a", "status": "success", "stage": "龙门"}))
        self.assertTrue(maa_common.append_run_index(self.dir, {"id": "b", "status": "failed"}))
        raw = self.path.read_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        lines = raw.decode("utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        first = json.loads(lines[0])
        self.assertEqual(first, {"schema_version": 1, "id": "a", "status": "success", "stage": "龙门"})
        # 中文原样写，不转义；文件和目录都只给自己看。
        self.assertIn("龙门", lines[0])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.dir.stat().st_mode), 0o700)
        self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir)], ["a", "b"])

    def test_the_append_opens_with_o_append_and_writes_once(self) -> None:
        """单行 `O_APPEND` 一次写入：读者看到的要么是整行、要么没有这行。"""
        calls: list[int] = []
        real_open, real_write = os.open, os.write

        def spy_open(path, flags, *args):
            if str(path).endswith(maa_common.RUN_INDEX_NAME):
                calls.append(flags)
            return real_open(path, flags, *args)

        writes: list[bytes] = []

        def spy_write(fd, data):
            writes.append(bytes(data))
            return real_write(fd, data)

        with patch.object(maa_common.os, "open", spy_open), patch.object(maa_common.os, "write", spy_write):
            maa_common.append_run_index(self.dir, {"id": "a"})
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0] & os.O_APPEND)
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0].count(b"\n"), 1)

    def test_broken_lines_are_skipped_not_fatal(self) -> None:
        self.dir.mkdir(parents=True)
        self.path.write_bytes(
            b'{"schema_version":1,"id":"a"}\n'
            b'{"schema_version":1,"id":"b"\n'  # 写到一半的行
            b"\xff\xfe\n"  # 不是 UTF-8
            b"[1,2]\n"  # 不是对象
            b'{"schema_version":99,"id":"future"}\n'  # 不认识的更高版本
            b'{"schema_version":"1","id":"str"}\n'
            b"\n"
            b'{"id":"old"}\n'  # 没有版本号 = 1
        )
        self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir)], ["a", "old"])
        # 坏行不影响继续追加。
        maa_common.append_run_index(self.dir, {"id": "c"})
        self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir)], ["a", "old", "c"])
        self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir, limit=2)], ["old", "c"])

    def test_a_missing_index_reads_as_empty(self) -> None:
        self.assertEqual(maa_common.read_run_index(self.dir), [])

    def test_the_index_is_trimmed_to_the_most_recent_rows(self) -> None:
        with patch.object(maa_common, "RUN_INDEX_KEEP", 5), patch.object(maa_common, "RUN_INDEX_TRIM_AT", 8):
            for n in range(8):
                maa_common.append_run_index(self.dir, {"id": n})
            # 没过线：只追加、不重写。
            self.assertEqual(len(maa_common.read_run_index(self.dir)), 8)
            maa_common.append_run_index(self.dir, {"id": 8})
            self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir)], [4, 5, 6, 7, 8])
            maa_common.append_run_index(self.dir, {"id": 9})
            self.assertEqual([row["id"] for row in maa_common.read_run_index(self.dir)], [4, 5, 6, 7, 8, 9])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)

    def test_the_default_retention_covers_more_than_thirty_runs(self) -> None:
        self.assertGreaterEqual(maa_common.RUN_INDEX_KEEP, 30)
        self.assertGreater(maa_common.RUN_INDEX_TRIM_AT, maa_common.RUN_INDEX_KEEP)

    def test_concurrent_appends_never_interleave(self) -> None:
        def worker(n: int) -> None:
            for i in range(40):
                maa_common.append_run_index(self.dir, {"id": f"{n}-{i}", "pad": "x" * 300})

        threads = [threading.Thread(target=worker, args=(n,)) for n in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        lines = self.path.read_text("utf-8").splitlines()
        self.assertEqual(len(lines), 160)
        self.assertEqual(len({json.loads(line)["id"] for line in lines}), 160)

    def test_append_never_raises(self) -> None:
        self.dir.parent.mkdir(parents=True, exist_ok=True)
        self.dir.write_text("不是目录", encoding="utf-8")
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            self.assertFalse(maa_common.append_run_index(self.dir, {"id": "a"}))
            # 写不成 JSON 的值也不抛。
            self.assertFalse(maa_common.append_run_index(self.dir, {"id": object()}))
        self.assertIn("场次索引没写成", stderr.getvalue())

    def test_run_file_cleanup_never_removes_the_index(self) -> None:
        self.dir.mkdir(parents=True)
        maa_common.append_run_index(self.dir, {"id": "a"})
        old_log = self.dir / "2026-01-01-am.log"
        old_log.write_text("x", encoding="utf-8")
        long_ago = (datetime.now() - timedelta(days=60)).timestamp()
        for path in (old_log, self.path, self.dir / maa_common.RUN_INDEX_LOCK_NAME):
            os.utime(path, (long_ago, long_ago))
        with patch.object(maa_common, "RUNS_DIR", self.dir):
            removed = maa_common.cleanup_run_files(14)
        self.assertEqual(removed, ["2026-01-01-am.log"])
        self.assertTrue(self.path.is_file())
        self.assertEqual(len(maa_common.read_run_index(self.dir)), 1)


class FailureCauseTests(unittest.TestCase):
    def test_the_first_matching_cause_wins(self) -> None:
        import maa_daily

        base = dict(
            startup_error="", offline_gave_up=False, connect_gave_up=False, timed_out=False,
            proxy_batches=0, return_code=0, home_verified=True, cleanup_errors=[], inventory_error="",
        )
        cases = [
            ({"startup_error": "游戏没装", "return_code": 1}, "startup"),
            ({"offline_gave_up": True, "return_code": 1}, "offline"),
            ({"connect_gave_up": True, "return_code": 1}, "screen_lost"),
            ({"timed_out": True, "return_code": 1}, "timeout"),
            ({"proxy_batches": 2}, "proxy"),
            ({"return_code": 1}, "task_failed"),
            ({"home_verified": False}, "not_home"),
            ({"cleanup_errors": ["x"]}, "cleanup"),
            ({"inventory_error": "x"}, "inventory"),
            ({}, "unknown"),
        ]
        for extra, cause in cases:
            with self.subTest(cause=cause):
                self.assertEqual(maa_daily.daily_failure(**{**base, **extra}), cause)


class RunIndexWriterTests(unittest.TestCase):
    def test_only_the_runners_write_the_index(self) -> None:
        """#66：只有日常和抄作业的收尾写索引；GUI 只读。"""
        writers = set()
        for path in sorted((ROOT / "scripts").glob("*.py")):
            tree = ast.parse(path.read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and getattr(node.func, "id", None) == "append_run_index":
                    writers.add(path.name)
        self.assertEqual(writers, {"maa_daily.py", "maa_copilot_worker.py"})


if __name__ == "__main__":
    unittest.main()
