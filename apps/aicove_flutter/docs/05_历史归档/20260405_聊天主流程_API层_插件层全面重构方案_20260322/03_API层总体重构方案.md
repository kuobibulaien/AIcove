# API层总体重构方案

## 目标

把 `core/api/` 从“一个大门面 + 多个 support 旁路”改成：

- 稳定 facade
- 清晰编排层
- 统一 transport
- 分域 runtime
- 可插拔 adapter

重构范围包括：

- 聊天直连
- 聊天流式
- 生图执行
- provider 解析
- 能力声明
- 日志与诊断收口

---

## 当前问题

### 1. `agent_api.dart` 仍是上帝类

它当前仍同时承担：

- 请求上下文解析
- provider/model 决策
- 诊断与日志
- payload/ref 落盘
- 旧 `sendMessage` / `sendMessageStream`
- direct / stream / image 入口

这意味着只要继续往里加功能，它就一定继续膨胀。

### 2. support 拆分没有变成运行时边界

`agent_api_*_support.dart` 现在更多是“把代码挪到另一个文件”，而不是“形成独立模块”。它们仍需要大量回调 `_owner` 私有逻辑。

### 3. HTTP 生命周期重复

当前 direct、stream、image 至少重复了这些东西：

- 请求头
- 请求体
- 超时
- POST 执行
- trace/logger
- 异常转换

这种重复一旦继续增长，认证、超时、诊断字段都会双份漂移。

---

## 目标分层

建议按下面的结构重组：

### 1. `AgentApiFacade`

职责：

- 对外保留稳定调用入口
- 做统一参数校验
- 选择执行器
- 聚合结果

不负责：

- 大段 transport 细节
- 大段请求装配细节
- provider 特判分支

### 2. `AgentRequestOrchestrator`

职责：

- 把“会话消息 + provider 配置 + 模式选择”归一化成标准请求对象
- 统一 direct / stream / image 的请求准备阶段

### 3. `AgentTransport`

职责：

- HTTP / WS 客户端生命周期
- headers、timeout、重试、stream 读取
- 原始异常转标准异常

### 4. Runtime 层

建议至少拆成：

- `ChatDirectRuntime`
- `ChatStreamRuntime`
- `ImageGenerateRuntime`

职责：

- 驱动具体模式的执行
- 调用 adapter 和 transport
- 产出标准执行结果

### 5. Diagnostics 层

职责：

- TraceStore
- ApiLogger
- payload/ref 记录
- 统一诊断字段

要求：

- 诊断逻辑不再散在 direct / stream / image 三处

---

## 统一请求模型

建议把 API 层统一为三类标准请求对象：

1. `ChatDirectRequest`
2. `ChatStreamRequest`
3. `ImageGenerationRequest`

它们共享公共字段：

- provider metadata
- model
- customConfig
- auth
- timeout
- diagnostics context

各自再补自己的域字段，而不是每条链路自己现场拼一份 `Map<String, dynamic>`。

---

## adapter 在 API 层中的位置

API 层应只向 adapter 问这几类问题：

1. 这个供应商支持什么能力
2. 这个请求应该如何构建
3. 这个响应应该如何解析
4. 这个供应商需要什么 transport policy

API 层不应再自己写太多：

- `if openai ...`
- `if gemini ...`
- `if novelai ...`
- `if requestFormat ...`

只要这些分支仍主要写在 facade 或 runtime 中，adapter 就还是半抽象。

---

## 旧接口兼容策略

旧接口如：

- `sendMessage`
- `sendMessageStream`

建议保留为 compatibility shell，一段时间内只做：

- 参数转换
- 调用新 facade
- 补兼容结果

明确禁止：

- 再继续往旧接口里加新功能
- 让旧接口拥有独立执行链

---

## 新增聊天/生图厂商的目标接入流程

### 新增聊天厂商

1. 补 provider metadata
2. 实现 chat adapter
3. 注册 adapter factory
4. 补 capabilities
5. 补 direct / stream 测试
6. 补诊断字段验证

### 新增生图厂商

1. 补 provider metadata
2. 实现 image adapter
3. 注册 image adapter factory
4. 补工具链与直连链测试
5. 补结果解析与落盘测试

目标是把新增厂商的动作稳定成这几步，而不是每次重新翻 `agent_api.dart` 和 support 文件找插入点。

---

## 分阶段迁移

### 阶段 A：抽公共传输能力

- 不改行为
- 只提取 headers、timeout、post、异常转换、stream 读取

### 阶段 B：建立 orchestrator 与 runtime

- facade 保持稳定
- 新逻辑开始从 facade 内部下沉

### 阶段 C：direct / stream / image 收口

- 三条链路全部改走 runtime + transport
- 诊断字段统一收口

### 阶段 D：adapter 统一与旧 support 清理

- 清理旁路
- 缩薄 `agent_api.dart`
- 删除失效 support 逻辑

---

## 风险点

1. 流式协议边界条件漂移
2. 图片生成返回格式解析漂移
3. fallback 过宽导致错误 provider 被静默命中
4. 诊断字段改动导致排障能力下降

因此迁移必须遵守：

- 先补契约测试
- 再搬逻辑
- 最后删旧代码

---

## 完成标准

1. `agent_api.dart` 只保留 facade 级职责。
2. direct / stream / image 的 HTTP 生命周期不再各写一份。
3. provider fallback 不再静默回退到 OpenAI 并伪装成功。
4. 新增聊天/生图厂商的接入步骤稳定可预测。
5. support 文件如果还存在，也只承担纯工具或兼容壳职责。

