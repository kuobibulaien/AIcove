# 主动回复系统

> 最后更新：2026-11-01。2026-10-28 起去掉每日上限和最小间隔、频率改两档、可按角色单独设置（见 ADR0079 修订）。其余设计以 [12_判断与执行拆分方案](12_判断与执行拆分方案_20261012.md) 和 ADR0079（判断与执行拆分）、ADR0084（按会话只由一台设备负责）、ADR0053（无全局总开关）为准。
> 01～11 号旧方案（AI 管家工具流程、旁白式提醒、完全体总结等）已归档到 [05_历史归档/20261016_文档库修订/主动关怀系统/](../../05_历史归档/20261016_文档库修订/主动关怀系统/)，只作历史参考。

## 做什么

角色在合适的时机主动发消息，或者（可选）主动打电话。没有全局开关，由角色卡逐个勾选主动回复插件。自拍走行内 `<image>`（绘图已启用时强制快速方式，`forceInlineImageRoute`）。

## 流程

```text
用户发消息 ─► ① 清场计时：5 分钟没人说话
            ─► ② 门卫（代码）：夜间免打扰（默认关）、本机是否为负责设备
            ─► ③ 判断：按回复频率选提示词，模型可一次返回多个计划（{"triggers":[…]}）
            ─► ④ 定时间（代码）：时间段换算成具体时刻，套夜间规则
            ─► ⑤ 预生成：主聊天链路按「发送时刻」装配并写好回复；开了打电话时可调用 call_user
            ─► ⑦ 入库：再确认用户没插话，存触发器、缓存与指纹
            ─► ⑧ 到点执行：发消息，或来电响铃
```

- ③ 目前由用户选的「判断模型」（一个聊天模型）通过 `ChatModelDecisionAdapter` 回答，只回一行 JSON，解析失败按沉默。决策模型只留了端口 `ProactiveDecisionPort`，暂不接入（方案 12 §12）。
- 多个计划：同一时间段的重复计划丢弃，其余按时间排序；入库前清掉该会话原有的 AI 触发器。前一个发完后，还有剩余触发器时不重新判断。
- ⑥ 审稿已在 10-14 删除，⑤ 写完直接入库。
- 到点时指纹仍有效就直接用缓存；失效时前台回到 ③ 重新判断，后台不发、留给前台。
- 多台设备同时在线时，每个会话只由用户最后发消息的那台设备分析和发送（ADR0084）。

## 设置

| 项 | 取值 | 能否按角色覆盖 |
|---|---|---|
| 回复频率 | 默认／频繁，只决定用哪套判断提示词 | 能 |
| 夜间免打扰 | 默认关，时段 22:00～08:00 | 能（开关、起止时间） |
| 允许设提醒 | 开／关 | 能 |
| 允许主动来电 | 默认关 | 能 |

全局值在设置页改，角色编辑页进入时只读写并显示这个角色的覆盖项，可一键恢复；覆盖存在 `auto_reply_settings.contact_settings`。判断、发送引导等提示词在「工具提示词」总控和主动回复更多设置页改，读写同一份（ADR0092 修订）。

`AutoReplySettings` 里的 `dailyLimit`、`minIntervalMinutes` 只剩读写，没有任何逻辑使用，是待清理的残留字段。

## 触发器优先级

| 优先级 | 来源 | 作废条件 |
|---|---|---|
| high | 用户明确要求的提醒 | 不因新消息作废；到点仍要会话和提醒有效、本机是负责设备才发 |
| medium | 自动创建的普通关怀 | 用户发了新消息就作废 |
| low | 情感类消息 | 用户发了新消息就作废；只是打开聊天页不作废 |

作废以「创建时最后一条用户消息」为准，不看消息总数。

## 主动打电话

默认关。开启后角色按人设决定打电话还是发消息，3 条底线护栏见方案 12 §13。`call_user` 只记录草稿、不真拨，拿到开场白后单轮即停；连续漏接 2 次暂停。前台显示来电页，Android 后台走通知；每通来电的结局记在本机 SQLite 来电账本。

## 代码位置（`lib/src/features/`）

| 文件 | 职责 |
|---|---|
| `auto_reply/data/analyzer_scheduler.dart` | ① 清场计时与分析调度 |
| `auto_reply/data/background_service.dart` | 后台执行与发送门禁 |
| `auto_reply/domain/proactive_decision.dart` | ③ 判断题目、答案与判断端口 |
| `auto_reply/data/chat_model_decision_adapter.dart`、`context_analyzer.dart` | ③ 用聊天模型回答判断题；按配置选判断端口 |
| `auto_reply/data/proactive_planner.dart` | ④ 纯函数的定时规则 |
| `auto_reply/data/proactive_message_pregenerator.dart`、`proactive_reply_generator.dart` | ⑤ 预生成 |
| `auto_reply/data/auto_reply_trigger.dart`、`auto_reply_trigger_storage.dart`、`auto_reply_trigger_controller.dart` | 触发器模型、存储与顺序事件总线 |
| `auto_reply/data/auto_reply_claim_store.dart` | 前后台原子认领，防止重复发送 |
| `auto_reply/data/auto_reply_dispatch_service.dart` | ⑧ 到点执行动作 |
| `auto_reply/data/proactive_owner_device.dart` | 会话→负责设备的同步映射（ADR0084） |
| `auto_reply/domain/proactive_action.dart`、`data/proactive_call*.dart`、`data/incoming_call*.dart` | 主动动作、来电与来电账本 |
| `plugins/trigger/trigger_agent_plugin.dart` | 提醒工具与触发器插件（内核 v2 插件） |
