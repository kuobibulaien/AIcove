# 日志中心全链路监控重构方案

> 版本：v1.0  
> 创建日期：2026-03-02  
> 状态：待实施

---

## 1. 这次要解决什么

当前日志中心已经能看到很多数据，但更像“原始录像堆”。  
真正的问题不是“没有日志”，而是“没有一条完整时间线把日志串起来”。

可以用一个类比：
- 现在：有前台监控、厨房监控、后厨监控，但要人工对时间拼接。
- 目标：像航班黑匣子，一次请求从起飞到落地全自动回放。

---

## 2. 改造目标（必须达到）

1. 一次用户发送，生成一条完整 `Turn Trace`（可回放）。
2. 每一轮都能看到 AI 真正收到的完整上下文（`messages`）。
3. 每一轮都能看到完整请求体与完整回包（非摘要）。
4. 工具调用必须有“参数、开始、结束、结果、错误、耗时”。
5. UI 默认看人话摘要，支持一键展开原始 JSON 细节。
6. 导出时可直接用于排障，不需要二次拼装。

---

## 3. 现状与缺口

## 3.1 已有基础（可复用）

- 请求/响应完整字段已存在：`rawContext/rawRequestBody/rawResponseBody/rawToolCalls/rawToolResults/finalReply`
  - 文件：`lib/src/core/api_logger.dart`
  - 产生位置：`lib/src/core/api/agent_api.dart`、`lib/src/features/chat/services/chat_send_api_runner.dart`
- 按 turn/round 聚合能力已存在
  - 文件：`lib/src/ui/features/settings/pages/log_formatters.dart`
- 日志页面可展示对话轮次
  - 文件：`lib/src/ui/features/settings/pages/log_viewer_page.dart`

## 3.2 关键缺口（要补）

1. 缺统一事件模型：不同模块写日志，字段语义不一致。
2. 缺标准阶段字典：同一阶段在不同文件命名不统一。
3. 缺时序视图：现在更像“多段文本”，不是“流程时间线”。
4. 缺隐私分级：完整上下文默认明文，调试和生产口径未分离。
5. 缺存储分层：大字段全部直接进日志，长期会导致查询和渲染变慢。

---

## 4. 功能 ↔ 文件（排障定位表）

| 功能 | 文件 | 说明 |
|---|---|---|
| 用户发送入口 | `lib/src/features/chat/chat_actions.dart` | 从“点击发送”到“最终交付”总入口 |
| 请求编排 | `lib/src/features/chat/services/chat_send_service.dart` | 组织配置、历史、API 调用 |
| 多轮与工具主循环 | `lib/src/features/chat/services/chat_send_api_runner.dart` | round 循环、工具执行、final_response |
| 模型直连请求 | `lib/src/core/api/agent_api.dart` | 构建请求、流式聚合、落 API 对话日志 |
| API 对话日志结构 | `lib/src/core/api_logger.dart` | `ApiLogEntry` 字段定义与落盘 |
| 系统 Trace 日志 | `lib/src/core/app_logger.dart` | `traceId`、层级日志 |
| 日志中心 UI | `lib/src/ui/features/settings/pages/log_viewer_page.dart` | 当前展示、筛选、复制、导出 |
| 日志聚合与格式化 | `lib/src/ui/features/settings/pages/log_formatters.dart` | turn/round 聚合、工具轨迹解析 |
| 历史日志管理 | `lib/src/core/log_history_service.dart` | 历史文件读取、清理策略 |
| 流式成功率统计 | `lib/src/features/chat/services/stream_monitor_service.dart` | 流式尝试/成功/回退统计 |

---

## 5. 目标架构（重构后）

```
用户发送
  -> TurnTrace.start()
  -> 阶段事件连续写入（统一 schema）
  -> round 内模型请求/工具调用事件
  -> 最终交付事件
  -> TurnTrace.end()
  -> 日志中心按 turn 读取并回放
```

### 5.1 四层架构

1. 采集层（Instrumentation）
- 在关键阶段打点，统一调用 `TraceEventRecorder.record(...)`。

2. 归档层（Storage）
- 摘要索引 + 大字段分离存储。
- 大字段（上下文/请求体/回包）单独存，索引用引用路径。

3. 聚合层（Query）
- 按 `sessionId + turnId` 聚合，按 `roundIndex + eventSeq` 排序。

