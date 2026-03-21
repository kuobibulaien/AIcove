# Provider与适配器统一方案

## 为什么这一卷必须单独存在

当前最大的问题之一，不是“没有 adapter”，而是：

- 聊天有一套 adapter
- 生图有半套 adapter
- TTS 只有半套 provider

三套抽象粒度完全不一致，所以新增供应商时根本没有统一套路。

本卷的任务，就是把这三域统一成一套稳定的供应商接入模型。

---

## 现状问题

### 聊天域

聊天 adapter 已经具备一些基础能力：

- endpoint / headers / body
- 响应解析
- provider factory

但仍然存在问题：

- fallback 过宽
- runtime 里仍有厂商特判
- capabilities 没真正参与路由

### 生图域

生图 adapter 目前只对 OpenAI-compatible 方向较完整，NovelAI 仍走旁路。

结果就是：

- adapter 有，但不是真正唯一入口
- 遇到特殊厂商时还是回到 support 大分支

### TTS 域

TTS 当前统一的是“音色管理 provider”，不是“完整供应商适配”。

具体表现：

- 音色 CRUD 走 provider
- 语音合成仍在 `TtsService`
- 厂商识别又分散在 config/context/plugin/service

这意味着 TTS 根本还没有真正的供应商适配器。

---

## 目标统一模型

建议统一为下面五件套：

1. `ProviderMetadata`
2. `ProviderCapabilities`
3. `RequestBuilder`
4. `ResponseParser`
5. `TransportPolicy`

### 1. `ProviderMetadata`

描述静态信息：

- providerId
- displayName
- authScheme
- baseUrl
- requestFormat
- aliases
- 默认模型
- 适用业务域

### 2. `ProviderCapabilities`

必须进入运行时决策，而不是只做静态说明。

例如：

- supportsStreaming
- supportsVision
- supportsImageGeneration
- supportsVoiceCatalog
- supportsVoiceSynthesis
- supportsFunctionCalling

### 3. `RequestBuilder`

负责把统一领域请求转换成供应商请求。

不同业务域分别实现：

- ChatRequestBuilder
- ImageRequestBuilder
- TtsSynthesisRequestBuilder
- TtsVoiceCatalogRequestBuilder

### 4. `ResponseParser`

负责把供应商响应解析成标准结果。

### 5. `TransportPolicy`

负责声明：

- HTTP 还是 WebSocket
- 是否 multipart
- 流式协议格式
- 特殊超时或重试规则

---

## TTS 的特殊设计

TTS 建议拆成两类 adapter，而不是强行塞成一个：

### 1. `TtsSynthesisAdapter`

负责：

- 文字转音频
- 请求构建
- 响应解析
- transport policy

### 2. `TtsVoiceCatalogAdapter`

负责：

- 音色列表
- 创建音色
- 删除音色
- 音色状态查询

这样既统一了 TTS 的供应商接入模型，又不会把“合成”和“目录管理”继续混在一起。

---

## Registry 与 Factory 目标

建议建立统一 registry 口径，而不是每个域各写一套含糊 factory：

- ChatProviderRegistry
- ImageProviderRegistry
- TtsProviderRegistry

它们的接口风格应统一：

- `resolve(metadata)`
- `getAdapter(providerId)`
- `supports(capability)`
- `register(adapter)`

并明确：

- 不允许未知 provider 默认假装支持
- 别名解析必须可追踪
- fallback 必须显式记录

---

## 新增供应商的目标成本

### 重构前

- 新增聊天厂商：常要改 4 到 6 处
- 新增生图厂商：OpenAI-compatible 还好，特殊厂商通常要再改 support 逻辑
- 新增 TTS 厂商：现实里常常要改 5 到 8 处以上

### 重构后目标

- 新增聊天厂商
  - 新增 metadata
  - 新增 adapter
  - 注册 registry
  - 补测试
- 新增生图厂商
  - 同上
- 新增 TTS 厂商
  - 新增 synthesis adapter
  - 如支持音色管理，再新增 voice catalog adapter
  - 注册 registry
  - 补测试

目标不是“只改 1 个文件”，而是“改动点稳定且可预测”。

---

## 迁移策略

### 第一阶段

- 先引入统一 metadata / capability 口径
- 保留原 factory

### 第二阶段

- 聊天和生图先接入统一 registry 思路
- TTS 先抽 synthesis adapter 接口

### 第三阶段

- TTS voice catalog adapter 接入
- 清理旧路由判断

### 第四阶段

- 清理宽 fallback
- 清理过时 factory / helper

---

## 完成标准

1. 聊天、生图、TTS 都能被描述成统一供应商接入模型。
2. `ProviderCapabilities` 真正参与运行时路由。
3. TTS 不再只有音色 provider，没有合成 adapter。
4. 特殊厂商不再长期依赖 support 大分支旁路。
5. 新增供应商的步骤有固定模板可复用。

