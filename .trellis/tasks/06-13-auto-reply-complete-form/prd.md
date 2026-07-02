# 主动回复完全体落地：阶段0-2实施

## Goal

按 `opusdocs/主动回复完全体方案.md`（2026-06-13，已与用户逐分支确认）实施：

- 阶段 0（止血）：后台即时生成接入人设+输出约束；后台任务补 quietHours/dailyLimit/minInterval 门禁；trigger 事件顺序消费（AR-034）。
- 阶段 1（收敛）：预生成「短用缓存、长即时生成」+ 状态机删 preparing（AR-021）；触发器执行权原子认领互斥（AR-001/002/030）；WorkManager inputData 瘦身 + 配置现读。
- 阶段 2（遗留）：XML 兜底默认关闭（AR-040）；后台消息多模态补渲染；SessionManager 残留清理（AR-041/042）；补集成测试（AR-044）。
- 阶段 3：仅把记忆联动接口契约写入 `.trellis/spec/agent-context/index.md`。

## 已确认的设计决策（用户拍板）

1. 投递通道：纯本地做扎实（Android WorkManager + 前台保活；iOS/桌面打开补发）。
2. 预生成：delay ≤ 60min 用 cachedContent；> 60min 到点即时生成，缓存降级为兜底。
3. 后台生成：带人设的简化链路（人设 system prompt + 时间感知 + 上下文 + 旁白 as last user；禁工具/多模态标签）。
4. 愿景层只正式纳入记忆联动；人设频率/多模态主动/她的世界进远期展望。

## Requirements

- 后台生成提示词不得硬编码，走 prompt defaults 节点。
- 触发器持久化迁移到 SQLite 时保留 SharedPreferences 数据迁移与后台 isolate 可读性。
- 聊天主链路行为不回退；每步跑定向测试 + dart analyze。
- 大改动拆阶段提交，每阶段可独立回滚。

## Acceptance Criteria

- [ ] 后台即时生成的 messages 含角色人设 system prompt 与输出约束，文案口吻与前台一致。
- [ ] quiet hours / dailyLimit / minInterval 在后台任务执行前生效（allowNight 触发器豁免夜间限制）。
- [ ] 同 tick 多个触发器事件不丢失。
- [ ] delay > 60min 的触发器到点即时生成，失败回退缓存候选。
- [ ] 触发器状态机不再有 preparing。
- [ ] 前后台并发触发只发一条（原子认领）。
- [ ] WorkManager inputData 不含 apiKey/model，执行时现读配置。
- [ ] XML 兜底默认关闭。
- [ ] 打开 App 后后台纯文本消息可补渲染多模态。
- [ ] 新增/更新测试全部通过；定向 dart analyze 无新增问题。

## Out of Scope

- 云端推送通道、人设驱动频率、多模态主动消息原生支持、生活模拟。
- 记忆联动的运行时实现（只写契约）。
