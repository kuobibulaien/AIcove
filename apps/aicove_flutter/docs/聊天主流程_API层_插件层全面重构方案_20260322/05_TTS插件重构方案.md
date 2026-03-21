# TTS插件重构方案

## 为什么 TTS 是本轮最难的一卷

TTS 当前的问题不是单点“文件太大”，而是四层语义混在一起：

1. 运行时
2. 厂商路由
3. 音色目录
4. UI 配置

这四层现在分别散在：

- `tts_plugin.dart`
- `tts_service.dart`
- `tts_config.dart`
- `tts_provider_context.dart`
- `tts_provider_factory.dart`
- 各厂商 provider / service 实现

所以 TTS 的重构不能只拆文件，必须重建分层。

---

## 当前问题地图

### 1. 运行时和厂商适配混写

`TtsPlugin` 现在既像插件入口，又像厂商识别器，又像语音规则模板生成器。

`TtsService` 又既像请求执行器，又像 requestFormat 路由器，又像不同厂商 body builder。

### 2. 音色目录和语音合成没有拆开

当前 `TtsVoiceProvider` 只统一了音色 CRUD，但“真正合成一段语音”并不走它。

这会导致：

- 音色管理有抽象
- 合成运行时没抽象
- 新厂商接入仍要改 `tts_service.dart`

### 3. 配置层承载了太多厂商私有语义

`VoicePreset` 里已经塞入大量厂商字段：

- 阿里云字段
- SiliconFlow 字段
- 以及对 MiniMax 的特殊补丁式存储

这会让配置对象越长越像“万能音色结构”。

### 4. 厂商身份分散

当前至少同时存在：

- `providerType`
- `selectedProviderId`
- `requestFormat`
- provider id

如果不统一来源，新增厂商时就只能继续多处同步。

---

## 目标分层

建议把 TTS 拆成四层。

### 1. 插件编排层

建议由 `TtsPlugin` 保留，但只做：

- 插件元数据
- system prompt 生成
- `<tts>` 标签解析
- 把任务交给运行时

不再做：

- MiniMax / Aliyun / SiliconFlow 判断
- requestFormat 解析
- 音色目录路由

### 2. TTS 运行时层

建议新增 `TtsRuntime` 或等价模块，负责：

- 合成任务调度
- 播放队列衔接
- 批量转换
- 临时文件生命周期
- 错误回退

### 3. 供应商适配层

拆成两类：

- `TtsSynthesisAdapter`
- `TtsVoiceCatalogAdapter`

这样“合成”和“音色目录”从概念上彻底分开。

### 4. 配置与 UI 层

职责：

- 保存用户可编辑配置
- 渲染配置页
- 提供统一模型 / 音色 / 频率 / 模板编辑入口

禁止：

- 在配置对象里写复杂厂商分支
- 在 UI 层判断厂商协议格式

---

## 建议模块划分

### `TtsProviderResolver`

唯一厂商解析入口，统一返回：

- provider metadata
- synthesis adapter
- voice catalog adapter
- request format
- selected model

让这些判断不再散在：

- `tts_plugin.dart`
- `tts_service.dart`
- `tts_provider_context.dart`
- `tts_provider_factory.dart`

### `TtsConfigModel`

只保存通用配置：

- 是否启用
- 选中 provider
- 选中 model
- 选中 voice
- 频率
- 模板
- 播放相关设置

厂商私有配置建议收口到扩展字段或 provider 侧，而不是继续把 `VoicePreset` 膨胀。

### `VoiceDescriptor`

建议把现在的 `VoicePreset` 逐步拆为：

- 通用字段
- 厂商扩展字段

目标是减少“这个对象什么都懂”的情况。

---

## 厂商实现重构目标

### 阿里云

拆分重点：

- Qwen 与 CosyVoice 的差异明确落到 adapter 层
- WebSocket 合成和音色创建逻辑分开

### MiniMax

拆分重点：

- 不再靠 `requestFormat` / URL 双重猜测识别
- 不再继续通过 `VoicePreset` 扩展补丁保存关键标识

### SiliconFlow

拆分重点：

- 预置音色、上传音色、动态音色三种路径统一进入 adapter
- model 与 voice 组合规则从配置对象里抽离

---

## 迁移顺序

### 第一阶段：统一厂商解析口径

- 建立 `TtsProviderResolver`
- 让 plugin / service / context 统一用它

### 第二阶段：引入 synthesis adapter

- `TtsService` 先改成 runtime + adapter 协作
- 保留旧入口作为兼容壳

### 第三阶段：拆 voice catalog

- 音色列表、创建、删除、状态查询全部改走 `TtsVoiceCatalogAdapter`

### 第四阶段：收配置与 UI

- 精简 `VoicePreset`
- 收掉多处厂商判断

### 第五阶段：清死代码

- 删除旧 `voice_manager_service.dart`
- 删除注释掉的大块旧实现
- 删除只剩历史兼容意义的分支

---

## 验收标准

1. `TtsPlugin` 不再直接判断具体厂商协议。
2. `TtsService` 不再是 requestFormat 大 switch 的唯一承载者。
3. 新增 TTS 厂商时，主要通过 resolver + adapter 注册完成，而不是同时改配置、UI、运行时多个分支。
4. 音色目录和语音合成是两个稳定抽象。
5. `VoicePreset` 不再继续膨胀成“万能音色对象”。

