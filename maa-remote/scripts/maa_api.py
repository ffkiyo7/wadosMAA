#!/usr/bin/env python3
"""Wado's MAA 本地 HTTPS/SSE API 服务端（Phase 2 S2-1 / S2-2 / S2-4）。

纯 Python 标准库（零第三方依赖），设计要点：
1. TLS 抗挂死（S2-1）：`do_handshake_on_connect=False`，在 `ThreadingHTTPServer` 的工作线程内先设短超时
   （默认 5s）再执行 `do_handshake()`，慢速半开连接绝不阻塞主 `accept()` 线程与其他并发请求；
2. 来源 IP 白名单收口：仅放行 `127.0.0.1/32`、`::1/128` 与 `192.168.50.0/24`（可配置）；
3. 分域 Bearer Token 鉴权（常时间 SHA-256 比对）：
   - `GET /healthz` 与 `GET /rescue` 免鉴权（不泄露任何账号/游戏数据）；
   - `full` Token 可访问全部 `/api/v1/*`；
   - `resign_only` Token 仅允许 `POST /api/v1/ios/resign`（含 `?if_due=1`），访问其他接口一律 `403`；
4. 全部 27+ REST/SSE 端点（SPEC §5.1 & §5.2）：
   - 写接口严格白名单映射为受控 argv 交给 `maa_action.py`（默认注入 `MAA_ACTION_SOURCE=ios`）；
   - `POST /api/v1/run/cancel` 强制要求 body 携带非空 `run_id`；
   - `POST /api/v1/copilot/preview` 支持客户端 UUID `request_id`，配合 `DELETE /api/v1/copilot/preview/<request_id>`
     可实时终止正在搜索的子进程或清理预览临时文件；
   - `GET /api/v1/events` SSE 广播引擎：25s 心跳防 Cloudflare 100s 断连，监听并推送 `progress`/`lock`/`last_run`/
     `today_plan`/`upstream`/`resign` 变更。
"""

from __future__ import annotations

import dataclasses
import ipaddress
import json
import os
import queue
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable, Mapping
from urllib.parse import parse_qs, unquote, urlparse

import maa_action
import maa_common
import maa_copilot
import maa_notify
import maa_schedule
import maa_tls
import maa_upstream

API_VERSION = 1
SERVICE_NAME = "wados-maa"
DEFAULT_ALLOWED_CIDRS = ("127.0.0.1/32", "::1/128", "192.168.50.0/24")
DEFAULT_HANDSHAKE_TIMEOUT = 5.0
DEFAULT_REQUEST_TIMEOUT = 30.0
DEFAULT_SSE_KEEPALIVE_SECONDS = 25.0
DEFAULT_SSE_POLL_SECONDS = 0.5
MAX_REQUEST_BODY_BYTES = 256 * 1024
DEFAULT_ACTION_TIMEOUT = 25.0
PREVIEW_ACTION_TIMEOUT = 60.0

SAFE_RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SAFE_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")

ActionRunner = Callable[[list[str], str, float], dict[str, Any]]
ResignHandler = Callable[[bool], tuple[int, dict[str, Any]]]


def _parse_networks(cidrs: tuple[str, ...] | list[str]) -> tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...]:
    nets: list[ipaddress.IPv4Network | ipaddress.IPv6Network] = []
    for raw in cidrs:
        text = str(raw).strip()
        if text:
            nets.append(ipaddress.ip_network(text, strict=False))
    return tuple(nets)


def is_ip_allowed(
    remote_ip: str,
    allowed_networks: tuple[ipaddress.IPv4Network | ipaddress.IPv6Network, ...],
) -> bool:
    """判断客户端来源 IP 是否在白名单网段内（兼容 IPv4-mapped IPv6）。"""
    try:
        addr = ipaddress.ip_address(remote_ip)
    except ValueError:
        return False
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    return any(addr in net for net in allowed_networks)


def is_safe_run_id(run_id: str) -> bool:
    """校验 URL 路径里的 run_id：严禁路径穿越（`..`、`/`、`\\`、空字节）。"""
    if not run_id or ".." in run_id or "/" in run_id or "\\" in run_id or "\x00" in run_id:
        return False
    return bool(SAFE_RUN_ID_RE.fullmatch(run_id))


def is_safe_request_id(request_id: str) -> bool:
    if not request_id or ".." in request_id or "/" in request_id or "\\" in request_id:
        return False
    return bool(SAFE_REQUEST_ID_RE.fullmatch(request_id))


def _resolve_under(base_dir: Path, candidate: Path) -> Path | None:
    try:
        resolved_base = base_dir.resolve()
        resolved = candidate.resolve()
        if not resolved.is_relative_to(resolved_base):
            return None
        return resolved
    except OSError:
        return None


def _parse_bool_flag(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _sse_fingerprint(event: str, payload: Any) -> str:
    """为 SSE diff 计算稳定指纹：剥离每次现算的瞬时时间戳（如 `upstream.checked_at`），避免空转刷屏。"""
    if event == "upstream" and isinstance(payload, dict) and "checked_at" in payload:
        stable = {k: v for k, v in payload.items() if k != "checked_at"}
        return json.dumps(stable, ensure_ascii=False, sort_keys=True, default=str)
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, default=str)


def _raise_missing_config(errors: Mapping[str, str]) -> Any:
    raise RuntimeError(f"config.json 不可用：{errors.get('config', '读取失败')}")


def _default_resign_handler(if_due: bool) -> tuple[int, dict[str, Any]]:
    return HTTPStatus.NOT_IMPLEMENTED, {
        "ok": False,
        "code": "not_configured",
        "message": "iOS 无线续签尚未配置（将于 Phase 4 接入）。",
        "data": {"if_due": if_due, "configured": False},
    }


def _kill_process_tree(proc: subprocess.Popen[Any]) -> None:
    """尽量按进程组温和停止，超时后强杀。"""
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.terminate()
        except OSError:
            pass
    try:
        proc.wait(timeout=2.0)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=2.0)
    except subprocess.TimeoutExpired:
        pass


@dataclasses.dataclass
class _PreviewRecord:
    request_id: str
    proc: subprocess.Popen[Any] | None = None
    token: str = ""
    canceled: bool = False
    finished: bool = False


