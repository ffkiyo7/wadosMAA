# 本机 ADB 换成 Landship 库内那份（模拟器时期）

- 日期：2026-11-03
- 一句话：路径不能带空格，BlueStacks 的 `hd-adb` 弃用
- 相关不变量：—
- 现行机制：DEV_GUIDE 已不适用（设备层已换成 PlayCover）

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 4 条**

4. **本机 ADB 是 Landship 库内的 `sdk/platform-tools/adb`**（Homebrew 那份校验和对不上未装），
   `config.json` 和 maa-cli profile 都指向它，换模拟器时两处都要改。**路径不能带空格**：
   MaaCore 经 shell 调 adb 不加引号，所以 `~/Library/Application Support/Landship/bin/adb`
   用不了。2026-11-03 之前是 BlueStacks 自带的 `hd-adb`（`127.0.0.1:5555`）。
