# 0129 日志中心重做与跨端 Token 用量计费账本

- 状态：accepted（2026-11-17 用户确认）
- 日期：2026-11-17
- 关联：ADR0019（全端共用界面）、ADR0065（诊断导出白名单分级）、ADR0067（请求用量与缓存观测）、ADR0123（跨端模型请求账本与上下文同步）

## 背景

1. **供应商返回的 Token 用量全量丢弃**：`OpenAIAdapter`、`ClaudeAdapter`、`GeminiAdapter` 及流式通道 `_AgentApiStreamSupport` 均未解析回包中的 `usage`／`usageMetadata`，OpenAI 兼容流式请求也未携带 `stream_options.include_usage`；用户无法看到日常聊天、后台上下文压缩、长期记忆整理、主动回复、杂活助手等环节各自的 Token 消耗、缓存命中省流比例与预估开销（ADR0067 第 1 步尚未落地）。
2. **模型无单价与倍率配置**：`ModelConfig` 与 `ProviderAuth` 尚无单价及中转倍率字段，缺少常见官方模型的内置参考单价，无法将 Token 用量换算为直观花费。
3. **跨端总账缺失**：`ModelRequestLedger`（ADR0123）仅保留每设备最近 80 条、7 天内的请求状态用于防多端并发撞车，无法承接长期计费统计；手机后台自动运行的压缩、记忆整理与主动消息开销在桌面端看不到长期累计。
4. **日志中心筛选繁杂、日常可读性差**：原 `LogViewerPage` 混排两行共 9 个筛选项（5 类来源 × 4 档级别）及工程调试说明，且仅深藏于「设置 → 调试中心」，缺少面向日常查账的清晰视图。

## 决定

### 一、统一 Token 用量契约与多供应商流式／非流式采集

1. **统一 `TokenUsage` 不变量**：
   - 定义 `TokenUsage({inputTokens, outputTokens, cachedInputTokens, cacheWriteTokens, reasoningTokens, isEstimated})`。
   - 跨供应商统一口径：`inputTokens` 为本轮总输入量（含缓存读取 `cachedInputTokens` 与缓存写入 `cacheWriteTokens`，故普通未缓存输入恒为 `uncachedInputTokens = max(0, inputTokens - cachedInputTokens - cacheWriteTokens)`），`outputTokens` 含思考量 `reasoningTokens`，总用量恒为 `totalTokens = inputTokens + outputTokens`。
2. **分供应商精确归一化**：
   - **OpenAI 兼容（含 DeepSeek／Moonshot／Qwen／OpenRouter／MiniMax 及 Responses API）**：Chat Completions 读取 `usage.prompt_tokens`、`completion_tokens`、`prompt_tokens_details.cached_tokens ?? prompt_cache_hit_tokens`、`completion_tokens_details.reasoning_tokens`；Responses 流／非流另兼容 `response.usage` 下的 `input_tokens`、`output_tokens`、`input_tokens_details.cached_tokens`、`output_tokens_details.reasoning_tokens`。
   - **OpenAI 兼容流式 `include_usage` 与不兼容中转自动回退**：仅当 `streaming == true`、请求目标路径为 `/chat/completions`、`adapter.name == 'openai'`、调用方／`customConfig` 未显式设置 `stream_options` 且该 `(endpoint, model)` 未在不支持列表中时，自动注入 `stream_options: {'include_usage': true}`。若上游在吐出任何流事件前返回 HTTP 400／422 且响应明确提及 `stream_options` 或 `include_usage`，立即将该 `(endpoint, model)` 记入内存不支持集合并剥离 `stream_options` 无感重发一次。
   - **Claude（Anthropic）**：Anthropic 官方 `usage.input_tokens` 仅代表未缓存输入，归一化时令 `inputTokens = input_tokens + cache_read_input_tokens + cache_creation_input_tokens`、`cachedInputTokens = cache_read_input_tokens`、`cacheWriteTokens = cache_creation_input_tokens`（默认按 1.25× 输入单价计费）、`outputTokens = output_tokens`。SSE 流式按字段非空合并 `message_start.message.usage` 与 `message_delta.usage`。
   - **Gemini**：读取 `usageMetadata.promptTokenCount`（已含 `cachedContentTokenCount`）；若 `thoughtsTokenCount > 0` 且结合 `totalTokenCount` 判定未包含在 `candidatesTokenCount` 内，令 `outputTokens = candidatesTokenCount + thoughtsTokenCount`、`reasoningTokens = thoughtsTokenCount`。
   - **本地估算与半途断流／取消记账**：当 HTTP 200 回包或已开始吐出流内容后发生取消／断流且缺少精确 `usage` 时，复用 `token_estimator.dart` 按已发送上下文与已接收输出估算并标 `isEstimated = true`；HTTP 非 2xx 或未收到任何有效响应前失败的请求不入账。
3. **诊断白名单对齐（ADR0065／ADR0067）**：`ApiLogEntry`、`TraceStore` 模型响应事件与 `sanitizeDiagnosticEntry` 同步纳入上述纯数值／布尔用量字段，严禁夹带对话正文。

### 二、四层定价优先级、公开价格库同步与渠道倍率