class PreviewRegistry:
    """按客户端 `request_id` 跟踪进行中的 `copilot preview` 子进程与已完成预览文件。"""

    def __init__(self, previews_dir: Path | None = None) -> None:
        self._lock = threading.Lock()
        self._records: dict[str, _PreviewRecord] = {}
        self._previews_dir = previews_dir

    def _dir(self) -> Path:
        return self._previews_dir or maa_copilot.PREVIEWS_DIR

    def begin(self, request_id: str, proc: subprocess.Popen[Any]) -> bool:
        with self._lock:
            existing = self._records.get(request_id)
            if existing is not None and not existing.finished:
                return False
            self._records[request_id] = _PreviewRecord(request_id=request_id, proc=proc)
            return True

    def finish(self, request_id: str, *, token: str = "") -> bool:
        """标记完成并返回是否在执行期间已被取消；若已取消且生成了预览文件则顺手删掉。"""
        with self._lock:
            rec = self._records.get(request_id)
            if rec is None:
                return False
            rec.proc = None
            rec.finished = True
            if token:
                rec.token = token
            canceled = rec.canceled
        if canceled and token:
            self._delete_preview_file(token)
        return canceled

    def cancel(self, request_id: str) -> dict[str, Any]:
        """取消正在进行的预览子进程，或清理已完成预览对应的临时文件。"""
        proc_to_kill: subprocess.Popen[Any] | None = None
        token_to_delete = ""
        found = False
        with self._lock:
            rec = self._records.get(request_id)
            if rec is not None:
                found = True
                rec.canceled = True
                if not rec.finished and rec.proc is not None:
                    proc_to_kill = rec.proc
                token_to_delete = rec.token
                if rec.finished:
                    self._records.pop(request_id, None)

        killed = False
        if proc_to_kill is not None:
            _kill_process_tree(proc_to_kill)
            killed = True

        deleted = False
        if token_to_delete:
            deleted = self._delete_preview_file(token_to_delete)
        elif not found and maa_copilot.SEARCH_TOKEN_RE.fullmatch(request_id):
            # 兼容直接按预览 token 清理。
            deleted = self._delete_preview_file(request_id)
            if deleted:
                found = True

        if killed:
            return {
                "ok": True,
                "code": "preview_canceled",
                "message": "已中止正在进行的作业搜索。",
                "data": {"request_id": request_id, "killed": True, "deleted": deleted},
            }
        if deleted:
            return {
                "ok": True,
                "code": "preview_deleted",
                "message": "已清理预览缓存。",
                "data": {"request_id": request_id, "killed": False, "deleted": True},
            }
        return {
            "ok": True,
            "code": "preview_not_found",
            "message": "预览已结束或已清理。",
            "data": {"request_id": request_id, "found": found, "killed": False, "deleted": False},
        }

    def _delete_preview_file(self, token: str) -> bool:
        if not maa_copilot.SEARCH_TOKEN_RE.fullmatch(token):
            return False
        base = self._dir()
        target = _resolve_under(base, base / f"{token}.json")
        if target is None or not target.is_file():
            return False
        try:
            target.unlink(missing_ok=True)
            return True
        except OSError:
            return False


