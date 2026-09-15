# NovelAI V5 图片 API 调研（2026-08-21）

## 一手来源

- Swagger UI：<https://image.novelai.net/docs/index.html>
- Swagger JSON：<https://image.novelai.net/docs/doc.json>
- NovelAI 图片模型帮助页：<https://docs.novelai.net/en/image/models/>
- NovelAI 当前生产前端包：
  <https://novelai.net/_next/static/chunks/pages/_app-bb47952efe692447.js>

## 模型目录接口

- Swagger 暴露 `GET /oa/v1/models`，描述为 OpenAI-compatible API 的可用模型；该分组
  只有文本 completion/chat 端点，不是 Diffusion 图片目录。
- Swagger 没有 `GET /ai/models` 或 `GET /ai/generate-image/models`。
- 2026-08-21 无鉴权只读探测结果：
  - `/ai/models` -> 404
  - `/ai/generate-image/models` -> 404
  - `/oa/v1/models` -> 401，证明端点存在但需要鉴权；其 Swagger 契约仍是文本模型。
- 结论：客户端不应把 NovelAI 交给通用 `$base/models` 探测，也不应运行时抓官网 JS；
  图片模型目录应随客户端版本受控维护。

## 当前生产模型选择器

NovelAI 当前生产前端的模型选择器分组为：

### New

- `nai-diffusion-5-curated`
- `nai-diffusion-5-full`

### Legacy

- `nai-diffusion-4-5-curated`
- `nai-diffusion-4-5-full`
- `nai-diffusion-4-curated-preview`
- `nai-diffusion-4-full`
- `nai-diffusion-3`
- `nai-diffusion-furry-3`

同一生产包把默认模型常量设为 V5 Curated，但本项目用户明确要求默认使用 V5 Full。
生产包还包含各模型的 inpainting ID；本项目当前只做文生图，因此不加入选择目录。

## V5 请求证据

当前生产前端对 V5 Curated / Full 使用：

- `params_version: 4`
- 默认 `scale: 7`
- 默认 `sampler: k_euler_ancestral`
- 默认 `steps: 23`
- 结构化提示词字段仍位于 `v4_prompt` / `v4_negative_prompt`
- 模型能力分类为 V5，tokenizer 分类为 Qwen；这与 V4 的 T5 分类不同
- V5 Full prompt 上限在生产包中为 1471，V5 Curated 为 703；本任务继续使用保守英文
  prompt，不扩展提示词功能

本项目只复制协议所需的最小核心字段，不照搬官网 UI 的质量预设、透明背景、参考图、
Vibe Transfer 或订阅额度相关参数。

## 本地代码证据

- `features/settings/data/remote/provider_probe_remote_data_source.dart` 已对 NovelAI
  短路返回 `kNovelAiDefaultModels`。
- `features/settings/data/support/ui_models_store_support.dart` 当前目录只有 V4.5
  Curated / Full 与 V3。
- `core/api/agent_image_api_support.dart` 当前仅用 `nai-diffusion-4` 前缀识别结构化
  prompt；V5 会误走 V3 legacy 分支。
- 同文件会在模型 enum 错误时跨模型重试到 V4.5/V3，无法保证用户实际得到所选模型。

## 约束

- 未读取或输出任何 NovelAI Token。
- 未使用 Token 发起请求，未产生图片或 Anlas 消耗。
- 生产 JavaScript 没有公开 source map；结论来自当前压缩包中的明确枚举、选择器数组与
  默认参数分支，后续由本地请求体测试固化。
