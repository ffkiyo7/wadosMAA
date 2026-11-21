# Phase 2 子 Spec：HTTPS/SSE API + 独立隧道 + 应急页（`devhome`）

> 对应总 Spec：[SPEC_DECOUPLE_AND_IOS.md §4 & §5 & §9 Phase 2](../SPEC_DECOUPLE_AND_IOS.md)
> 原则：在 `feat/decouple-ios` + `devhome` 完成全部远程 API、安全边界与隧道部署模板，**线上 `~/.hermes` 仍不动**。
> 跨阶段提示：进入 Phase 2 时可同步并行推进 [Phase 3](./P3_IOS_APP_AND_CUTOVER.md) 的 **S3-1（UI 细化设计）** 与 **S3-2（抽出 `shared/` Swift Package）**。

---

## 执行顺序与并行安排

```text
Gate 1 ──┬──► S2-1 (TLS 防挂死 + 分域 Token + 证书/二维码工具) ──► S2-2 (REST 读/写 + SSE)
         ├──► S2-3 (独立 cloudflared 配置与 LaunchAgent 模板)           │
         └──► S2-4 (/rescue 极简应急 Web 页)                             │
                                                                         ▼
                                                                S2-5 (双轨安全与 API 实测) ──► Gate 2
```

---

## S2-1：TLS 传输层、安全鉴权、证书初始化与配对二维码

- **前置依赖**：Gate 1
- **并行性**：🟢 与 S2-3（除最终 `cert.pem` 联调外）/ S2-4 及跨阶段 S3-1 / S3-2 并行
- **改动 / 新增文件**：
  - `maa-remote/scripts/maa_daemon.py`（TLS Server 底座、来源 IP 拦截、Bearer Token 鉴权中间件）
  - `maa-remote/daemon/` 初始化与轮换脚本（如 `init_daemon.py` / `rotate_tls.py`，保持 stdlib 零依赖，二维码可用终端 Unicode 块字符或最小纯 Python QR 编码器）
  - `maa-remote/tests/test_daemon_security.py`
- **规格要点**：
  1. **防慢速/异常 TLS 握手挂死**：
     - 监听 `0.0.0.0:18170`；
     - `ssl.SSLContext.wrap_socket(..., do_handshake_on_connect=False)`；
     - 在 `ThreadingHTTPServer` 派生的连接工作线程中先设 `socket.settimeout(5.0)`，再调 `do_handshake()`，握手失败直接关闭 socket，绝不在主 `accept()` 线程握手。
  2. **来源 IP 收口**：
     - 仅放行 `127.0.0.1` 与 `192.168.50.0/24`（局域网），其余来源直接拒连。
  3. **分域 Bearer Token 鉴权**：
     - `daemon/secrets.json`（权限 `0600`）仅存 `full_token_sha256` 与 `resign_only_token_sha256`（常时间比对 `hmac.compare_digest`）；
     - `GET /healthz` 免鉴权（且响应不含任何账号/游戏敏感信息）；
     - `full` Token 可访问全部 `/api/v1/*`；
     - `resign_only` Token **仅允许** `POST /api/v1/ios/resign`（含 `?if_due=1`），访问任何其他接口一律返回 `403 Forbidden`。
  4. **证书生命周期与首次配对**：
     - **必须使用 Homebrew `/opt/homebrew/opt/openssl@3/bin/openssl` 显式加 `-pkeyopt ec_param_enc:named_curve`** 生成 5 年 ECDSA P-256 自签证书 `daemon/tls/cert.pem` + `key.pem`（`0600`），SAN 含 `IP:192.168.50.2` 与 `IP:127.0.0.1`（S0-3 实证：系统 LibreSSL 默认 explicit EC parameters 会被 Apple `SecCertificateCopyKey` 拒认）；
     - 计算 SPKI SHA-256 Base64 指纹；
     - 守护进程每日巡检 `cert.pem` 剩余有效期，到期前 60 天发 `timeSensitive` Bark 提醒（`id=tls-cert`）；
     - 初始化脚本在 Mac 终端输出配对 JSON 与一次性配对二维码（含 `lan_url`、`remote_url`、`spki_sha256`、`full_token`）。
