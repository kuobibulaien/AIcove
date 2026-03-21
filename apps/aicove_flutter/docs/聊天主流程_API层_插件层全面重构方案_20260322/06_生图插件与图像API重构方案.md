# 生图插件与图像API重构方案

## 目标

让生图域从“插件里兼任半个 API 层”变成：

- 插件层只做编排
- API 层负责执行
- adapter 负责供应商差异

并统一两条现有生图路径：

1. 稳定工具链 `draw_image`
2. 快速直连链 `<image>...</image>`

---

## 当前问题

### 1. `ImagePlugin` 职责过多

当前它同时承担：

- system prompt
- tool schema
- `<image>` 标签解析
- provider/model 解析
- prompt bundle 构建
- 请求执行
- 结果落盘

这意味着只要生图规则继续增加，插件本体就必然继续膨胀。

### 2. image adapter 不是真正唯一入口

目前 `image_provider_adapter_factory.dart` 只对 OpenAI-compatible 路径较完整，而 NovelAI 仍通过 `agent_image_api_support.dart` 走专属分支。

这会造成：

- adapter 看起来存在
- 但真正复杂厂商并没有被接住

### 3. 参数归属不清

当前经常混在一起的内容包括：

- 插件配置默认值
- runtime 输入参数
- provider 请求参数
- prompt bundle 合并规则

如果这些归属不清，后续新增厂商时就只能继续复制逻辑。

---

## 目标分层

### 1. `ImagePlugin`

仅负责：

- 暴露工具
- 解析 `<image>` 直连标签
- 把用户场景转换成图像生成命令
- 接收结果回灌消息流

### 2. `ImageGenerationUseCase`

建议新增统一应用层入口，负责：

- 接收图像生成命令
- 调用 target resolver
- 调用 API runtime
- 统一结果格式

### 3. `ImageTargetResolver`

负责：

- 选 provider
- 选 model
- 读取配置
- 产出标准目标

禁止在插件本体里重复写同样的解析逻辑。

### 4. `ImagePromptComposer`

负责：

- 画师串
- 负面词合并
- 默认尺寸
- 默认质量参数

它属于图像领域规则，不属于插件编排本体。

### 5. `ImageGenerationRuntime`

位于 API 层，负责：

- 调 adapter
- 调 transport
- 解析结果
- 统一异常

---

## NovelAI 与 OpenAI-compatible 的统一策略

### 当前问题

- OpenAI-compatible 走 adapter
- NovelAI 走旁路 support 分支

### 重构目标

二者都走统一 runtime，只在 adapter 内表达差异：

- 请求体差异
- prompt 规则差异
- 结果解析差异
- 特殊 transport policy

结论是：

NovelAI 不应该继续长期作为 support 特判存在。

---

## 两条生图路径如何统一

### 稳定工具链

`draw_image` 工具负责：

- 工具调用参数验证
- 调用 `ImageGenerationUseCase`
- 把结果作为工具结果回灌

### 快速直连链

`<image>...</image>` 负责：

- 标签解析
- 调用同一个 `ImageGenerationUseCase`
- 把结果当作快速生成消息回灌

两条链路的差异只在“入口形式”，不应再是“完全不同的执行实现”。

---

## 参数归属规则

### 插件配置负责

- 默认 provider / model
- 默认宽高
- 默认负面词
- 默认步数和 guidance
- 提示词模板

### 图像命令负责

- 当前 prompt
- 当前运行时覆盖参数
- 当前入口来源

### adapter 负责

- 把统一参数翻译成供应商参数
- 解析供应商结果

---

## 迁移步骤

### 第一步：冻结图像生成命令

- 定义统一 `ImageGenerationCommand`
- 让工具链与快速链都先产出这一命令

### 第二步：抽 target resolver 与 prompt composer

- 把 provider/model 选择和提示词合成从 `ImagePlugin` 内拆走

### 第三步：引入统一 runtime

- 插件统一改调用 API 层 runtime
- 原有执行逻辑保留兼容壳

### 第四步：NovelAI 适配收口

- 让 NovelAI 正式进入 image adapter 体系
- 清理 support 特判

---

## 验收标准

1. `ImagePlugin` 不再承担 provider/model 解析与执行细节。
2. 工具链和快速链都走同一个图像生成 use case。
3. NovelAI 不再长期走 support 旁路。
4. 生图域新增供应商时，不再需要同时改插件层和 support 大分支。

