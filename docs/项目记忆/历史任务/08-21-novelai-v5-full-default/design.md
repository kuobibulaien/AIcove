# NovelAI V5 Full 默认生图模型：技术设计

## 边界

改动只落在 Flutter 本地客户端：设置数据层维护 NovelAI 模型目录和一次性迁移，
图片 API support 维护供应商请求体。UI 继续消费既有 `ProviderAuth`、可见模型和
`defaultImageModel`，不新增跨层接口。

## 模型目录

`kNovelAiDefaultModels` 作为 NovelAI 文生图生产目录的单一真相源，顺序同时表达
默认优先级：V5 Full、V5 Curated，随后是 Legacy 模型。默认 provider、模型预览、
导入 fallback 和迁移均复用该常量。NovelAI 的 normalize 路径不得再按字母排序；
它按“受控目录顺序 + 原有未知模型顺序”去重合并。

inpainting ID 不进入该目录，因为当前 `ImageProviderAdapter` 请求契约只覆盖文生图。

## 设置迁移

增加一次性 migration id。加载旧设置时：

1. 识别所有 NovelAI provider（ID、base URL 或 `requestFormat`）。
2. 将受控目录与原有模型去重合并，受控目录在前。
3. 将 V5 Full 放到可见模型首位，保留其余原有可见模型。
4. 默认值缺失，或属于 V4.5 Curated / Full / 旧 Curated Preview 别名时，升级
   `custom_config.defaultImageModel` 为 V5 Full；V3、Furry V3、V4 和未知自定义
   默认值保持不变。
5. 保持 API keys、base URL、enabled、capabilities 及未知 custom config 字段不变。
6. 写入 migration id，之后不再自动覆盖用户的新选择。

全新默认数据预先包含 migration id，避免首次加载重复迁移。内置 provider 的配置键
统一修正为持久层实际读取的 `custom_config`，并通过写入 SharedPreferences 后重载测试。

## V5 请求

仍调用 `POST https://image.novelai.net/ai/generate-image`。V5 与 V4 都使用
`v4_prompt` / `v4_negative_prompt` 的结构化 caption，但按模型族设置参数：

| 模型族 | params_version | 默认 scale | 结构化 prompt | V3 legacy 字段 |
|---|---:|---:|---|---|
| V5 | 4 | 7.0 | 是 | 否 |
| V4 / V4.5 | 保持本项目已验证行为 3 | 5.0 | 是 | 否 |
| V3 / Furry V3 | 保持本项目已验证行为 3 | 5.0 | 否 | 是 |

`steps`、`guidanceScale`、`sampler` 等显式调用参数继续优先于默认值。
API support 自身的空模型默认值也改为 V5 Full，避免绕过设置层的调用继续选中 V4.5。

V5 与 V4 统一走“结构化提示词模型”判定，并选择禁止覆盖结构化核心字段的 reserved
key 集合。`image_parameters` 不得覆盖 `params_version`、尺寸、scale、sampler、
`v4_prompt`、`v4_negative_prompt`，也不得重新注入 V3 的 legacy / qualityToggle /
SMEA 字段。

## 错误与兼容

- 保留旧 ID `nai-diffusion-4-5-curated-preview` 到正式 ID 的规范化。
- 删除所有 NovelAI 模型枚举错误后的跨模型自动重试；所选模型失败即返回错误。
- 网络超时、401、403、ZIP/JSON 解包和日志行为保持不变。
- 旧 V4.5/V3 请求体由现有回归测试保护。

## 回滚

代码回滚后，已迁移设置里的 V5 ID 仍会保留；旧代码无法正确生成 V5，因此不能直接
回退到不识别 V5 的旧提交。可执行回滚采用前向修复版本：保留 V5 模型识别与安全请求
分支，同时增加新的补偿 migration id，仅把由本次历史默认迁移到 V5 Full 的渠道切回
V4.5 Full，并恢复可见首项；明确的用户模型选择仍保留。回滚验收必须覆盖已迁移设置，
不能只测全新安装。

## 长期知识判断

“NovelAI 图片模型没有可靠 `/models` 端点、目录需受控维护”属于可复用供应商约定。
实现和验证完成后更新绘图功能文档；它不改变项目领域词汇，也未达到全局 ADR 门槛。