4. 展示层（UI）
- 总览（Turn 列表） -> 时间线（Stage） -> 载荷（Payload Inspector）。

---

## 6. 数据模型设计（统一标准）

## 6.1 TraceTurn（一次用户发送）

```json
{
  "traceId": "tr_xxx",
  "sessionId": "conv_xxx",
  "turnId": "msg_xxx",
  "startedAt": "2026-03-02T20:00:00.000Z",
  "endedAt": "2026-03-02T20:00:03.500Z",
  "status": "success",
  "totalDurationMs": 3500,
  "roundCount": 2
}
```

## 6.2 TraceEvent（阶段事件）

```json
{
  "traceId": "tr_xxx",
  "sessionId": "conv_xxx",
  "turnId": "msg_xxx",
  "roundIndex": 1,
  "eventSeq": 12,
  "stage": "MODEL_RESPONSE_RECEIVED",
  "status": "success",
  "source": "AgentApiClient",
  "startedAt": "2026-03-02T20:00:01.000Z",
  "endedAt": "2026-03-02T20:00:01.900Z",
  "durationMs": 900,
  "payloadRef": {
    "rawContextPath": "...",
    "rawRequestBodyPath": "...",
    "rawResponseBodyPath": "..."
  },
  "meta": {
    "provider": "openai",
    "modelFullId": "openai:gpt-4o-mini",
    "toolCallsCount": 1
  }
}
```

## 6.3 Stage 字典（固定枚举）

- `TURN_STARTED`
- `USER_MESSAGE_PERSISTED`
- `HISTORY_PREPARED`
- `API_CONFIG_READY`
- `ROUND_REQUEST_BUILT`
- `MODEL_REQUEST_SENT`
- `MODEL_RESPONSE_RECEIVED`
- `MODEL_STREAM_AGGREGATED`
- `TOOL_CALL_DETECTED`
- `TOOL_EXEC_STARTED`
- `TOOL_EXEC_FINISHED`
- `ROUND_COMPLETED`
- `FINAL_REPLY_READY`
- `MESSAGE_DELIVERED`
- `TURN_COMPLETED`
- `TURN_FAILED`

---

## 7. 关键链路落点（改哪里）

## 7.1 `chat_actions.dart`

新增/补齐：
- `TURN_STARTED`
- `USER_MESSAGE_PERSISTED`
- `MESSAGE_DELIVERED`
- `TURN_COMPLETED / TURN_FAILED`

作用：
- 负责总时间线首尾闭环。

## 7.2 `chat_send_service.dart`

新增/补齐：
- `HISTORY_PREPARED`
- `API_CONFIG_READY`

作用：
- 把“发给 AI 前到底准备了什么”记录清楚。

## 7.3 `agent_api.dart`

新增/补齐：
- `ROUND_REQUEST_BUILT`
- `MODEL_REQUEST_SENT`
- `MODEL_RESPONSE_RECEIVED`（非流）
- `MODEL_STREAM_AGGREGATED`（流式）

作用：
- 保证每轮 `rawContext/rawRequestBody/rawResponseBody` 全量可追踪。

## 7.4 `chat_send_api_runner.dart`

新增/补齐：
- `TOOL_CALL_DETECTED`
- `TOOL_EXEC_STARTED`
- `TOOL_EXEC_FINISHED`
- `ROUND_COMPLETED`
- `FINAL_REPLY_READY`

作用：
- 完整记录工具执行细节和多轮迭代过程。

---

## 8. UI 重构方案（不再繁琐）

## 8.1 页面结构

1. Turn 总览页（默认）
- 一行就是一次用户发送。
- 只看关键信息：成功/失败、总耗时、轮次、工具次数。

2. Round 时间线页
- 像调用栈时间轴，按阶段排列。
- 每阶段展示：开始时间、耗时、状态、错误摘要。

3. Payload 检查器
- 标签页：`Context / Request / Response / ToolCalls / ToolResults / FinalReply`
- 支持 JSON 折叠、搜索、复制当前块。

## 8.2 默认视图策略（降噪）

- 默认不展示原始 `streamEvents`，只展示聚合文本。
- 提供开关“显示原始流事件（高级）”。
- 工具结果默认显示摘要（成功/失败/耗时），点开看完整 JSON。

---

## 9. 隐私与安全策略（必须执行）

1. 默认脱敏导出
- API Key、Authorization、Cookie、手机号、邮箱等替换为 `***`。

