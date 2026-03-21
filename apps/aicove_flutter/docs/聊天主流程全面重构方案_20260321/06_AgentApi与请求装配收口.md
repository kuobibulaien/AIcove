# AgentApi 与请求装配收口

## 本文目标

把 `AgentApi` 及其相关支持文件重新收回到“传输层/协议层”职责，避免公共 API 类继续承载历史业务分叉和重复请求装配。

---

## 当前症状

重点文件：

- `lib/src/core/api/agent_api.dart`
- `lib/src/core/api/agent_api_stream_support.dart`
- `lib/src/core/api/agent_api_direct_chat_support.dart`

审计中的主要问题：

1. `AgentApi` 同时承载了图片生成、普通聊天、流式支持、遗留兼容方法等多类职责。
2. 流式支持与直发支持中存在 provider/baseUrl/endpoint 解析的重复实现。
3. 聊天消息归一化逻辑在 stream/direct 两边都重复出现。
4. 部分公共方法疑似已经不再被聊天主链使用，但仍挂在公共 API 类上。

---

## 目标口径

### `AgentApi` 只保留稳定公共入口

它应该是“能力门面”，而不是“历史方法收容站”。

### stream/direct 共享同一套前置装配

像以下逻辑不应再写两份：

- provider/endpoint 解析
- base URL 选择
- 消息归一化
- 公共 headers / request body 公共字段装配

### 已无调用的方法进入清退流程

如果确认某些方法已经不被主流程使用，就不应长期挂在公共 API 类里增加理解成本。

---

## 建议重构方向

### 1. 把公共请求装配提成共享能力

重点收口这些重复点：

- provider 解析
- endpoint 决策
- 消息格式标准化
- 通用请求参数

无论最终放在 shared helper、support base 还是单独文件，都必须做到 stream/direct 共用。

### 2. `AgentApi` 门面化

`AgentApi` 应尽量只暴露稳定且仍在线的公共入口，例如：

- 直发聊天
- 流式聊天
- 图片生成

每个入口背后可以走共享装配能力，但门面本身不继续堆业务判断。

### 3. 老方法分三类处理

- 仍在主链使用：保留并收边界
- 仅被少量兼容路径使用：标记迁移计划
- 已确认无调用：进入清理清单

不要一边猜测、一边直接删。

---

## 推荐施工步骤

### Step 1：先提取 stream/direct 的公共前置逻辑

优先统一：

- provider/baseUrl/endpoint 解析
- 消息数组标准化
- 通用 body 字段

这样后续无论保留多少 support 文件，重复都会先降下来。

### Step 2：瘦身 `AgentApi`

确认哪些入口是真正对外公共入口，哪些只是历史遗留包装。对外 API 面尽量缩小，但第一阶段可保留兼容方法转发，避免直接炸全仓。

### Step 3：建立待删除清单

把疑似 dead code 的 API 方法单独列出来，交给清理窗口在全链路验证后删除。

---

## 建议写文件范围

推荐由“API 窗口”负责：

- `apps/aicove_flutter/lib/src/core/api/agent_api.dart`
- `apps/aicove_flutter/lib/src/core/api/agent_api_stream_support.dart`
- `apps/aicove_flutter/lib/src/core/api/agent_api_direct_chat_support.dart`

如果需要抽公共 helper，也由这个窗口主导。

---

## 不建议这个窗口直接改的地方

1. 不主动改 `chat_page.dart`
2. 不主动改 Provider 文件
3. 不主导 `ChatActions` 拆责
4. 不直接删除全量疑似 dead code

API 窗口的任务是先把边界收清，再把删除建议交给清理窗口执行。

---

## 与发送窗口的接口约定

发送窗口最终希望拿到的是稳定 API 能力：

- 一致的请求装配入口
- 一致的流式事件输出
- 一致的错误模型

发送窗口不应该继续知道 stream/direct support 的内部差异。

---

## 验收标准

1. stream/direct 的公共装配逻辑不再重复两份。
2. `AgentApi` 的公开入口比现在更清晰、更少历史包袱。
3. 已无调用的 API 方法进入明确清理清单。
4. 聊天主流程不再依赖 API 层的历史兼容分叉才能跑通。

---

## 高风险点

1. API 层一旦动错，很容易出现所有聊天入口都挂掉的全局性问题。
2. 流式和直发虽然看上去相似，但细节字段和回调节奏不一定完全一致。
3. 公共装配提取过度也可能引入新的抽象壳。

建议：

- 先统一真正重复的前置逻辑
- 不为“理论优雅”过度抽象
