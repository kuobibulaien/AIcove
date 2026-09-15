# Aicove 现有架构与 DSH 接入面

## 当前事实

- Flutter 已有 `AgentDefinition`、`AgentRunRequest`、`AgentRuntime`、`AgentScheduler`、`AgentDeliveryChannel` 等稳定契约。
- 当前 `StandardChatAgentRuntime` 仍只是把请求委托给旧 `ChatSendUseCase`；真正模型调用、工具循环和多模态投递还在旧聊天链路。
- 现有 Dart 插件协议提供 prompt、响应后处理、AI tool、LLM hook、生命周期和配置，但不是 DSH/Cordis 插件协议。
- 项目规定 DB raw message 是聊天上下文唯一真相源；官方 DSH 则把 append-only SessionEvent log 作为模型上下文、恢复和 UI replay 的真相源。两者的所有权必须在设计中显式分开。
- Android 已有 Flutter MethodChannel、前台保活 Service、电池优化和自启动设置入口，可以复用生命周期基础，但还没有 Node/DSH 运行时管理器。

## 不应采用的接法

1. 仅把 DSH WebUI 放进 WebView：可以演示 Harness，但 Aicove 的联系人、DB、主动消息和插件全部留在外面。
2. Flutter 继续完成 Agent loop，再调用 DSH 作为一个普通模型接口：这不是真正以 Harness 为底层。
3. 一次性删除旧聊天链路：无法保留回滚路径，也无法验证 DB、流式 UI 和多模态投递的兼容。
4. 永久维护 Dart Plugin 与 Cordis Plugin 两套同级公共插件平台：新能力会重复实现和配置。

## 推荐边界

```text
Flutter 产品层
  - 联系人 / 对话 UI / Drift DB / 通知 / 多媒体展示
  - AgentRuntime 合同与 DeliveryChannel
            |
            | authenticated local JSON-RPC / WebSocket
            v
Aicove DSH Bridge Plugin
  - Agent/session 创建与恢复
  - 流式 SessionEvent -> Flutter AgentOutputEvent
  - Aicove capability tool -> Flutter/native call
  - AgentDefinition -> DSH preset/profile/session config
            |
            v
Official DSH / Cordis
  - agent loop / tools / session log / compaction / subagent / skills
            |
            v
Android Runtime Host
  - Node process / runtime update / foreground service
  - App / Shizuku / Root execution backends
```

## 插件迁移方向

- DSH/Cordis 成为 Agent 侧插件标准：上下文注入、模型工具、Agent 事件、session durable event 都在此扩展。
- Dart 保留设备和展示能力实现：TTS 播放、图片保存、通知、Flutter UI、Drift 读写。
- `aicove-bridge` 插件把 Dart 能力注册成 DSH tool/capability seam；现有插件逐个迁移，不要求首版全部改写为 JavaScript。
- 迁移完成后，Dart `Plugin` 更名或收窄为 `DeviceCapability` / `OutputRenderer`，避免与 Cordis 插件概念冲突。

## 主要映射

| Aicove | DSH |
|---|---|
| `AgentDefinition` | Agent preset + Cordis config rows + session metadata |
| `AgentRunRequest` | 新建/恢复 agent session + inbox input |
| `ContextProfile` | preset composition、prompt sections、tool policy |
| `AgentOutputEvent` | `session/event` 和 `agent/*` live event 的稳定投影 |
| `AgentDeliveryChannel` | Flutter DB/通知/多模态执行 |
| `Plugin.getTools()` | `ctx.tools` 注册 |
| `Plugin.getSystemPrompt()` | DSH system-prompt section / agent injection |
| `Plugin.processResponse()` | session event consumer / output bridge |

## 最大架构冲突

DSH SessionEvent log 必须能完整重建模型看到的内容，而 Aicove Drift DB 必须继续支撑联系人 UI、同步、主动消息和多模态消息。推荐分工是：

- DSH log：Agent 执行真相源。
- Drift DB：产品消息与投递真相源。
- `DshSessionBinding(conversationId, agentId, dshSessionId, lastProjectedEvent)`：显式映射和幂等投影游标。

不能让两边互相自动全量覆盖。首次切换时从 DB raw messages 生成一个受控的 DSH seed；之后 DSH 事件投影到 Drift，用户编辑/重发通过明确命令产生新的 DSH 分支或 session event。

该分工是难回头的全局决定，需要在实现前由用户审核并记录 ADR。

## 预计受影响区域

- `apps/aicove_flutter/android/app/`：运行时、前台服务、权限后端、jniLibs、Manifest、Gradle。
- `apps/aicove_flutter/lib/src/features/agent_context/`：DSH runtime adapter、事件映射、session binding。
- `apps/aicove_flutter/lib/src/features/chat/`：按 feature flag 把 `StandardChatAgentRuntime` 切到 DSH adapter。
- `apps/aicove_flutter/lib/src/features/plugins/`：设备能力桥接与逐步迁移。
- 新的 runtime builder/CI 位置需遵守仓库允许目录规则，实施前要确定放入 `apps/aicove_flutter/android/` 还是调整项目宪法。