- **验收清单**：
  - [ ] 模拟建立 TCP 连接后不发 TLS ClientHello（慢速半开连接），5 秒后自动断开且期间并发正常请求不受阻塞
  - [ ] 来源 IP 白名单、无效 Token 401、`resign_only` 越权 403 单测全绿
  - [ ] 证书生成、SPKI 指纹计算、到期前 60 天告警逻辑单测通过

---

## S2-2：REST 读/写端点（§5.1 + §5.2）与 SSE 广播引擎

- **前置依赖**：S2-1
- **并行性**：🟡 内部可按「读端点 + SSE 引擎」与「写端点 + `request_id` 取消表」两路并行；对外与 S2-3 / S2-4 并行
- **改动 / 新增文件**：
  - `maa-remote/scripts/maa_daemon.py`（或拆同目录辅助模块 `maa_api.py`，按 `deploy.py` `SCRIPT_NAMES` 登记）
  - `maa-remote/tests/test_daemon_api.py`、`maa-remote/tests/test_daemon_sse.py`
- **规格要点**：
  1. **读端点（§5.1）**：
     - `GET /healthz` → `{ok: true, service: "wados-maa", api_version: 1, server_time}`；
     - `GET /api/v1/snapshot` → 1 次 RTT 聚合 `{lock, last_run, progress, today_plan, schedule, upstream, copilot_auto_paused, activity, scheduler, resign}`；
     - `GET /api/v1/choices`、`GET /api/v1/copilot/stages`、`GET /api/v1/config`、`GET /api/v1/defaults`（复用 `maa_action.py` 对应 `data`）；
     - `GET /api/v1/history?limit=50&offset=0`（读 `runs/index.jsonl` 倒序分页 `{items, total, has_more}`）；
     - `GET /api/v1/runs/<id>/report`（按 `run_id` 定位，兼容旧 `<date>-<phase>` 命名，统一支持日常与抄作业）；
     - `GET /api/v1/runs/<id>/screenshot`（支持 `?thumb=1` 压缩预览与原图；严防路径穿越）；
     - `GET /api/v1/runs/<id>/log?tail=200`（只返尾部 N 行与 `truncated`）。
  2. **SSE 实时推送流（`GET /api/v1/events`）**：
     - 每 **25 秒**发送 `: keepalive\n\n` 防 Cloudflare 100s 空闲断连；
     - 监听 `state/maa/` 及当前运行 `runs/<run_id>.progress.json` 变更，按事件类型推送：`progress`（日常 & 抄作业）、`lock`、`last_run`、`today_plan`、`upstream`、`resign`。
  3. **写端点（§5.2，统一返回 `{ok, code, message, detail?, data?}`）**：
     - 严格动作白名单映射，后端受控组装 argv 调 `maa_action.py`（默认注入 `MAA_ACTION_SOURCE=ios`），绝不透传任意命令；
     - 覆盖：`/plan/stage`、`/plan/skip`、`/plan/fight`、`/run/local`、`/run/cancel`（**强制校验 body 中 `run_id`**）、`/copilot/preview`（接受客户端 UUID `request_id`，长请求超时 60s）、`DELETE /api/v1/copilot/preview/<request_id>`（按 `request_id` 终止进行中的搜索子进程或清理临时预览文件）、`/copilot/go`、`/copilot/auto`、`/copilot/mark`、`/schedule`（含 `depot_enabled` 并热重载调度器）、`/defaults`、`/config`、`/upstream/update`、`/notify/test`、`/ios/resign`（Phase 2 先接参数校验与 `not_configured` 占位，Phase 4 S4-1 接入真实续签）。
