# 绘图功能

> 更新：2026-11-01，按当前工作树源码重写。决策：[ADR0008](../../../../../docs/项目记忆/决策记录/0008-插件配置统一预设化与角色绑定.md)、[ADR0092](../../../../../docs/项目记忆/决策记录/0092-插件提示词按模型分包并由预设绑定.md)、[ADR0119](../../../../../docs/项目记忆/决策记录/0119-漫画分镜由主模型直出.md)。提示词包的结构见 [插件提示词包](../插件提示词包/README.md)，旧预设迁移见 [绘图预设实现与迁移](绘图预设实现与迁移.md)，渠道接口细节见 [图片渠道适配说明](图片渠道适配说明_20260306.md)。
> 2026-03 版旧说明（稳定／快速三套独立预设、单图上限）已归档到 [05_历史归档](../../05_历史归档/20261101_文档进度更新/04_功能模块规范/绘图功能/README_2026-03版.md)。

状态：离线测试通过；NovelAI 漫画已用手机真实请求排查修复；应用内多图、ComfyUI 与 OpenAI 兼容渠道的真实出图和性能未验。

## 三样配置，各管各的

| 对象 | 管什么 | 存在哪 |
|---|---|---|
| 绘图预设 `DrawingPreset` | 画风与渠道参数：渠道、模型、默认宽高／张数／步数／强度、反面词、画师串、ComfyUI 参数 | 插件预设，角色绑定一个 |
| 生图方案 `PromptPack`（`pluginId = image`） | 告诉模型怎么写提示词，以及写完后怎么处理（后处理器） | 提示词包库，可共享、可导入导出 |
| 角色生图提示词与方案绑定 | 这个角色的外貌标签、这个角色默认用哪个方案 | 角色设定（`persona_prompt_codec.dart`） |

画风和方案可以自由组合，互不绑定（2026-10-28 用户决定，修订 ADR0092）。

方案解析顺序：角色绑定的方案 → 绘图预设绑定的方案（兼容旧数据）→ 按渠道格式和模型自动匹配（自建方案优先于内置）。实现在 `plugin_prompt_resolution.dart`、`prompt_pack.dart`。

角色生图提示词每次请求时写入预设专属节参与渲染。`prompt_pack_migration.dart` 里把角色提示搬进预设的旧函数 `planRoleDrawingMove` 只有测试还在调用。

## 两种生图方式

只有「快速」和「调用」两种，旧配置的 `auto`、`stable` 读成调用（`settings_models.dart`）。

| | 快速 | 调用 |
|---|---|---|
| 模型怎么写 | 正文里写 `<image>提示词</image>` | 调 `draw_image` 工具 |
| 条件 | 无 | 模型同时有视觉和工具调用能力，否则自动退回快速 |
| 单轮数量 | 最多 8 个标签，多出的跳过；每个标签按参数出 1～4 张，总张数不另设上限 | 候选最多留 8 张，送回模型看图最多 4 张 |
| 何时发给用户 | 生成完原位补进回复 | 模型看过图后写空标签 `<image></image>` 才发；再调工具表示返工，旧图丢弃 |

提示词可以是中文，NovelAI 的英文限制已移除。NovelAI 默认模型是 `nai-diffusion-5-full`。

## 内置生图方案

| 方案 | 自动匹配 | 后处理器 |
|---|---|---|
| NovelAI | 渠道格式 `novelai` | `plain` |
| NovelAI 分镜漫画 | 不自动匹配，只能手选 | `novelai_manga` |
| MOSS 多格漫画 | `comfyui` 且模型含 moss-image | `moss_manga` |
| ComfyUI 通用 | `comfyui`（Flux 等纯自然语言底模除外） | `plain` |
| SD／ComfyUI（Danbooru 标签） | 非 ComfyUI 渠道的 Illustrious 等模型；ComfyUI 渠道默认走通用方案，要用得手选 | `plain` |
| 自然语言 | 兜底 | `plain` |

自定义方案可在方案列表页「从文件导入」（JSON，上限 2MB），详情页「导出为文件」。选了漫画后处理器的方案要配对应渠道，界面会判断兼容性。

## 漫画

分镜由主模型一次写完，后台分镜画师和摘要委托已删除（ADR0119）。

