# 节点库内容审查

## 核心结论

节点库当前不能作为真实运行态编辑台使用。它把变量节点显示成 `sampleValue`，而实际 Agent 预览仍展示未替换模板；同时变量库、模板正文、Agent Build 图、Flutter 同步物存在多处漂移。

## 发现

### 1. 变量节点只展示 sampleValue，不展示运行时真实值

- 变量详情页字段标签是“示例值 / 预览/调试时替换 {name}”。
- `state_json` 的 sampleValue 只有 `mode` 和 `device_local_time`。
- 实际运行时 `ContextAnalyzer._buildRuntimeStateJson` 会生成更多字段，包括 `conversation_id`、`current_role_persona`、时区、主动回复状态、未回复计数、待触发器 ID 等。

影响：用户在节点库里改变量时，看不到真实注入结构，只能看一个人工示例。

### 2. Agent Build 的实际提示词预览没有做变量替换

- 后端 `_agent_prompt_preview` 中 `content` 和 `preview` 都直接取 `detail['template']`。
- `combinedText` 也是原模板拼接，没有使用变量 `sampleValue`，更没有使用运行时真实值。

影响：面板写着“预览/调试时替换”，但实际预览不会替换，提示词作者无法验证最终输入。

### 3. 变量库与模板正文存在漂移

自动比对 `prompt_defaults.json` 的 `variables` 与模板占位符后发现：

- 模板使用但变量库没有定义：`current_time_explanation`、`message_timestamp_explanation`、`previous_user_message_explanation`、`current_time_line`、`previous_user_message_line`、`profile_block`、`l2_skill_index_block`、`l2_skill_detail_block`、`recall_block`、`lines`、`pov`、`pov_hands`、`tag`。
- 变量库定义但当前 prompt 默认模板不使用：`user_name`、`datetime`、`previous_user_message_datetime`、`profile_lines`、`l2_skill_index_lines`、`l2_skill_detail_lines`、`recall_lines`、`time_prefix`、`content`、`title`、`trigger_hints`、`indented_details`、`template_text`、`old_line`、`voice_frequency` 等。

影响：节点库的变量列表并不能可靠代表“这个模板真实可用的变量”。

### 4. `current_role_persona` 的元数据表达容易误导

- `auto_reply.analyzer.default` 声明了 `state_json` 和 `current_role_persona`。
- 模板正文只直接使用 `{state_json}`。
- 运行时代码把 `current_role_persona` 放进 `state_json`，同时也把它作为模板变量传入。

影响：节点库看起来像有两个并列变量，但实际 `current_role_persona` 是嵌入在 `state_json` 内的运行态字段。

### 5. Flutter 同步物的 `nodeLibrary` 只包含内置 Agent 引用的 10 个 prompt

- `prompt_defaults.json` 有 34 个 prompt。
- `agent_context_defaults.json` 的 `nodeLibrary` 只有 10 个 prompt。
- 后端生成 Flutter artifact 时只把 `bindings` 引用到的节点写入 `nodeLibrary`。

影响：同一个“节点库”概念在 Web 面板和 Flutter 同步物里含义不一致，容易误判为节点缺失。

### 6. 默认 Memory Agent 图把多个独立记忆流程串成了一条链

- `memory_agent:default` 有 8 个 prompt 节点和 7 条顺序边。
- 这些节点实际覆盖记忆总结、角色人设说明、聊天注入、画像格式化、合并、重新丰富等不同运行场景。

影响：图上像是一个连续流水线，但运行时并不是这样调用，容易误导 Agent Build 编辑。

### 7. 默认 Proactive Agent 图有两个阶段节点但没有连线

- `proactive_agent:default` 有 analyzer 与 reply_generation 两个节点。
- `entryNodeIds` 和 `outputNodeIds` 都同时包含两个节点。

影响：这可能是为了表达两个独立阶段，但图语义没有显式说明“分阶段独立请求”，普通编辑者会以为图缺边。

## 建议修复方向

最佳方案：把节点库变量从“示例值字典”升级为“运行态变量契约”。

最小修复内容：

1. 变量节点增加 `valueSource` / `runtimeShape` / `sampleValue` 三层语义。
2. Agent Build 预览区明确区分“模板原文”“示例渲染”“真实运行态预览”。
3. 为可本地计算的变量接入真实 resolver，例如 `state_json`、时间变量、TTS 配置变量、记忆块变量。
4. 为无法离线拿到真实上下文的变量提供结构化 mock，不再放一句短字符串。
5. 增加校验：模板占位符必须在变量库登记；变量库里未被任何模板使用的项标记为“孤立变量”。
6. 调整 Agent Build 默认图：Memory 按运行场景拆阶段，不把独立流程串成一条链；Proactive 标明 analyzer/reply_generation 是两个阶段请求。

## 本轮状态

已完成审查，未修改业务代码或节点库内容。