- **验收清单**：
  - [ ] §5.1 与 §5.2 全部 27 个端点（含 SSE）均有离线单测覆盖
  - [ ] `DELETE /api/v1/copilot/preview/<request_id>` 可可靠中止正在搜索的子进程
  - [ ] `/runs/<id>/*` 路径参数防穿越（`..`、`/` 均拒绝）
  - [ ] `ruff` / `pyright` 0 报错

---

## S2-3：独立 Cloudflare Tunnel 正式配置与 LaunchAgent 模板

- **前置依赖**：S0-2（隧道 UUID 与域名已就绪）、S2-1（证书路径定型）
- **并行性**：🟢 与 S2-2 / S2-4 可并行
- **新增文件**：
  - `maa-remote/daemon/wados-maa-cloudflared.yml.tmpl`（隧道 ID `dcd1aac1-ff11-4a1f-b91c-9fb37b045716`，**必须含 `protocol: http2`** 适配本机 TUN/fake-ip，`ingress` 指向 `https://127.0.0.1:18170`，`originRequest.caPool` 指向 `~/.wados-maa/daemon/tls/cert.pem`，兜底 `http_status:404`）
  - `maa-remote/daemon/io.github.ffkiyo7.wados-maa.cloudflared.plist`（开机自启、`KeepAlive=true`，日志落 `~/.wados-maa/logs/cloudflared.log`）
- **验收清单**：
  - [ ] 模板渲染出的配置文件通过 `cloudflared tunnel ingress validate`
  - [ ] `devhome` 联调期通过 `maa.luxraykit.com` 可正常反代至 `devhome` 守护进程，且与 `netease-mcp` 完全隔离

---

## S2-4：`/rescue` 极简应急 Web 页

- **前置依赖**：Gate 1（API 契约已在 §5 定型）
- **并行性**：🟢 与 S2-1 / S2-2 / S2-3 完全可并行
- **新增文件**：
  - `maa-remote/daemon/rescue.html`（零外部 CDN/JS/CSS 依赖单页 HTML，手机 Safari 友好布局）
- **规格要点**：
  - 仅支持输入 `full` Bearer Token（存于页面内存或可选 `sessionStorage`，不拼进 URL query）；
  - 严格限定 3 个救命功能：① 刷新并展示当前 `lock` / `last_run` / `progress` 状态；② 携带当前 `run_id` 触发 `POST /api/v1/run/cancel`（带二次确认）；③ 触发 `POST /api/v1/ios/resign`。
- **验收清单**：
  - [ ] 无外网静态资源依赖，Safari 移动端排版清晰可用
  - [ ] 错误 Token 提示鉴权失败；紧急停止必须携带 `run_id`

---

## S2-5：Phase 2 双轨安全与 API 实测验收

- **前置依赖**：S2-2, S2-3, S2-4
- **并行性**：🔴 严格串行（Phase 2 收口门禁）
- **实测项目（在 `devhome` 执行，动游戏项须避开线上窗口且核对线上锁空闲）**：
  1. 手机在**家里 Wi-Fi** 与 **外网 5G** 分别拉取 `/api/v1/snapshot`、订阅 `/api/v1/events` SSE；
  2. 发起 `copilot/preview` 并在搜索途中发 `DELETE /api/v1/copilot/preview/<request_id>` 确认子进程被中止；
  3. 发起手动场并通过 `/rescue` 与 API 带 `run_id` 取消，验证旧 `run_id` 被 `run_changed` 拒绝；
  4. 调用 `POST /api/v1/notify/test` 收到真机解密 Bark 推送；
  5. 实测慢速半开 TLS 连接不阻塞并发正常请求；
  6. 实测 `resign_only` Token 访问 `/api/v1/snapshot`、`/api/v1/run/cancel` 返回 `403`。
- **Gate 2 验收清单**：
  - [ ] 上述 6 项双轨实测全部通过
  - [ ] `unittest` / `ruff` / `pyright` 全部 0 报错
  - [ ] 线上 `~/.hermes` 与 Discord 全程零改动
