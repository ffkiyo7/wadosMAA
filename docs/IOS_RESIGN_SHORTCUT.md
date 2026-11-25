# 回家自动续签：快捷指令配置（Phase 4 S4-2）

Mac mini 本来就会在续签窗口里每 25 分钟找一次手机（DEV_GUIDE §13.4）。这条快捷指令只是加速：手机一连上家里 Wi-Fi 就叫 Mac 看一眼，到时间了马上续，没到时间什么也不做。

## 1. 在 Mac 上拿一个续签专用 Token

```bash
python3 ~/.wados-maa/scripts/maa_ios_resign.py shortcut-token
```

输出里的 `resign_only_token` 只显示这一次，旧的随之作废。这个 Token 只能调续签接口，调别的接口一律 403。

## 2. 在 iPhone 上建个人自动化

快捷指令 → 自动化 → 新建个人自动化 → **无线局域网**：

- 网络：勾选 `Alice3u3` 和 `Aliceuwu`；
- 选「立即运行」，关掉「运行前询问」和「运行时通知」。

动作有两个，第一个是「等待」，设 10 秒。自动化在刚连上 Wi-Fi 时就触发，那时手机往往还没联网，直接发请求会报「互联网已断线」。

第二个是「获取 URL 内容」：

| 项 | 值 |
|---|---|
| URL | `https://maa.luxraykit.com/api/v1/ios/resign?if_due=1` |
| 方法 | `POST` |
| 头部 | `Authorization` = `Bearer <第 1 步的 Token>` |
| 请求体 | JSON，留空 |

走公网域名而不是局域网 IP：Cloudflare 的证书是正规证书，快捷指令不认自签证书。

## 3. 回执

| HTTP | `code` | 意思 |
|---|---|---|
| 200 | `not_due` | 没到续签时间，什么也没做 |
| 202 | `started` | 开始续签，几分钟后 App 会被新版覆盖（App 会退出） |
| 409 | `running` / `run_locked` | 已经在续签，或正在跑游戏；结束后守护进程会自己续 |
| 501 | `not_configured` | Mac 的 `daemon.json` 没配 `ios_device_udid` |

续签结果看 App「设置 → iOS 签名」，或 Mac 上 `python3 ~/.wados-maa/scripts/maa_ios_resign.py status`。
