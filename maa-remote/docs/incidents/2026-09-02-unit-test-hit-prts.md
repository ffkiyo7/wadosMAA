# 单测顺手打了真实的 prts.plus

- 日期：2026-09-02
- 一句话：一条缓存 TTL 用例连真网，整套又慢又会被 SSL EOF 判红
- 相关不变量：#43
- 现行机制：DEV_GUIDE §9「单测必须离线可跑」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§9「单测必须离线可跑」**

### 单测必须离线可跑

**整套单测不许碰网络**，一条都不许。曾经有一条 `test_search_copilots_respects_cache_ttl`
在验缓存 TTL 时顺手调了真实的 prts.plus，结果整套测试既慢（15～59s）又会被对方
一次 SSL EOF 判红——「全绿」这个验收标准就此不可信。现在网络层由
`tests/test_copilot.py: prts_http_stub()` 桩掉，整套 2.4s。

**一图流 / 企鹅物流那条出口在每个测试模块的 `setUpModule()` 里被整个封死**
（`tests/_helpers.py: start_module_patches()` 模块级 patch 掉 `maa_farming._http_json`，
游戏数据 `maa_gamedata._fetch` / `load_layout` 同理）。这一层不是洁癖：抓取层默认把缓存写进
**线上** `~/.hermes/state/maa/farming/`，一条漏了打桩的用例既会打对方接口，又会往运行时
状态里塞一份带假时间戳（用例的 `at=`）的缓存，把线上数据冻到那个未来时刻。
需要自己造响应的用例在 `with patch.object(maa_farming, "_http_json", …)` 里覆盖它；
其余用例一律传 `data=`。**断网复核抓不到这一类**——抓取层吞掉所有异常只降级，
不会让测试变红，所以这道模块级闸门是唯一的防线。
（另：`_cache_age()` 把「未来的 `fetched_at`」一律当成不新鲜，写坏的缓存最多多抓一次。）