1. **四层定价解析闭环（由高到低）**：
   - **用户手填覆盖**：`ModelConfig` 新增可选字段 `inputPricePerMillion`、`outputPricePerMillion`、`cachedInputPricePerMillion`、`priceCurrency`（`'USD'`｜`'CNY'`）、`priceMultiplier`；`ProviderAuth.customConfig` 支持 `'priceMultiplier'`（默认 `1.0`，加入 `ProviderAdapterFactory._requestLocalOnlyKeys` 绝不透传上游），均随 `aicove.ui_models.v1` 跨端同步。
   - **上游真实账单与渠道列表单价**：OpenRouter 渠道回包携带合法 `usage.cost` 时（未手填单价前提下）直接采信真实美元花费；非 OpenRouter 渠道忽略裸 `cost` 防第三方积分污染。拉取渠道 `/models` 列表时，若返回标准单 Token `pricing`（如 OpenRouter），自动换算并缓存至本机渠道价格表。
   - **公开模型价格库按需同步（`models.dev`）**：不在后台静默联网；用户在「用量账单」主动点击「更新官方参考价」时拉取 `models.dev/api.json` 缓存至本机，按第一方原厂优先提取并过滤非原厂 0 元试用脏数据。
   - **智能模型名清洗与内置参考目录兜底**：剥离多级中转路径、中英文中转修饰前缀、思考／推理挡位与日期尾缀，归一 `5p1` 小数点与家族简写，识别 `:free` 零价，并在前缀匹配中禁止轻量档（`flash`／`lite`／`mini`／`nano`／`air`）回退命中主型号正代。
2. **未定价诚实展示与事后补算**：既未手填单价也未命中上述参考源的自定义代号记 `priced = false`，界面仅展示 Token 用量与「未设单价」提示，不伪造 `$0.00`；当用户事后补填单价或同步官方参考价后，历史 `priced = false` 记录在读取展示时动态补算金额，已按当时单价落账的历史记录保持原账面金额不变。

### 三、本机 SQLite 明细表 ＋ 单设备专属键跨端汇总账本

1. **本机明细表 `token_usage_entries`**：
   - 在 `AppDatabase.beforeOpen` 幂等建表与索引（不递增 Drift `schemaVersion`，前后台 isolate 共享同一 WAL 数据库连接与 `_runWithBusyRetry` 重试保护）。
   - 覆盖全部文字／多模态大模型真实 HTTP 回包入口（主对话、上下文压缩、长期记忆整理、主动回复规划与生成、杂活 Agent、语音通话简报与总结、空间网页 AI、模型连接测试），失败未产生计费响应的请求不入账。
   - 本机保留最近 **180 天**逐笔明细；超期明细在清理前自动折叠合入本机月度归档行（`purpose`／模型／角色维度保留），防止长期运行无限膨胀。
2. **跨端零冲突总账同步（`aicove.plugins.observability.usage_rollups.<deviceId>.v1`）**：
   - 沿用 ADR0123 单设备专属偏好键模式，顶层固定单一 `snapshot` 字段（清理合成 `value` 时钟，单键字段时钟恒为 1，直接兼容现有局域网同步与未重部署的 `sync_v3` 云端）。
   - **单写者防跨 isolate 竞态**：后台 WorkManager isolate 仅执行带 `await` 的 SQLite 事务写入（幂等请求主键去重，防进程退出丢账），不直接改写 `usage_rollups` 偏好键；仅前台主 isolate 在新账落库及启动／回前台时，从 SQLite 读取本机记录生成并发布 `usage_rollups.<localDeviceId>.v1`。
   - **重装恢复保护与体积有界**：发布本机快照前，若偏好中已有早于本机 SQLite 最早记录的历史汇总桶（例如重装后从云端恢复），先合并保留旧桶再写回，绝不用空库冲掉云端历史；近 30 天保留会话维度（最多 500 桶），31～90 天按日聚合模型与用途，90 天以前折叠为月度桶，总桶数硬上限 600（体积恒小于 120 KB）。
   - `ModelRequestLedger` 的 `ModelRunRecord` 同步附带可选单轮汇总用量字段，供近期跨端逐笔记录直接显示用量。
   - 账单统计查询严格按 `deviceId` 分治：**本机部分查本地 SQLite（合并重装恢复的本机旧归档桶），对端部分读取 `deviceId != localDeviceId` 的远端 `usage_rollups`**，天然杜绝重复计费，USD 与 CNY 分币种独立累计展示。

### 四、「用量与日志」界面重做与入口打通

1. **双入口共用同一页面**：
   - `设置 → 模型管理` 顶部新增「用量与计费」入口，打开直达「用量账单」分栏；
   - `设置 → 调试中心` 原入口更新为「用量与日志」。
2. **两栏结构**：
   - **「用量账单」栏**：支持 `今天／近 7 天／近 30 天／全部` 与设备筛选；顶部总览卡展示预估花费、总用量、输入／输出／缓存省流／调用次数；中部排行卡支持按 `模型／角色／用途／设备` 切换（未设单价模型可一键调起单价设置）；底部展示逐笔账单明细，右上角支持导出 CSV 与清空本机记录。
   - **「运行日志」栏**：砍掉原双排 9 个筛选项与晦涩工程提示，收敛为单排 4 个直观视图（`全部记录`、`对话过程`、`网络请求`、`只看异常`），保留单轮 Trace 导出、多选复制、历史日志及前端响应采集开关，并在对话轮次与网络日志中同步展示本轮 Token 用量。
3. **单价与倍率编辑**：`ModelRowTile` 编辑弹窗（对话与嵌入模型）支持自动保存单价与币种并展示内置参考价提示；`ProviderDetailPage` 配置页支持自动保存渠道计费倍率。

## 代价

- 内置参考单价随官方调价可能滞后，界面须标明「参考价」并支持随时手改覆盖。
- 极端不返回 `usage` 的第三方中转只能依赖本地字符级估算，存在约 10%～25% 偏差，须在界面明确标出「估算」。
