# 拿相邻顶层键当 YAML 锚点写坏 config.yaml，全部 cron 提前 8 小时

- 日期：2026-09-03
- 一句话：Hermes 重排键顺序后提示词插进了 `skills:` 块，YAML 解析失败、时区回退
- 相关不变量：—
- 现行机制：DEV_GUIDE §7 第 4 步

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 17 条**

17. **拿相邻顶层键当 YAML 锚点会写坏 config.yaml，代价是全部 cron 提前 8 小时**——
    旧 `patch_config_yaml()` 把频道提示词插在 `timezone: Etc/UTC` 之前，假定它紧跟
    `channel_prompts:`。2026-09-03 Hermes 重排了键顺序，`timezone` 落到了 `skills:`
    之后，于是那行 6 空格缩进的提示词插进了 `skills:` 块里，YAML 解析失败。
    Hermes 静默回退默认配置 → `timezone: Etc/UTC` 失效 → cron 全按本机 `+08:00` 解释，
    每个 job 都提前 8 小时跑。修法见 §7 的锚点说明；判断线上是否中招：
    `hermes cron list` 的 `Next run` 带 `+08:00` 而不是 `+00:00`。

---

**原文出处：§7「给 Hermes 打补丁」下的说明**

> `patch_config_yaml_text()` 只认 `channel_prompts:` 这一行做锚点（缩进按块内实际
> 缩进推导），**不许拿相邻的顶层键（如 `timezone`）当锚点**——键顺序归 Hermes 管，
> 会变（见 §11.17）。是否需要插入按 `yaml.safe_load` 的**解析值**判断而不是字面量，
> 这样 Hermes 折行重排过文本也不会重复插入；**替换**旧文案同样按解析值判断，
> 并由 `_replace_channel_prompt()` 连同折行的续行一起换掉（§11.17b）。写盘前后各解析一次，
> 顶层 `timezone` 丢失/被改、或 `platforms.discord.channel_prompts[<频道>]`
> 不等于目标文案就 `RuntimeError` 且不落盘；config.yaml 在打补丁前就解析不了也直接拒绝。
