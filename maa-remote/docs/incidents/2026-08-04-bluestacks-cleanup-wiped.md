# 卸 BlueAI 把 BlueStacks 连同实例数据一起删光（模拟器时期）

- 日期：2026-08-04
- 一句话：BlueStacks 的清理 LaunchDaemon 发现三件套少一个就全删
- 相关不变量：—
- 现行机制：DEV_GUIDE 已不适用（设备层已换成 PlayCover）

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 12 条**

12. **（BlueStacks 时期）动 BlueStacks 三件套里的任何一个，整套会被连坐删除**——安装包附带 LaunchDaemon
    `/Library/LaunchDaemons/com.now.gg.BlueStacks.cleanup.plist`，`WatchPaths` 盯着
    `/Applications/BlueStacks.app`、`/Applications/BlueAI.app`、
    `/Applications/BlueStacks Air multi-instance manager.app`。任一路径变动即触发
    `/Library/Application Support/BlueStacks/BlueStacksCleanup`，而该脚本的判定是
    「三个里少任何一个」就把三个连同 `/Users/Shared/Library/Application Support/BlueStacks`
    全部 `rm -rf`，收尾还会删掉自己和那个 plist（所以事后翻 `LaunchDaemons` 什么也找不到）。

    2026-08-04 22:17:55 用 mole 卸载捆绑的 BlueAI，就这样把模拟器和实例数据一起清空了；
    `/var/log/bst_cleanup.log` 留有带时间戳的完整记录，是排查这类「模拟器凭空消失」的第一现场。

    - **症状**：场次 0.x 秒内 `return_code=1`、`runs/<date>-<phase>.log` 根本没生成、
      `last_run.thread_id=null`、战报七项全「未执行」。因为 `adb_path` 指向
      `/Applications/BlueStacks.app/Contents/MacOS/hd-adb`（当时的配置），bundle 一没
      `require_executable()` 就抛，比 `open_emulator()` 还早一步。
    - **要卸 BlueAI 就先拆引信**：`sudo launchctl bootout system
      /Library/LaunchDaemons/com.now.gg.BlueStacks.cleanup.plist` 并删掉该 plist，再动 app。
      直接 `mo uninstall` / 拖废纸篓都会引爆。
    - **重装不恢复实例数据**，得重走一遍：`brew install --cask bluestacks`（pkg 装机要 sudo，
      无 TTY 时用 `open` 调 GUI 安装器）→ 重建实例（4 核 / 4GB / **1920×1080 横屏**，
      默认实例是 1080×1920 竖屏，横屏不改 MAA 必然识别不到）→ 装国服 APK → 重新登录。
    - **国服 APK 官方下载链**：`https://ak.hypergryph.com/downloads/android_lastest` → 302 →
      `https://launcher.hypergryph.com/game/latest/GzD1CpaWgmSq1wew/1/1` → 302 → `ak.hycdn.cn`
      上的 `arknights-hg-<版本>.apk`（2.7.61 约 2.0GB）。装前可验签名者应为
      `CN=HyperGryph, O=HyperGryph, L=Shanghai`：
      `unzip -p <apk> META-INF/ARKNIGHT.RSA | openssl pkcs7 -inform DER -print_certs -text`。