class SSEHub:
    """后台状态监听与 SSE 多客户端广播中心。"""

    def __init__(
        self,
        state_provider: Callable[[], dict[str, Any]],
        *,
        poll_interval: float = DEFAULT_SSE_POLL_SECONDS,
    ) -> None:
        self._state_provider = state_provider
        self._poll_interval = max(0.05, poll_interval)
        self._lock = threading.Lock()
        self._clients: set[queue.Queue[tuple[str, Any] | None]] = set()
        self._last_serialized: dict[str, str] = {}
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
        self._seed_initial()
        thread = threading.Thread(target=self._loop, name="wados-sse-hub", daemon=True)
        thread.start()
        with self._lock:
            self._thread = thread

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        with self._lock:
            clients = list(self._clients)
            thread = self._thread
            self._thread = None
        for q in clients:
            self._offer(q, None)
        if thread is not None and thread.ident is not None and thread is not threading.current_thread():
            thread.join(timeout=2.0)

    def notify_changed(self) -> None:
        """外部写操作或重载完成后主动唤醒一次检测。"""
        self._wake.set()

    def subscribe(self) -> queue.Queue[tuple[str, Any] | None]:
        q: queue.Queue[tuple[str, Any] | None] = queue.Queue(maxsize=128)
        with self._lock:
            self._clients.add(q)
        return q

    def unsubscribe(self, q: queue.Queue[tuple[str, Any] | None]) -> None:
        with self._lock:
            self._clients.discard(q)

    def _seed_initial(self) -> None:
        try:
            state = self._state_provider()
        except Exception as exc:  # noqa: BLE001 — (c) 初始状态采样失败不阻断 SSE 启动
            print(f"SSE initial state read failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
            return
        self._last_serialized = {
            event: _sse_fingerprint(event, payload)
            for event, payload in state.items()
        }

    @staticmethod
    def _offer(q: queue.Queue[tuple[str, Any] | None], item: tuple[str, Any] | None) -> None:
        try:
            q.put_nowait(item)
        except queue.Full:
            try:
                q.get_nowait()
            except queue.Empty:
                pass
            try:
                q.put_nowait(item)
            except queue.Full:
                pass

    def poll_once(self) -> list[str]:
        """检查一次状态变化并向所有客户端广播变化事件，返回触发的事件名列表。"""
        state = self._state_provider()
        emitted: list[str] = []
        changes: list[tuple[str, Any]] = []
        for event, payload in state.items():
            serialized = _sse_fingerprint(event, payload)
            if self._last_serialized.get(event) != serialized:
                self._last_serialized[event] = serialized
                changes.append((event, payload))
                emitted.append(event)
        if changes:
            with self._lock:
                clients = list(self._clients)
            for item in changes:
                for q in clients:
                    self._offer(q, item)
        return emitted

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._wake.wait(timeout=self._poll_interval)
            self._wake.clear()
            if self._stop.is_set():
                break
            with self._lock:
                has_clients = bool(self._clients)
            if not has_clients:
                continue
            try:
                self.poll_once()
            except Exception as exc:  # noqa: BLE001 — (a) SSE 后台线程顶层兜底，永不静默死亡
                print(f"SSE poll error: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)


@dataclasses.dataclass
class APIContext:
    """API 服务运行上下文（全部路径与协作对象均可注入，便于完全离线单测）。"""

    home_dir: Path
    scripts_dir: Path
    state_dir: Path
    runs_dir: Path
    daemon_dir: Path
    secrets_path: Path
    rescue_html_path: Path
    python_bin: str = sys.executable
    allowed_cidrs: tuple[str, ...] = DEFAULT_ALLOWED_CIDRS
    handshake_timeout: float = DEFAULT_HANDSHAKE_TIMEOUT
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT
    sse_keepalive_seconds: float = DEFAULT_SSE_KEEPALIVE_SECONDS
    sse_poll_seconds: float = DEFAULT_SSE_POLL_SECONDS
    action_runner: ActionRunner | None = None
    resign_handler: ResignHandler | None = None
    on_schedule_reload: Callable[[], None] | None = None
    preview_spawner: Callable[[list[str], dict[str, str]], subprocess.Popen[Any]] | None = None
    clock: Callable[[], datetime] = maa_common.now_beijing
    previews: PreviewRegistry = dataclasses.field(default_factory=PreviewRegistry)

    def __post_init__(self) -> None:
        self.allowed_networks = _parse_networks(self.allowed_cidrs)
        self.previews = PreviewRegistry(self.state_dir / "copilot" / "previews")

    @classmethod
    def from_default_paths(
        cls,
        *,
        allowed_cidrs: tuple[str, ...] | list[str] = DEFAULT_ALLOWED_CIDRS,
        handshake_timeout: float = DEFAULT_HANDSHAKE_TIMEOUT,
        sse_keepalive_seconds: float = DEFAULT_SSE_KEEPALIVE_SECONDS,
        on_schedule_reload: Callable[[], None] | None = None,
    ) -> APIContext:
        home = maa_common.WADOS_MAA_HOME
        daemon_dir = maa_common.DAEMON_DIR
        rescue_deployed = daemon_dir / "rescue.html"
        rescue_repo = Path(__file__).resolve().parents[1] / "daemon" / "rescue.html"
        rescue_path = rescue_deployed if rescue_deployed.is_file() else rescue_repo
        return cls(
            home_dir=home,
            scripts_dir=maa_common.SCRIPTS_DIR,
            state_dir=maa_common.STATE_DIR,
            runs_dir=maa_common.RUNS_DIR,
            daemon_dir=daemon_dir,
            secrets_path=daemon_dir / "secrets.json",
            rescue_html_path=rescue_path,
            python_bin=sys.executable,
            allowed_cidrs=tuple(allowed_cidrs),
            handshake_timeout=handshake_timeout,
            sse_keepalive_seconds=sse_keepalive_seconds,
            on_schedule_reload=on_schedule_reload,
        )

    def load_secrets(self) -> dict[str, Any]:
        raw = maa_common.load_json(self.secrets_path, {})
        return raw if isinstance(raw, dict) else {}

    def authenticate(self, auth_header: str) -> str | None:
        """校验 `Authorization: Bearer <token>`，返回 `'full'`、`'resign_only'` 或 `None`。"""
        if not auth_header:
            return None
        parts = auth_header.strip().split(None, 1)
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return None
        token = parts[1].strip()
        if not token:
            return None
        sec = self.load_secrets()
        full_hash = str(sec.get("full_token_sha256") or "")
        if maa_tls.verify_token(token, full_hash):
            return "full"
        resign_hash = str(sec.get("resign_only_token_sha256") or "")
        if maa_tls.verify_token(token, resign_hash):
            return "resign_only"
        return None

    def _subprocess_env(self, source: str) -> dict[str, str]:
        env = dict(os.environ)
        env["WADOS_MAA_HOME"] = str(self.home_dir)
        env["MAA_ACTION_SOURCE"] = source
        return env

    def run_action(self, argv: list[str], *, source: str = "ios", timeout: float = DEFAULT_ACTION_TIMEOUT) -> dict[str, Any]:
        """以受控 argv 子进程调用 `maa_action.py`，返回结构化回执 `{ok, code, message, detail?, data?}`。"""
        if self.action_runner is not None:
            return self.action_runner(argv, source, timeout)
        script = self.scripts_dir / "maa_action.py"
        if not script.is_file():
            return {
                "ok": False,
                "code": "not_installed",
                "message": "后端动作脚本尚未部署。",
                "detail": str(script),
            }
        try:
            proc = subprocess.run(
                [self.python_bin, str(script), *argv],
                capture_output=True,
                text=True,
                check=False,
                timeout=timeout,
                env=self._subprocess_env(source),
            )
        except subprocess.TimeoutExpired:
            return {
                "ok": False,
                "code": "timeout",
                "message": "操作超时，请稍后刷新状态确认结果。",
            }
        except OSError as exc:
            return {
                "ok": False,
                "code": "exec_failed",
                "message": "无法执行动作脚本。",
                "detail": str(exc),
            }
        return _parse_action_stdout(proc.stdout, proc.stderr, proc.returncode)

    def run_copilot_preview(self, stage: str, request_id: str) -> dict[str, Any]:
        """以可被 `DELETE /api/v1/copilot/preview/<request_id>` 中断的子进程跑 `copilot preview <stage>`。"""
        script = self.scripts_dir / "maa_action.py"
        argv = [self.python_bin, str(script), "copilot", "preview", stage]
        env = self._subprocess_env("ios")
        if self.preview_spawner is not None:
            proc = self.preview_spawner(argv, env)
        else:
            if not script.is_file():
                return {
                    "ok": False,
                    "code": "not_installed",
                    "message": "后端动作脚本尚未部署。",
                    "detail": str(script),
                }
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                start_new_session=True,
            )
        if not self.previews.begin(request_id, proc):
            _kill_process_tree(proc)
            return {
                "ok": False,
                "code": "duplicate_request_id",
                "message": "该预览请求正在进行中，请勿重复提交。",
            }

        token = ""
        try:
            stdout, stderr = proc.communicate(timeout=PREVIEW_ACTION_TIMEOUT)
            result = _parse_action_stdout(stdout or "", stderr or "", proc.returncode)
            data = result.get("data")
            if isinstance(data, dict) and isinstance(data.get("token"), str):
                token = data["token"]
            canceled = self.previews.finish(request_id, token=token)
            if canceled:
                return {
                    "ok": False,
                    "code": "preview_canceled",
                    "message": "预览已取消。",
                    "data": {"request_id": request_id},
                }
            if isinstance(data, dict):
                data["request_id"] = request_id
            return result
        except subprocess.TimeoutExpired:
            _kill_process_tree(proc)
            self.previews.finish(request_id)
            return {
                "ok": False,
                "code": "timeout",
                "message": "搜索作业超时，请稍后再试。",
                "data": {"request_id": request_id},
            }

    # -----------------------------------------------------------------------
    # 读接口数据组装（全部只读本地状态文件，毫秒级返回）
    # -----------------------------------------------------------------------

    def _read_lock(self) -> dict[str, Any] | None:
        return maa_common.run_lock_holder()

    def _read_last_run(self) -> dict[str, Any] | None:
        raw = maa_common.load_json(self.state_dir / "last_run.json", None)
        if not isinstance(raw, dict) or not raw.get("status"):
            return None
        return raw

    def _read_active_progress(
        self,
        lock: Mapping[str, Any] | None,
        last_run: Mapping[str, Any] | None,
    ) -> dict[str, Any] | None:
        # 持锁态：只接受当前 lock.run_id 自己的进度文件，新文件未写入前直接返回 None，绝不回退旧场进度。
        if lock is not None:
            lock_run_id = lock.get("run_id")
            if not isinstance(lock_run_id, str) or not is_safe_run_id(lock_run_id):
                return None
            resolved = _resolve_under(self.runs_dir, self.runs_dir / f"{lock_run_id}.progress.json")
            if resolved is None or not resolved.is_file():
                return None
            doc = maa_common.load_json(resolved, None)
            if not isinstance(doc, dict):
                return None
            if doc.get("run_id") and str(doc.get("run_id")) != lock_run_id:
                return None
            if (
                last_run
                and str(last_run.get("run_id") or "") == lock_run_id
                and last_run.get("started_at")
                and str(doc.get("started_at") or "") != str(last_run.get("started_at"))
            ):
                return None
            return doc

        # 空闲态：按 last_run 定位，严格遵守 DEV_GUIDE §12.3 的 started_at 一致性规则。
        if not last_run:
            return None
        candidates: list[Path] = []
        raw_prog = last_run.get("progress")
        if isinstance(raw_prog, str) and raw_prog:
            p = Path(raw_prog)
            candidates.append(p if p.is_file() else self.runs_dir / p.name)
        run_id = last_run.get("run_id")
        if isinstance(run_id, str) and is_safe_run_id(run_id):
            candidates.append(self.runs_dir / f"{run_id}.progress.json")

        expected_started = str(last_run.get("started_at") or "")
        for path in candidates:
            resolved = _resolve_under(self.runs_dir, path)
            if resolved is None or not resolved.is_file():
                continue
            doc = maa_common.load_json(resolved, None)
            if not isinstance(doc, dict):
                continue
            if expected_started and str(doc.get("started_at") or "") != expected_started:
                continue
            return doc
        return None

    def _read_today_plan(self) -> dict[str, Any]:
        _ok, _msg, data = maa_action.plan_today()
        return data

    def _file_sig(self, path: Path) -> tuple[int, int]:
        try:
            st = path.stat()
            return (st.st_mtime_ns, st.st_size)
        except OSError:
            return (0, 0)

    def _read_upstream(self) -> dict[str, Any]:
        # 缓存签名包含：upstream.json、config.json、run.lock、国服游戏日（04:00 换日）以及实时 update_gate，
        # 确保跨 04:00 从 ok 切 stale 或进出早晚场保护窗导致 update_blocked 变化时立刻刷新，
        # 同时空闲 0.5s SSE 轮询不重复拉起 maa version 子进程。
        now = self.clock()
        config = maa_common.load_config()
        holder = maa_common.run_lock_holder()
        game_day = maa_upstream.game_day_start(now).isoformat()
        gate = maa_upstream.update_gate(config, now)
        sig: tuple[Any, ...] = (
            self._file_sig(self.state_dir / "upstream.json"),
            self._file_sig(self.state_dir / "config.json"),
            holder,
            game_day,
            gate,
        )
        cached_sig = getattr(self, "_upstream_cache_sig", None)
        cached_val = getattr(self, "_upstream_cache_val", None)
        if cached_val is not None and cached_sig == sig:
            return cached_val
        val = maa_upstream.status(config, online=False, at=now)
        self._upstream_cache_sig = sig
        self._upstream_cache_val = val
        return val

    def _read_resign(self) -> dict[str, Any] | None:
        raw = maa_common.load_json(self.daemon_dir / "resign.json", None)
        return raw if isinstance(raw, dict) and raw else None

    def _read_scheduler(self) -> dict[str, Any] | None:
        raw = maa_common.load_json(self.daemon_dir / "scheduler.json", None)
        return raw if isinstance(raw, dict) and raw else None

    def _read_activity(self) -> dict[str, Any] | None:
        raw = maa_common.load_json(self.state_dir / "activity_watch.json", None)
        return raw if isinstance(raw, dict) and raw else None

    def build_snapshot(self) -> dict[str, Any]:
        """`GET /api/v1/snapshot` 首屏聚合快照（SPEC §5.1）。

        逐字段容错隔离：即使 `config.json` 损坏或某个旁路子系统报错，仍必须尽量返回
        `lock`（含 `run_id`）、`last_run`、`progress`，确保 `/rescue` 可执行紧急停止；
        失败字段置 `None` 并在 `errors` 中标出原因。
        """
        errors: dict[str, str] = {}

        def safe(name: str, fn: Callable[[], Any]) -> Any:
            try:
                return fn()
            except Exception as exc:  # noqa: BLE001 — (c) 快照逐字段降级隔离，单源失败绝不拖垮紧急停止
                errors[name] = f"{type(exc).__name__}: {exc}"
                return None

        lock = safe("lock", self._read_lock)
        last_run = safe("last_run", self._read_last_run)
        progress = safe("progress", lambda: self._read_active_progress(lock, last_run))

        config: Any = None
        try:
            config = maa_common.load_config()
        except Exception as exc:  # noqa: BLE001 — (c) config.json 损坏时仅标记对应字段失败，不返回 500
            errors["config"] = f"{type(exc).__name__}: {exc}"

        today_plan = safe("today_plan", self._read_today_plan)
        schedule = safe(
            "schedule",
            lambda: maa_schedule.schedule_report(config) if config is not None else (_raise_missing_config(errors)),
        )
        upstream = safe(
            "upstream",
            lambda: maa_upstream.status(config, online=False) if config is not None else (_raise_missing_config(errors)),
        )
        copilot_auto_paused = safe("copilot_auto_paused", lambda: bool(maa_copilot.auto_pause_state()))
        activity = safe("activity", self._read_activity)
        scheduler = safe("scheduler", self._read_scheduler)
        resign = safe("resign", self._read_resign)

        return {
            "lock": lock,
            "last_run": last_run,
            "progress": progress,
            "today_plan": today_plan,
            "schedule": schedule,
            "upstream": upstream,
            "copilot_auto_paused": copilot_auto_paused,
            "activity": activity,
            "scheduler": scheduler,
            "resign": resign,
            "errors": errors,
        }

    def build_sse_state(self) -> dict[str, Any]:
        """SSE 监听的 6 类事件状态快照（逐源隔离，单源异常不阻塞 lock/progress 等事件推送）。"""
        out: dict[str, Any] = {}

        def capture(name: str, fn: Callable[[], Any]) -> Any:
            try:
                val = fn()
                out[name] = val
                return val
            except Exception as exc:  # noqa: BLE001 — (c) SSE 单源异常隔离，确保 lock/last_run/progress 照常推送
                print(f"SSE source {name} failed: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
                return None

        lock = capture("lock", self._read_lock)
        last_run = capture("last_run", self._read_last_run)
        capture("progress", lambda: self._read_active_progress(lock, last_run))
        capture("today_plan", self._read_today_plan)
        capture("upstream", self._read_upstream)
        capture("resign", self._read_resign)
        return out

    def read_history(self, *, limit: int = 50, offset: int = 0) -> dict[str, Any]:
        clamped_limit = max(1, min(200, limit))
        clamped_offset = max(0, offset)
        rows = maa_common.read_run_index(self.runs_dir)
        rows.reverse()  # 倒序：最新在前
        total = len(rows)
        items = rows[clamped_offset : clamped_offset + clamped_limit]
        return {
            "items": items,
            "total": total,
            "has_more": (clamped_offset + len(items)) < total,
        }

    def locate_run_artifact(self, run_id: str, kind: str) -> Path | None:
        """安全定位指定场次的 `report` / `screenshot` / `log` 文件（防穿越，兼容旧命名）。"""
        if not is_safe_run_id(run_id):
            return None
        suffix_map = {
            "report": f"{run_id}-report.json",
            "screenshot": f"{run_id}.png",
            "log": f"{run_id}.log",
        }
        direct_name = suffix_map.get(kind)
        if not direct_name:
            return None
        direct = _resolve_under(self.runs_dir, self.runs_dir / direct_name)
        if direct is not None and direct.is_file():
            return direct

        # 兼容从 index.jsonl 查找（含旧命名或路径重映射兜底）
        for row in reversed(maa_common.read_run_index(self.runs_dir)):
            if str(row.get("id") or "") != run_id:
                continue
            field_key = "report" if kind == "report" else "log" if kind == "log" else ""
            raw_path = row.get(field_key) if field_key else None
            if isinstance(raw_path, str) and raw_path:
                for candidate in (Path(raw_path), self.runs_dir / Path(raw_path).name):
                    resolved = _resolve_under(self.runs_dir, candidate)
                    if resolved is not None and resolved.is_file():
                        return resolved
            if kind == "screenshot":
                # 由 report/log 的 stem 推导同名 .png
                for stem_field in ("log", "report"):
                    raw_ref = row.get(stem_field)
                    if isinstance(raw_ref, str) and raw_ref:
                        name = Path(raw_ref).name
                        if name.endswith("-report.json"):
                            png_name = name[: -len("-report.json")] + ".png"
                        elif name.endswith(".log"):
                            png_name = name[: -len(".log")] + ".png"
                        else:
                            continue
                        resolved = _resolve_under(self.runs_dir, self.runs_dir / png_name)
                        if resolved is not None and resolved.is_file():
                            return resolved
        return None


def _parse_action_stdout(stdout: str, stderr: str, returncode: int) -> dict[str, Any]:
    lines = [line.strip() for line in stdout.splitlines() if line.strip()]
    for line in reversed(lines):
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict) and "ok" in parsed:
            return parsed
    detail = (stderr or stdout or "").strip()[:400]
    return {
        "ok": False,
        "code": "action_failed",
        "message": "动作执行返回异常。",
        "detail": f"rc={returncode} {detail}".strip(),
    }


def _make_thumbnail_jpeg(png_path: Path) -> tuple[bytes, str]:
    """用 macOS 自带 `sips` 生成压缩缩略图；不可用时退回原图 PNG。"""
    sips = shutil.which("sips") or ("/usr/bin/sips" if os.path.isfile("/usr/bin/sips") else "")
    if not sips:
        return png_path.read_bytes(), "image/png"
    with tempfile.TemporaryDirectory(prefix="wados-thumb-") as tmp:
        out_jpg = Path(tmp) / "thumb.jpg"
        proc = subprocess.run(
            [sips, "-Z", "960", "-s", "format", "jpeg", "-s", "formatOptions", "75", str(png_path), "--out", str(out_jpg)],
            capture_output=True,
            check=False,
            timeout=10,
        )
        if proc.returncode == 0 and out_jpg.is_file():
            return out_jpg.read_bytes(), "image/jpeg"
    return png_path.read_bytes(), "image/png"


class _APIRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server: SafeTLSThreadingHTTPServer  # type: ignore[assignment]

    def log_message(self, format: str, *args: Any) -> None:
        # 静音默认逐条访问日志，避免刷屏与泄露 URL/路径细节；异常由错误路径显式记录。
        del format, args

    @property
    def ctx(self) -> APIContext:
        return self.server.ctx

    def _should_close_connection(self) -> bool:
        if self.close_connection:
            return True
        if getattr(self, "_is_chunked", False) and not getattr(self, "_body_consumed", False):
            return True
        return getattr(self, "_declared_body_len", 0) > 0 and not getattr(self, "_body_consumed", False)

    def _begin_request(self, *, allow_body: bool) -> bool:
        """校验 HTTP/1.1 请求帧边界：仅允许单一 Transfer-Encoding: chunked（且禁与 CL 并存）、拒绝非法 CL，标记未消费请求体。"""
        self._body_consumed = False
        self._declared_body_len = 0
        self._is_chunked = False

        te_values = self.headers.get_all("Transfer-Encoding") or []
        cl_values = self.headers.get_all("Content-Length") or []

        if te_values and cl_values:
            self.close_connection = True
            self._send_error_json(
                HTTPStatus.BAD_REQUEST,
                "bad_request",
                "不允许同时携带 Transfer-Encoding 与 Content-Length。",
            )
            return False

        if te_values:
            if len(te_values) != 1 or te_values[0].strip().lower() != "chunked":
                self.close_connection = True
                self._send_error_json(
                    HTTPStatus.BAD_REQUEST,
                    "unsupported_transfer_encoding",
                    "仅支持单一 Transfer-Encoding: chunked 请求。",
                )
                return False
            self._is_chunked = True
            if not allow_body:
                # GET / DELETE 不会读取分块请求体，响应后必须关闭连接以防剩余字节被当作下一条请求。
                self.close_connection = True
            return True

        if len(cl_values) > 1:
            self.close_connection = True
            self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_request", "不允许多个 Content-Length 头。")
            return False
        if len(cl_values) == 1:
            raw_len = cl_values[0].strip()
            if not raw_len.isdigit():
                self.close_connection = True
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_request", "无效的 Content-Length。")
                return False
            self._declared_body_len = int(raw_len)
            if self._declared_body_len > 0 and not allow_body:
                # GET / DELETE 不会读取请求体，响应后必须关闭连接以防剩余字节被当作下一条请求。
                self.close_connection = True
        return True

    def send_error(self, code: int, message: str | None = None, explain: str | None = None) -> None:
        # 任何框架层错误（如不支持的 HTTP 方法）一律关闭连接，避免未消费请求体滞留。
        self.close_connection = True
        super().send_error(code, message, explain)

    def _send_json(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        if self._should_close_connection():
            self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, status: int, data: bytes, content_type: str, *, cache_control: str = "no-store") -> None:
        if self._should_close_connection():
            self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", cache_control)
        self.send_header("X-Content-Type-Options", "nosniff")
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def _send_error_json(self, status: int, code: str, message: str, detail: str = "") -> None:
        body: dict[str, Any] = {"ok": False, "code": code, "message": message}
        if detail:
            body["detail"] = detail
        self._send_json(status, body)

    def _read_chunked_body(self) -> tuple[bytes | None, tuple[int, str, str] | None]:
        """按 RFC 9112 严格解析 `Transfer-Encoding: chunked`（适配 cloudflared HTTP/2 空体/分块 POST）。"""
        max_line_bytes = 1024
        max_trailer_lines = 16
        buf = bytearray()
        while True:
            size_line = self.rfile.readline(max_line_bytes + 1)
            if not size_line or len(size_line) > max_line_bytes or not size_line.endswith(b"\r\n"):
                self.close_connection = True
                return None, (HTTPStatus.BAD_REQUEST, "bad_request", "无效的分块请求体。")
            size_part = size_line[:-2].split(b";", 1)[0].strip()
            if not size_part or len(size_part) > 16 or not all(c in b"0123456789abcdefABCDEF" for c in size_part):
                self.close_connection = True
                return None, (HTTPStatus.BAD_REQUEST, "bad_request", "无效的分块长度。")
            chunk_size = int(size_part, 16)
            if chunk_size == 0:
                trailer_count = 0
                while True:
                    trailer = self.rfile.readline(max_line_bytes + 1)
                    if not trailer or len(trailer) > max_line_bytes or not trailer.endswith(b"\r\n"):
                        self.close_connection = True
                        return None, (HTTPStatus.BAD_REQUEST, "bad_request", "无效的分块结尾。")
                    if trailer == b"\r\n":
                        self._body_consumed = True
                        return bytes(buf), None
                    trailer_count += 1
                    if trailer_count > max_trailer_lines:
                        self.close_connection = True
                        return None, (HTTPStatus.BAD_REQUEST, "bad_request", "分块拖尾头过多。")
            if len(buf) + chunk_size > MAX_REQUEST_BODY_BYTES:
                self.close_connection = True
                return None, (HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "payload_too_large", "请求体超过大小限制。")
            chunk = self.rfile.read(chunk_size)
            if len(chunk) < chunk_size:
                self.close_connection = True
                return None, (HTTPStatus.BAD_REQUEST, "bad_request", "分块请求体不完整。")
            crlf = self.rfile.read(2)
            if crlf != b"\r\n":
                self.close_connection = True
                return None, (HTTPStatus.BAD_REQUEST, "bad_request", "分块缺少换行分隔符。")
            buf.extend(chunk)

    def _read_json_body(self) -> tuple[dict[str, Any] | None, tuple[int, str, str] | None]:
        if getattr(self, "_is_chunked", False):
            raw, err = self._read_chunked_body()
            if err is not None:
                return None, err
            assert raw is not None
            if not raw:
                return {}, None
        else:
            length = getattr(self, "_declared_body_len", 0)
            if length < 0 or length > MAX_REQUEST_BODY_BYTES:
                self.close_connection = True
                return None, (HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "payload_too_large", "请求体超过大小限制。")
            if length == 0:
                self._body_consumed = True
                return {}, None
            raw = self.rfile.read(length)
            if len(raw) < length:
                self.close_connection = True
                return None, (HTTPStatus.BAD_REQUEST, "bad_request", "请求体不完整。")
            self._body_consumed = True
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None, (HTTPStatus.BAD_REQUEST, "bad_json", "请求体必须是合法 JSON。")
        if not isinstance(parsed, dict):
            return None, (HTTPStatus.BAD_REQUEST, "bad_json", "请求体必须是 JSON 对象。")
        return parsed, None

    def _require_auth(self, *, allow_resign_only: bool = False) -> str | None:
        role = self.ctx.authenticate(self.headers.get("Authorization", ""))
        if role is None:
            self._send_error_json(HTTPStatus.UNAUTHORIZED, "unauthorized", "未授权或令牌无效。")
            return None
        if role == "resign_only" and not allow_resign_only:
            self._send_error_json(HTTPStatus.FORBIDDEN, "forbidden", "当前令牌仅允许触发 iOS 无线续签。")
            return None
        return role

    def do_GET(self) -> None:
        try:
            if not self._begin_request(allow_body=False):
                return
            self._handle_get()
        except Exception as exc:  # noqa: BLE001 — (a) HTTP 处理器顶层兜底，返回结构化 500
            self.close_connection = True
            self._send_error_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                "internal_error",
                "服务端处理请求失败。",
                f"{type(exc).__name__}: {exc}",
            )

    def do_POST(self) -> None:
        try:
            if not self._begin_request(allow_body=True):
                return
            self._handle_post()
        except Exception as exc:  # noqa: BLE001 — (a) HTTP 处理器顶层兜底，返回结构化 500
            self.close_connection = True
            self._send_error_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                "internal_error",
                "服务端处理请求失败。",
                f"{type(exc).__name__}: {exc}",
            )

    def do_DELETE(self) -> None:
        try:
            if not self._begin_request(allow_body=False):
                return
            self._handle_delete()
        except Exception as exc:  # noqa: BLE001 — (a) HTTP 处理器顶层兜底，返回结构化 500
            self.close_connection = True
            self._send_error_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                "internal_error",
                "服务端处理请求失败。",
                f"{type(exc).__name__}: {exc}",
            )

    def _handle_get(self) -> None:
        parsed = urlparse(self.path)
        raw_path = parsed.path
        query = parse_qs(parsed.query)

        # 1. 免鉴权端点
        if raw_path == "/healthz":
            self._send_json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": SERVICE_NAME,
                    "api_version": API_VERSION,
                    "server_time": maa_common.now_beijing().isoformat(),
                },
            )
            return

        if raw_path in ("/rescue", "/rescue/"):
            html_path = self.ctx.rescue_html_path
            if not html_path.is_file():
                self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "应急页面未部署。")
                return
            self._send_bytes(HTTPStatus.OK, html_path.read_bytes(), "text/html; charset=utf-8")
            return

        # 2. 以下全部需要 full Token
        if self._require_auth(allow_resign_only=False) is None:
            return

        if raw_path == "/api/v1/snapshot":
            self._send_json(HTTPStatus.OK, self.ctx.build_snapshot())
            return

        if raw_path == "/api/v1/events":
            self._serve_sse()
            return

        if raw_path == "/api/v1/choices":
            _ok, _msg, data = maa_action.run_choices()
            self._send_json(HTTPStatus.OK, data)
            return

        if raw_path == "/api/v1/copilot/stages":
            _ok, _msg, data = maa_action.copilot_stages()
            self._send_json(HTTPStatus.OK, data)
            return

        if raw_path == "/api/v1/config":
            _ok, _msg, data = maa_action.config_get()
            self._send_json(HTTPStatus.OK, data)
            return

        if raw_path == "/api/v1/defaults":
            _ok, _msg, data = maa_action.defaults_show()
            self._send_json(HTTPStatus.OK, data)
            return

        if raw_path == "/api/v1/history":
            try:
                limit = int(query.get("limit", ["50"])[0])
                offset = int(query.get("offset", ["0"])[0])
            except ValueError:
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "limit 和 offset 必须是整数。")
                return
            self._send_json(HTTPStatus.OK, self.ctx.read_history(limit=limit, offset=offset))
            return

        # /api/v1/runs/<id>/(report|screenshot|log)
        if raw_path.startswith("/api/v1/runs/"):
            self._handle_run_artifact(raw_path, query)
            return

        self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "未知接口路径。")

    def _handle_run_artifact(self, raw_path: str, query: dict[str, list[str]]) -> None:
        # 严格校验原始路径段，避免 `%2f` / `..` 绕过。
        suffix = raw_path[len("/api/v1/runs/") :]
        parts = suffix.split("/")
        if len(parts) != 2:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_run_id", "无效的场次路径。")
            return
        run_id = unquote(parts[0])
        kind = parts[1]
        if kind not in ("report", "screenshot", "log"):
            self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "未知场次产物类型。")
            return
        if not is_safe_run_id(run_id):
            self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_run_id", "非法场次 ID。")
            return

        artifact = self.ctx.locate_run_artifact(run_id, kind)
        if artifact is None:
            self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "找不到对应的场次产物。")
            return

        if kind == "report":
            data = maa_common.load_json(artifact, None)
            if not isinstance(data, dict):
                self._send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, "bad_report", "战报文件损坏。")
                return
            self._send_json(HTTPStatus.OK, data)
            return

        if kind == "screenshot":
            want_thumb = _parse_bool_flag(query.get("thumb", ["0"])[0])
            if want_thumb:
                raw_bytes, ctype = _make_thumbnail_jpeg(artifact)
            else:
                raw_bytes, ctype = artifact.read_bytes(), "image/png"
            self._send_bytes(HTTPStatus.OK, raw_bytes, ctype, cache_control="private, max-age=300")
            return

        # kind == "log"
        try:
            tail = int(query.get("tail", ["200"])[0])
        except ValueError:
            self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "tail 必须是整数。")
            return
        tail = max(1, min(2000, tail))
        all_lines = artifact.read_text(encoding="utf-8", errors="replace").splitlines()
        truncated = len(all_lines) > tail
        self._send_json(HTTPStatus.OK, {"lines": all_lines[-tail:], "truncated": truncated})

    def _serve_sse(self) -> None:
        self.connection.settimeout(None)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        self.close_connection = True

        hub = self.server.sse_hub
        sub = hub.subscribe()
        keepalive = max(0.05, float(self.ctx.sse_keepalive_seconds))
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while not self.server.shutting_down.is_set():
                try:
                    item = sub.get(timeout=keepalive)
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    continue
                if item is None:
                    break
                event_name, payload = item
                data_str = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), default=str)
                frame = f"event: {event_name}\ndata: {data_str}\n\n".encode("utf-8")
                self.wfile.write(frame)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            hub.unsubscribe(sub)

    def _handle_post(self) -> None:
        parsed = urlparse(self.path)
        raw_path = parsed.path
        query = parse_qs(parsed.query)

        if raw_path == "/api/v1/ios/resign":
            if self._require_auth(allow_resign_only=True) is None:
                return
            body, err = self._read_json_body()
            if err is not None:
                self._send_error_json(*err)
                return
            assert body is not None
            if_due = _parse_bool_flag(query.get("if_due", ["0"])[0]) or bool(body.get("if_due", False))
            handler = self.ctx.resign_handler or _default_resign_handler
            status, payload = handler(if_due)
            self._send_json(status, payload)
            return

        if self._require_auth(allow_resign_only=False) is None:
            return

        body, err = self._read_json_body()
        if err is not None:
            self._send_error_json(*err)
            return
        assert body is not None

        if raw_path == "/api/v1/plan/stage":
            phase = str(body.get("phase") or "")
            if phase not in ("am", "pm"):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_phase", "phase 必须是 am 或 pm。")
                return
            if bool(body.get("auto", False)):
                res = self.ctx.run_action(["plan", "auto-stage", phase])
            else:
                if "stage" not in body or not isinstance(body.get("stage"), str):
                    self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "缺少 stage 字符串。")
                    return
                res = self.ctx.run_action(["plan", "set-stage", body["stage"], phase])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/plan/skip":
            phase = str(body.get("phase") or "")
            skip = body.get("skip")
            if phase not in ("am", "pm") or not isinstance(skip, bool):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 phase (am|pm) 和布尔值 skip。")
                return
            res = self.ctx.run_action(["plan", "skip-today", "on" if skip else "off", phase])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/plan/fight":
            phase = str(body.get("phase") or "")
            fight = body.get("fight")
            if phase not in ("am", "pm") or not isinstance(fight, bool):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 phase (am|pm) 和布尔值 fight。")
                return
            res = self.ctx.run_action(["plan", "fight", "on" if fight else "off", phase])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/run/local":
            stage = body.get("stage")
            switches = body.get("switches")
            force = bool(body.get("force", False))
            if not isinstance(stage, str) or not isinstance(switches, dict):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要字符串 stage 和对象 switches。")
                return
            argv = ["run", "local", stage, json.dumps(switches, ensure_ascii=False)]
            if force:
                argv.append("--force")
            res = self.ctx.run_action(argv)
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/run/cancel":
            run_id = body.get("run_id")
            if not isinstance(run_id, str) or not run_id.strip():
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "紧急停止必须携带目标 run_id。")
                return
            if not is_safe_run_id(run_id.strip()):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_run_id", "run_id 格式无效。")
                return
            res = self.ctx.run_action(["run", "cancel", "--run-id", run_id.strip()])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/copilot/preview":
            stage = body.get("stage")
            request_id = body.get("request_id")
            if not isinstance(stage, str) or not stage.strip():
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "缺少 stage 参数。")
                return
            if not isinstance(request_id, str) or not is_safe_request_id(request_id.strip()):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "缺少合法的 request_id（UUID）。")
                return
            res = self.ctx.run_copilot_preview(stage.strip(), request_id.strip())
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/copilot/go":
            token = body.get("token")
            if not isinstance(token, str) or not token.strip():
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "缺少预览 token。")
                return
            argv = ["copilot", "go", token.strip()]
            cand_id = body.get("candidate_id")
            if cand_id is not None and str(cand_id).strip():
                if not str(cand_id).strip().isdigit():
                    self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "candidate_id 必须是正整数。")
                    return
                argv.append(str(cand_id).strip())
            res = self.ctx.run_action(argv)
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/copilot/auto":
            if isinstance(body.get("enabled"), bool):
                enabled = body["enabled"]
            elif isinstance(body.get("paused"), bool):
                enabled = not body["paused"]
            else:
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要布尔值 enabled 或 paused。")
                return
            res = self.ctx.run_action(["copilot", "auto", "on" if enabled else "off"])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/copilot/mark":
            stage = body.get("stage")
            cleared = body.get("cleared")
            if not isinstance(stage, str) or not stage.strip() or not isinstance(cleared, bool):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 stage 与布尔值 cleared。")
                return
            if cleared:
                argv = ["copilot", "mark-cleared", stage.strip()]
                mode = body.get("mode")
                if mode is not None and str(mode).strip():
                    mode_s = str(mode).strip().lower()
                    if mode_s not in ("normal", "raid", "all"):
                        self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "mode 仅支持 normal / raid / all。")
                        return
                    argv.append(mode_s)
            else:
                argv = ["copilot", "unmark", stage.strip()]
            res = self.ctx.run_action(argv)
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/schedule":
            res = self._dispatch_schedule(body)
            if res is None:
                return
            if res.get("ok") and self.ctx.on_schedule_reload is not None:
                self.ctx.on_schedule_reload()
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/defaults":
            if "stage" in body and isinstance(body.get("stage"), str):
                res = self.ctx.run_action(["defaults", "set", "stage", body["stage"]])
            elif isinstance(body.get("task"), str) and isinstance(body.get("enabled"), bool):
                res = self.ctx.run_action(
                    ["defaults", "set", "task", body["task"], "on" if body["enabled"] else "off"]
                )
            else:
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 stage 或 (task, enabled)。")
                return
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/config":
            if isinstance(body.get("key"), str) and "value" in body:
                res = self.ctx.run_action(
                    ["config", "set", body["key"], json.dumps(body["value"], ensure_ascii=False)]
                )
            elif isinstance(body.get("patch"), dict):
                res = self.ctx.run_action(
                    ["config", "patch", json.dumps(body["patch"], ensure_ascii=False)]
                )
            elif isinstance(body.get("values"), dict):
                res = self.ctx.run_action(
                    ["config", "patch", json.dumps(body["values"], ensure_ascii=False)]
                )
            else:
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 (key, value) 或 patch 对象。")
                return
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/upstream/update":
            res = self.ctx.run_action(["upstream", "update"])
            self.server.sse_hub.notify_changed()
            self._send_json(HTTPStatus.OK, res)
            return

        if raw_path == "/api/v1/notify/test":
            ok, msg, info = maa_notify.send_test()
            self._send_json(
                HTTPStatus.OK,
                {
                    "ok": ok,
                    "code": "notify_sent" if ok else "notify_failed",
                    "message": msg,
                    "data": info,
                },
            )
            return

        self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "未知接口路径。")

    def _dispatch_schedule(self, body: dict[str, Any]) -> dict[str, Any] | None:
        action = str(body.get("action") or "").strip().lower()
        if action == "sync":
            return self.ctx.run_action(["schedule", "sync"])
        if action == "depot" or "depot_enabled" in body:
            val = body.get("enabled") if action == "depot" else body.get("depot_enabled")
            if not isinstance(val, bool):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "depot 开关必须是布尔值。")
                return None
            return self.ctx.run_action(["schedule", "depot", "on" if val else "off"])
        if action in ("enable", "disable"):
            phase = str(body.get("phase") or "")
            if phase not in ("am", "pm", "depot"):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_phase", "phase 必须是 am / pm / depot。")
                return None
            return self.ctx.run_action(["schedule", action, phase])
        if action == "set":
            phase = str(body.get("phase") or "")
            hhmm = body.get("time")
            if phase not in ("am", "pm") or not isinstance(hhmm, str):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "需要 phase (am|pm) 和 time (HH:MM)。")
                return None
            return self.ctx.run_action(["schedule", "set", phase, hhmm])

        # 组合形态：{phase: "am"|"pm", time?: "HH:MM", enabled?: bool}
        phase = str(body.get("phase") or "")
        if phase in ("am", "pm") and ("time" in body or "enabled" in body):
            res: dict[str, Any] = {"ok": True, "code": "schedule_saved", "message": "已保存。"}
            if "time" in body:
                if not isinstance(body["time"], str):
                    self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "time 必须是 HH:MM 字符串。")
                    return None
                res = self.ctx.run_action(["schedule", "set", phase, body["time"]])
                if not res.get("ok"):
                    return res
            if "enabled" in body:
                if not isinstance(body["enabled"], bool):
                    self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "enabled 必须是布尔值。")
                    return None
                res = self.ctx.run_action(["schedule", "enable" if body["enabled"] else "disable", phase])
            return res

        self._send_error_json(
            HTTPStatus.BAD_REQUEST,
            "bad_args",
            "需要合法的调度修改参数（action 或 phase/time/enabled/depot_enabled）。",
        )
        return None

    def _handle_delete(self) -> None:
        parsed = urlparse(self.path)
        raw_path = parsed.path

        if self._require_auth(allow_resign_only=False) is None:
            return

        prefix = "/api/v1/copilot/preview/"
        if raw_path.startswith(prefix):
            req_id = unquote(raw_path[len(prefix) :])
            if "/" in req_id or not is_safe_request_id(req_id):
                self._send_error_json(HTTPStatus.BAD_REQUEST, "bad_args", "request_id 格式无效。")
                return
            res = self.ctx.previews.cancel(req_id)
            self._send_json(HTTPStatus.OK, res)
            return

        self._send_error_json(HTTPStatus.NOT_FOUND, "not_found", "未知接口路径。")


