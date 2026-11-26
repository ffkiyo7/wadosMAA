# 全量 Review 流程（轻量版，2026-11-25，北京时间）

> 用途：ROADMAP M0「全量只读 Review」怎么做。只设计，不开跑。
> 依据：Anthropic 公开的 review 做法（笔记 `~/Developer/cc-scratch/2026-11-25-review-research/notes.md`），按个人项目的规模（280 个文件，约 6.4 万行）裁剪。
> 规模：大约 6～8 个 agent，一个下午做完。

## 原则

- 发现问题和验证问题分开，由不同的 agent 做。
- 每条结论都带 file:line，不凭函数名推断。
- 只报会出错的问题，不报风格、格式，也不报「建议加测试」。不确定就不报，没找到问题也是正常结果。
- reviewer 只读代码，不改代码，也不运行。需要运行的检查在第 1 步先跑。
- 注释里写的「已校验」「不会发生」要回到代码里核实。

## 流程

### 1. 先跑不花模型额度的检查

- 后端：`python3 -m unittest discover -s tests`、`uvx ruff@0.17.3 check`、`uvx pyright@1.1.414`。
- Swift：`swift test --package-path shared`；Mac App 和 iOS App 各编译一次。
- 部署：`python3 deploy.py --standalone --check`，核对线上和仓库是否一致。
- 线索：`uvx vulture maa-remote/scripts --min-confidence 80` 找死代码；`rg -c 'discord|hermes|HERMES_HOME'` 统计历史遗留；密钥扫描直接用 agy 跑过的 gitleaks 结果。

这些结果作为背景交给下一步的 reviewer。

### 2. 找问题：并行跑 4 个 reviewer，再加 1 个出表格

所有 reviewer 共用同一份背景说明，不再单独派 agent 梳理全局：

- DEV_GUIDE 的 §8 不变量、§12 本机接口、§13 HTTP API；
- 硬约束：不吃理智药（临期药除外）、不碎石、不借助战、动游戏必须持 `run.lock`；
- 两个运行根目录；
- `HANDOFF.md` 里已知的问题（命中就标「已知」，不重复报）。

| # | 负责范围 | 主要文件 | 重点看 | 模型 |
|---|---|---|---|---|
| ① | 公网入口和守护进程 | `maa_api.py`、`maa_tls.py`、`maa_daemon.py`、`maa_schedule.py`、`daemon/rescue.html` | 从公网经 Cloudflare Tunnel 能否越权；Token 分域；重启会不会杀掉正在跑的场次；定时任务漏跑或重跑 | Opus |
| ② | 日常和抄作业执行链 | `maa_daily.py`、`maa_farming.py`、`maa_playcover.py`、`maa_clearing.py`、`maa_copilot*.py` | 违反硬约束；把失败报成成功（战报失真）；恢复逻辑；挑 `fix` 提交里最常见的几类 bug，看别处还有没有同类 | Opus |
| ③ | 公共底座、动作入口、运维和外部数据 | `maa_common.py`、`maa_settings.py`、`maa_action.py`、`deploy.py`、`daemon/*.py`、`maa_ios_resign.py`、`maa_skland.py`、`maa_notify.py` 等 | 锁协议和原子写；往 `~/.hermes` 写；凭据处理；外部接口返回格式变了怎么办 | Sonnet |
| ④ | 跨端契约 | 后端：§12、§13 相关代码；App 端：`shared/Sources`、`ios/…/Core`、`gui/…/Remote` | 两端字段名、可选或必填、枚举值、日期格式能否对上；iOS 的 SPKI 固定；拒绝读写 `~/.hermes` | Opus |
| ⑤ | 对账表格（不找 bug） | DEV_GUIDE §8 和全仓代码 | 67 条不变量各在哪里实现、由哪个测试守着；死代码和 Discord/Hermes 遗留分成「直接删 / 等 F1 / 还在用」三类 | Sonnet |

每条结论写成：file:line、问题、怎么触发、后果、修法、严重程度（严重 / 一般 / 小）。每个 reviewer 最多报 5 条小问题。

**做完这一步停下来**，先看一眼候选列表再往下走。

### 3. 验证：只验证「严重」的

- 每条严重的候选派 1 个 verifier。它默认当误报处理，要认定成立，必须给出 file:line 证明三件事：默认配置下真的能触发、会造成实际后果、别处没有兜住。
- 一般和小问题不单独验证，只由主会话自己读代码抽查。

### 4. 报告

写成一份 `docs/REVIEW_2026-11-xx.md`，格式沿用 11-09 那份：

- 一句话结论；
- 按「严重 / 一般 / 小 / 已知」列出问题；
- 附上第 ⑤ 步的两张表；
- 末尾一段「哪些没审到」；
- 每条问题都写明归到 ROADMAP 的哪个阶段，或者标「不修」并说明理由。

## 不做的事

- review 期间不改代码、不提交、不部署、不 push。要修的另起任务，等放行。
- UX 走查不走这套流程：要拿着真机看，按 ROADMAP 单独做。

## 更省事的备选

按 ①～④ 的路径分组，各跑一次内置的 `/code-review high <路径>`。它自带找问题和验证，最省额度；代价是四份结果格式不统一，最后要手动合成一份报告。第 ⑤ 步的表格照样单独出。
