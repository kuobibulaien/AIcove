# NovelAI V5 Full 默认生图模型

## Goal

把 NovelAI 生图目录升级到当前生产可用模型，并让 `nai-diffusion-5-full`
成为新安装与既有 NovelAI 渠道的默认生图模型，同时保证客户端使用与 V5
兼容的请求体。

## Background

- NovelAI 图片 API 没有稳定的图片模型列表端点；`GET /oa/v1/models` 仅服务于
  OpenAI 兼容文本 API，因此客户端仍需维护受控的图片模型目录。
- NovelAI 当前生产前端把 V5 Curated / Full 标为 New，把 V4.5、V4、Anime V3、
  Furry V3 标为 Legacy。
- 当前客户端仅内置 V4.5 Curated、V4.5 Full、Anime V3，且请求构造只把
  `nai-diffusion-4*` 识别为结构化提示词模型；直接加入 V5 会误走 V3 参数分支。
- 用户已明确要求默认模型为 V5 Full，并批准同步完成目录、协议适配和测试。

## Requirements

- NovelAI 文生图目录包含以下 8 个生产模型，New 在前、Legacy 在后：
  - `nai-diffusion-5-full`
  - `nai-diffusion-5-curated`
  - `nai-diffusion-4-5-full`
  - `nai-diffusion-4-5-curated`
  - `nai-diffusion-4-full`
  - `nai-diffusion-4-curated-preview`
  - `nai-diffusion-3`
  - `nai-diffusion-furry-3`
- 新安装的 NovelAI 渠道以 V5 Full 为 `defaultImageModel`，并把 V5 Full 放在
  可见模型首位。
- 既有 NovelAI 渠道通过一次性本地迁移补齐目录、把 V5 Full 放到可见模型首位；
  缺失默认值或使用历史内置默认值的渠道升级为 V5 Full，明确选择 V3、Furry V3、
  V4 或未知自定义模型的渠道保留原默认值。迁移不得覆盖 API Token、地址、启用状态
  或其他用户配置。
- V5 使用 NovelAI 当前结构化提示词请求格式，核心参数与 V4/V3 分支明确隔离。
- 所有显式选择的 NovelAI 模型均不得在枚举错误后静默切换为另一个模型；失败必须
  保留原模型上下文并直接返回。旧模型 ID 的确定性别名规范化不属于降级，继续保留。
- V4.5、V4、V3 与 Furry V3 继续作为可选回退模型保留，不删除旧模型别名兼容。
- 不把 inpainting 模型混入当前仅支持文生图的模型选择列表。

## Acceptance Criteria

- [x] NovelAI 模型预览返回上述 8 个受控模型，且不请求不存在的 `/models` 端点。
- [x] 全新设置中的 NovelAI `defaultImageModel` 为 `nai-diffusion-5-full`，可见模型
      首项也是 V5 Full。
- [x] 既有 NovelAI 设置只迁移一次；历史内置默认值升级为 V5 Full，明确的 V3、
      Furry V3、V4 或自定义默认值保持不变，密钥、地址和其他渠道字段保持不变。
- [x] V5 Full 请求使用 `POST /ai/generate-image`、模型 ID `nai-diffusion-5-full`、
      `params_version = 4`、V5 默认 guidance scale，并包含结构化正负提示词。
- [x] V5 请求不携带仅供 V3 使用的 legacy / qualityToggle / SMEA 参数。
- [x] V5、V4.5、V3 返回模型枚举错误时均只产生一次请求，不尝试其他模型。
- [x] 现有 V4.5 与 V3 协议兼容测试继续通过。
- [x] `flutter pub get`、相关窄测试、`flutter analyze` 和
      `flutter run --no-resident` 完成；若设备/环境阻塞，记录完整证据。

## 自主决策

- 图片模型目录采用版本内受控常量，不运行时抓取 NovelAI 官网前端包，避免上游构建
  结构变化导致核心生图功能失效。
- 迁移使用一次性 migration id，既让现有安装升级到 V5 Full，也避免每次启动重复
  覆盖用户后续选择。
- 历史 V4.5 Curated / Full 及旧 Curated Preview 别名视为旧内置默认并迁移；无法
  区分用户主动选择的 V4.5 与旧版本默认值，这是默认升级目标的已知代价。
- V5 先沿用 NovelAI 的 `v4_prompt` / `v4_negative_prompt` 结构，但单独设置
  `params_version = 4` 与 V5 默认 scale；这是当前官方生产前端所使用的兼容边界。
- 本次不新增模型目录实体或远端配置系统；当前只有一个特殊供应商，使用集中常量与
  小型判定函数更符合 KISS。

## Out of Scope

- NovelAI inpainting、Vibe Transfer、Precise Reference、透明背景等新能力。
- 运行时抓取或解析 NovelAI 官网 JavaScript。
- 使用真实 Token 发起付费生图；若需要真实联网验收，另行获得敏感网络请求确认。
- 修改其他生图供应商、聊天模型或云端服务。