- **角色母表**：模型在 `<comic_plan>` 里写 `@C1`、`@C1_outfit`，提示词里引用时展开；台词原样保留。可见正文的母表优先，其次才看思考块。`<comic_plan>` 在界面折叠为「分镜规划」，也不进后续请求的历史。
- **编号槽位**：图片可带正整数 `id` 固定位置，缺失或重复时自动顺延。
- **NovelAI 分镜语法**：`@position manual`、`@page`、`@panel N`、`@character C1`、`@center x,y`、`Text: "台词"`、`@negative`；编译进 V4／V5 的分角色字段，跨页关键词自动换横版。
- **MOSS**：符号化 JSON（`layout`、`items`、`panel`、`slot`），由 `moss_manga_layout_compiler.dart` 编译成像素坐标。
- **冲突词清洗**（`manga_prompt_sanitizer.dart`）：多人漫画去掉前缀里的 `solo`、`no text`；反面词去掉 `text`、`comic`、`screentone`、`halftone`、`multiple views`、`speech bubble`，避免单图画风预设压制分格和台词。
- **内置角色「漫画家」**：工具模式，默认绑定 NovelAI 分镜漫画，可再绑任意酒馆预设。酒馆预设可用占位条目拼入当前方案，见 [酒馆兼容插件](../酒馆兼容插件/README.md)。

## 请求可靠性

**排队**（`image_request_gate.dart`）：同一渠道先进先出，并发上限 NovelAI 1、ComfyUI 1、其他 OpenAI 兼容渠道 2。队列键＝渠道格式＋规范化地址＋Key 哈希前 12 位。超时从拿到名额算起，排队时间不计。

**重试**（`media_request_retry.dart`，按重发是否安全分级，共用原超时预算）：

| 类型 | 最多重试 | 只在这些情况重发 |
|---|---|---|
| 提交生图（会计费） | 2 次 | 原始请求直接返回 429；网络错误和超时不重发 |
| 轮询、下载（只读） | 3 次 | 408、429、5xx，网络、握手、超时错误 |
| 语音合成 | 1 次 | 429、500、502、503、504，网络错误；超时和主动中止不重试 |

**参数修正**（`drawing_parameters.dart`）：宽高 256–2048，NovelAI 取整到 64；张数 1–4；步数 1–100；强度 0–20。越界自动收回，不是数字才报错。NovelAI 和 ComfyUI 以外的渠道忽略步数和强度。

## 占位、失败与多版本

- 生成中先在原文位置放占位图，比例取标签里的宽高或预设默认值；占位写入聊天时间线，刷新后仍在，但不进语义内容和请求。
- 成功后原位替换。失败转错误态，提示「生成失败，长按可重画」，并给上一条文字挂隐藏的失败说明，让模型下一轮知道。
- 真实宽高在存图时从文件头读出，旧消息由时间线缓存后台回填；解码放后台线程。
- 重画入口在长按菜单的「重新生成图片」「改词重画」，每次保留为版本（`ImageVersionEntry`），气泡里可切换。
- 已知缺口：删消息和重绘还没接取消信号，排队中的图仍会执行，出结果后才丢弃。

## 存储

`<应用数据目录>/generated_images/<渠道id>/<模型id>/`，目前只统计体积，没有清理机制（见 [存储体积治理](../正式版上线前阻断项_存储体积治理.md)）。

## 代码地图（`lib/src/`）

| 模块 | 文件 |
|---|---|
| 插件核心 | `features/plugins/image/image_plugin.dart`（`buildRequestSystemPrompt`、`getTools`、`convertInlineImageTags`、`generateInlineImage`、`regenerateImage`、`_handleDrawImage`），内核适配 `image_agent_plugin.dart` |
| 预设与参数 | `features/plugins/image/drawing_preset.dart`、`drawing_preset_provider.dart`、`image_config.dart`、`drawing_parameters.dart`、`draw_image_tool_schema.dart` |
| 生图方案 | `features/plugins/prompts/prompt_pack.dart`、`builtin_prompt_packs.dart`、`plugin_prompt_resolution.dart`、`prompt_pack_store.dart` |
| 请求 | `core/api/agent_image_api_support.dart`、`image_request_gate.dart`、`media_request_retry.dart`、`manga_prompt_sanitizer.dart`、`image_providers/` |
| 交付与展示 | `features/chat/services/chat_deferred_image_delivery.dart`、`chat_reply_display_transform.dart`（角色母表）、`chat_run_product_stages.dart`（候选图） |
| 界面 | `ui/features/plugins/pages/`：`image_plugin_detail_page`（绘图预设、生图方式）、`drawing_preset_editor_page`、`prompt_pack_pages`（方案列表与详情）、`prompt_section_editor_page`、`prompt_preview_page`、`image_generation_test_page`、`plugin_prompts_page`（工具提示词总控）；角色侧 `ui/features/character/pages/role_extra_prompt_page.dart` |

`draw_image_tool_description_page.dart`、`inline_image_prompt_page.dart`、`artist_preset_page.dart` 已没有入口，是待清理的死页面。

## 排查

设置页「生图测试」直接走 `draw_image` 工具链，用来判断是链路问题还是模型不可用。真实请求内容看手机诊断包里的生成快照（`tool/DIAGNOSTICS.md`）。
