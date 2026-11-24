# maa-remote

在 macOS 上用 [MAA](https://github.com/MaaAssistantArknights/MaaAssistantArknights) 自动跑《明日方舟》国服日常，
从 Mac App 或 iPhone App 查看和操作。游戏是 PlayCover 里的原生 iOS 版。

- 早晚各一场：开跑前 10 分钟定好这一场的关卡（按材料缺口自动选关），到点跑完整日常：剿灭、刷理智、基建、公招、信用商店、领奖，跑完回到主界面
- 跑完写中文战报和截图，用 Bark 加密推送到手机，然后关掉游戏
- 新活动上线后，自动从 prts.plus 找作业，把活动关打一遍
- 手机上随时看进度、换关、跳过、手动开一场、停止、抄指定关

自用项目，只在 Apple Silicon Mac + PlayCover 国服上跑过。配置和状态文件的格式随时可能改。

> ⚠️ 非官方工具，和鹰角、森空岛、MAA 官方都没有关系。用自动化可能违反游戏用户协议，账号风险自己承担。
> 森空岛接口是社区逆向出来的。仓库里没有任何凭据。

## 架构

一个常驻守护进程 `maa_daemon.py`（LaunchAgent），其余都是跑完就退的脚本，数据都在 `~/.wados-maa/`。

| 时间（北京） | 任务 |
|---|---|
| 每 15 分钟 | `maa_activity_watch.py`：活动自动抄作业 |
| 04:30 | `maa_depot.py`：仓库对表，满 7 天才开游戏；默认关闭 |
| 早晚场前 10 分钟（默认 07:50 / 21:50） | `maa_plan_card.py`：定这一场的关卡；早场顺带更新 maa-cli / MaaCore |
| 早晚场（默认 08:00 / 22:00） | `maa_daily.py`：日常 |
| App 操作 | `maa_action.py`：唯一能改状态的入口 |

守护进程还提供 HTTPS + SSE 接口（端口 18170，Bearer Token + SPKI 固定证书），iPhone 在家直连、在外经 Cloudflare Tunnel；`/rescue` 是浏览器能开的应急停止页。

**仓库不是运行目录**：改完代码要跑 `deploy.py --standalone`，脚本才会拷进 `~/.wados-maa/`。

## 环境

- Apple Silicon Mac；Python 3.9+，只用标准库
- [PlayCover 的 MAA 分支](https://github.com/hguandl/PlayCover) 装好明日方舟国服，开启 MaaTools，端口 `1717`
- maa-cli（`brew install MaaAssistantArknights/tap/maa-cli`）
- 用 [BetterDisplay](https://github.com/waydabber/BetterDisplay) 建一块虚拟屏 `MAA-Game`，给游戏窗口单独用。窗口不在屏上时，MaaTools 截不到图
- 给 `~/.wados-maa/scripts/wados-maa-launcher` 开「辅助功能」权限，用来挪游戏窗口
- Homebrew 的 OpenSSL 3（生成证书）、`cloudflared`（远程访问）、[Bark](https://github.com/Finb/Bark)（推送）

## 部署

```bash
python3 -m unittest discover -s tests
```

```bash
python3 deploy.py --standalone
```

```bash
python3 deploy.py --standalone --check
```

部署后用 `launchctl kickstart -k gui/$(id -u)/io.github.ffkiyo7.wados-maa.daemon` 重启守护进程。
新机器第一次装：先部署，再跑 `daemon/init_daemon.py` 生成证书、Token 和配对二维码，把 `~/.wados-maa/daemon/` 下渲染好的两个 plist 装进 `~/Library/LaunchAgents/`。细节见 [DEV_GUIDE](./docs/DEV_GUIDE.md) §7、§13。

## 文档

- [docs/DEV_GUIDE.md](./docs/DEV_GUIDE.md)：链路怎么串起来、配置项（§6.2）、部署（§7）、不能破坏的约定（§8）、出问题先看哪里、踩过的坑、App 接口（§12、§13）
- [docs/incidents/](./docs/incidents/README.md)：事故记录
- [docs/spikes/](./docs/spikes)、[docs/archive/](./docs/archive)：实测记录和历史方案；[docs/DISCORD_GUIDE.md](./docs/DISCORD_GUIDE.md) 是切线前 Discord 时期的使用说明

## 致谢与许可

全部通过命令行或 HTTP 调用，不含下面这些项目的源码：MAA / maa-cli（AGPL-3.0）、
[prts.plus](https://prts.plus)、[明日方舟一图流](https://ark.yituliu.cn) 和 [企鹅物流](https://penguin-stats.io)（数据按 CC BY-NC 4.0 使用，会匿名上报掉落）。

[MIT](./LICENSE) © 2026 ffkiyo7