2. 全量模式仅本地调试可用
- 需要用户手动开启“高级调试模式”。

3. 大字段长度策略
- UI 默认显示截断版；复制可拿全量（如果开启）。

4. 系统提示词保护
- 继续复用 `system` 文本截断策略，避免误泄露长提示词。

---

## 10. 性能与存储策略

1. 日志分层存储
- `index.jsonl`（轻量摘要）
- `payload/*.json`（大字段）

2. 生命周期
- 保留 7 天（沿用现有策略），支持按天清理。

3. 查询优化
- 列表页只读摘要索引。
- 详情页按需加载 payload 文件。

4. 防卡死
- base64 继续清理（沿用 `sanitizeBase64InJson`）。

---

## 11. 实施分单元（每次不超过 3 文件）

## 单元 A：数据模型与仓储骨架

- 新增：`lib/src/features/observability/trace_models.dart`
- 新增：`lib/src/features/observability/trace_store.dart`
- 改：`lib/src/app.dart`（初始化）

产出：可写入标准 Trace 事件。

## 单元 B：发送入口埋点

- 改：`chat_actions.dart`
- 改：`chat_send_service.dart`
- 改：`chat_types.dart`（补 trace 上下文）

产出：从发送开始到交付结束形成闭环。

## 单元 C：模型链路埋点

- 改：`agent_api.dart`
- 改：`api_logger.dart`

产出：每轮完整请求/响应可回放。

## 单元 D：工具执行埋点

- 改：`chat_send_api_runner.dart`

产出：工具全生命周期可见。

## 单元 E：查询聚合

- 新增：`trace_query_service.dart`
- 改：`log_models.dart`
- 改：`log_formatters.dart`

产出：统一 turn/round/stage 聚合结果。

## 单元 F：新日志中心 UI

- 改：`log_viewer_page.dart`
- 新增：`trace_timeline_panel.dart`
- 新增：`trace_payload_panel.dart`

产出：可视化监控界面。

## 单元 G：历史与导出

- 改：`log_history_service.dart`
- 改：`log_history_detail_page.dart`
- 新增：`trace_export_service.dart`

产出：可追溯历史文件与标准导出。

---

## 12. 测试方案（先复现再修复）

## 12.1 单元测试

1. `trace_event_order_test.dart`
- 验证同一 turn 内 `eventSeq` 单调递增。

2. `trace_round_aggregation_test.dart`
- 验证 round 聚合准确（请求、工具、最终回复都能匹配）。

3. `trace_payload_redaction_test.dart`
- 验证导出脱敏生效。

## 12.2 集成测试

1. 文本直答路径（无工具）
- 应生成完整阶段链路。

2. 工具调用路径（draw_image/speak）
- 应有工具开始/结束/结果/失败信息。

3. 流式回退路径
- 应记录 `MODEL_STREAM_AGGREGATED` 失败与回退原因。

4. 多轮工具路径（stable/fast）
- round 数正确，第二轮时序正确。

## 12.3 手工验收

1. 日志中心按 turn 查看不混乱。  
2. 任意一轮都能看到完整 `messages/rawRequestBody/rawResponseBody`。  
3. 导出文件可直接给开发复现。  
4. 启动与滚动不卡顿。  

---

## 13. 里程碑与验收标准

## M1（可用）
- 完成 A+B+C
- 验收：一条 turn 能看到完整请求链路和上下文

## M2（完整）
- 完成 D+E+F
- 验收：工具链路、时间线、可视化面板可用

## M3（可运维）
- 完成 G + 脱敏 + 历史导出
- 验收：导出标准化、隐私可控、历史可查

---

## 14. 基础操作检查清单（排障必查）

1. 是否执行 `flutter pub get`。  
2. 是否使用最新构建安装到设备（排除旧包）。  
3. 模型 Provider / API Key 是否配置完整。  
4. 涉及接口时后端是否已启动。  
5. 当前调用模式是否为预期（fast/stable）。  
6. 网络是否可访问目标模型服务。  

---

## 15. 本方案对“日志中心”的最终形态

重构后日志中心不再是“杂乱文本清单”，而是：
- 一次会话一条主线；
- 每轮请求一眼看懂；
- 每个工具有完整轨迹；
- 每个异常都能定位到具体阶段和输入上下文。

这就是“完整监控 AI 调用流程”的可执行实现方案。