class SafeTLSThreadingHTTPServer(ThreadingHTTPServer):
    """线程内带超时 TLS 握手 + 来源 IP 收口 + 证书热重载的安全 HTTPS/SSE 服务器。

    关键防挂死保证（SPEC §4.2.3 & S2-1）：
    - 主 `accept()` 线程绝不执行 `do_handshake()`；
    - 仅在 `process_request_thread()` 派生线程内先验 IP、再设 `handshake_timeout`（默认 5s）、
      再以 `do_handshake_on_connect=False` 包装并握手；超时或异常立即关闭 socket。
    """

    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64

    def __init__(
        self,
        server_address: tuple[str, int],
        ctx: APIContext,
        *,
        ssl_context: ssl.SSLContext | None = None,
        cert_path: Path | None = None,
        key_path: Path | None = None,
    ) -> None:
        self.ctx = ctx
        self._ssl_lock = threading.Lock()
        self.ssl_context = ssl_context
        self._cert_path = cert_path
        self._key_path = key_path
        self.active_cert_info: dict[str, Any] | None = (
            _read_served_cert_meta(cert_path) if (ssl_context is not None and cert_path is not None) else None
        )
        self.shutting_down = threading.Event()
        self.sse_hub = SSEHub(ctx.build_sse_state, poll_interval=ctx.sse_poll_seconds)
        super().__init__(server_address, _APIRequestHandler)

    def get_active_cert_info(self) -> dict[str, Any] | None:
        with self._ssl_lock:
            return dict(self.active_cert_info) if self.active_cert_info is not None else None

    def reload_tls(self, cert_path: Path | None = None, key_path: Path | None = None) -> dict[str, Any]:
        """原子重载服务端 TLS 证书；若新证书无效则保持旧 SSLContext 不受影响并抛异常。"""
        cpath = cert_path or self._cert_path
        kpath = key_path or self._key_path
        if cpath is None or kpath is None:
            raise RuntimeError("当前服务未配置 TLS 证书路径，无法重载。")
        new_ctx = build_ssl_context(cpath, kpath)
        meta = _read_served_cert_meta(cpath)
        with self._ssl_lock:
            self.ssl_context = new_ctx
            self._cert_path = cpath
            self._key_path = kpath
            self.active_cert_info = meta
        return dict(meta)

    def serve_forever(self, poll_interval: float = 0.5) -> None:
        self.sse_hub.start()
        try:
            super().serve_forever(poll_interval=poll_interval)
        finally:
            self.shutting_down.set()
            self.sse_hub.stop()

    def shutdown(self) -> None:
        self.shutting_down.set()
        self.sse_hub.stop()
        super().shutdown()

    def process_request_thread(self, request: socket.socket | bytes, client_address: Any) -> None:
        if not isinstance(request, socket.socket):
            return
        remote_ip = str(client_address[0]) if isinstance(client_address, tuple) and client_address else ""
        if not is_ip_allowed(remote_ip, self.ctx.allowed_networks):
            try:
                request.close()
            except OSError:
                pass
            return

        with self._ssl_lock:
            ssl_ctx = self.ssl_context

        conn: socket.socket = request
        if ssl_ctx is not None:
            tls_sock: ssl.SSLSocket | None = None
            try:
                request.settimeout(self.ctx.handshake_timeout)
                tls_sock = ssl_ctx.wrap_socket(
                    request,
                    server_side=True,
                    do_handshake_on_connect=False,
                )
                tls_sock.do_handshake()
                conn = tls_sock
            except (ssl.SSLError, TimeoutError, socket.timeout, OSError):
                target = tls_sock if tls_sock is not None else request
                try:
                    target.close()
                except OSError:
                    pass
                return

        try:
            conn.settimeout(self.ctx.request_timeout)
            self.finish_request(conn, client_address)
        except Exception as exc:  # noqa: BLE001 — (a) 单连接线程顶层兜底，不影响其他并发连接
            print(f"API connection error ({remote_ip}): {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        finally:
            self.shutdown_request(conn)


def _read_served_cert_meta(cert_path: Path) -> dict[str, Any]:
    """读取并记录当前已加载进 SSLContext 的证书指纹与到期时间。

    `cert_sha256` 使用纯 Python 标准库计算（零外部依赖）；SPKI 与到期时间尽力用 OpenSSL 3 读取，
    读取失败仅打警告并标记 `meta_ok=False`，绝不阻断 HTTPS API 启动或证书热切换。
    """
    cert_sha256 = ""
    try:
        cert_sha256 = maa_tls.compute_cert_sha256(cert_path)
    except (OSError, ValueError) as exc:
        print(f"warning: compute_cert_sha256 failed ({cert_path}): {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)

    meta: dict[str, Any] = {
        "cert_path": str(cert_path),
        "cert_sha256": cert_sha256,
        "spki_sha256": "",
        "not_after": "",
        "not_after_utc": "",
        "meta_ok": False,
        "loaded_at": maa_common.now_beijing().isoformat(),
    }
    try:
        spki = maa_tls.compute_spki_sha256(cert_path)
        expiry = maa_tls.cert_expiry_info(cert_path)
        meta["spki_sha256"] = spki
        meta["not_after"] = expiry["not_after"]
        meta["not_after_utc"] = expiry["not_after_utc"]
        meta["meta_ok"] = True
    except Exception as exc:  # noqa: BLE001 — (c) 证书元信息仅用于到期巡检，失败记日志并降级，绝不阻断 API 启动/热重载
        meta["meta_error"] = f"{type(exc).__name__}: {exc}"
        print(
            f"warning: TLS cert metadata unavailable ({cert_path}): {type(exc).__name__}: {exc}",
            file=sys.stderr,
            flush=True,
        )
    return meta


def build_ssl_context(cert_path: Path, key_path: Path) -> ssl.SSLContext:
    """构建现代 TLS 1.2+ 服务端上下文。"""
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    return ctx


def create_server(
    host: str,
    port: int,
    ctx: APIContext,
    *,
    cert_path: Path | None = None,
    key_path: Path | None = None,
) -> SafeTLSThreadingHTTPServer:
    ssl_ctx = build_ssl_context(cert_path, key_path) if (cert_path and key_path) else None
    return SafeTLSThreadingHTTPServer(
        (host, port),
        ctx,
        ssl_context=ssl_ctx,
        cert_path=cert_path,
        key_path=key_path,
    )
