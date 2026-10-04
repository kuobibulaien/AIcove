# 酒馆兼容插件（测试）

日期：2026-09-29。范围：标准聊天中的预设、正则、世界书实际上下文装配及逐条开关；不是完整 SillyTavern 复刻。

## 使用入口

界面于 2026-09-29 重写，沿用设置页分组卡片与 Moe 组件：

1. 聊天插件 → **酒馆相关**（列表末尾），与绘图、语音并列。首页「我的预设」列出全部预设，标着「默认」的就是默认预设；行尾「更多」或长按可设为／取消默认。
2. 「导入预设」选择 Chat Completion / Prompt Manager 预设 JSON，确认条目数与提示后导入；只用正则或世界书时选「新建空白预设」。
3. 预设详情顶部分段切换「提示词／正则／世界书／标签」：提示词逐条开关、点开看正文，底部「预设信息」看来源与参数生效情况；正则先打开「允许运行正则」再逐条开关；世界书点进单本后开关条目，条目多时可搜索；标签可改正文／折叠／选项或恢复自动识别。修改自动保存，共享此预设的角色从下一次请求起生效。
4. 角色编辑页仅选择酒馆预设绑定；未绑定时「跟随默认酒馆预设」。没设默认预设且角色未显式绑定时使用 AIcove 原模式。酒馆兼容常开，没有全局总开关；旧 enabled=false 会被忽略。条目/世界书/正则仍可分别启停。
5. 正则须额外允许整个预设运行；未允许时即使单条开启也不执行。明确绑定丢失不静默换预设，应重新选择。总配置损坏可在插件页「重置默认选择」，不删除资源和角色绑定。

“插件预设”在这里是一个完整组合：原始酒馆提示词预设 + 导入正则 + 世界书 + 各类条目开关。角色沿用 `Conversation.recipeId`，不增加第二份独立绑定，也不添加没有实际工具权限意义的角色插件勾选框。

## 实际兼容范围

| 分类 | 本批实际行为 |
|---|---|
| 预设 | 复用既有 `prompts` / `prompt_order`、role、深度、顺序、attach、宏／会话变量、prefill、请求参数解析。选定顺序组的条目可逐条开关；保留导入顺序，不提供可视化重排编辑器。 |
| 正则导入 | 支持单个酒馆脚本对象、脚本数组、`regex_scripts` 包装，以及预设内已支持的根/扩展/SPreset 脚本。按 ID 去重，原文件已有 ID 优先；无 ID 由内容生成。 |
| 正则执行 | 保留输入/AI历史/推理的既有副本转换；新增 WORLD_INFO placement=5，作用于命中的世界书请求内容。按 disabled、授权、promptOnly/markdownOnly、placement、深度筛选。 |
| 角色卡导入（2026-10-04，ADR0059） | 新建角色页导入 PNG／JSON／chub.ai 角色卡。开场白：读 `first_mes` 与 `alternate_greetings`，多套时弹窗选择（显示字数，超 6 行可展开），可在导入按钮下方改选；不拼进人设，创建时替换 `{{char}}`／`{{user}}`（遵循预设的用户名开关）写成会话首条 assistant raw 消息，显示副本走已授权显示正则，开场白不能重新生成。卡内 `regex_scripts`／`character_book`：创建时以显式绑定→默认预设→「基础上下文」为底复制「角色名 专用」组合并改绑，卡含正则时副本直接允许运行（不弹确认），之后在预设「正则」里逐条管理。不执行酒馆助手脚本；只把占位符换成网页的美化正则显示时替换成空（ADR0046 10-04 修订）；气泡样式下长开场白按标点切成多个气泡（10-04 用户裁决保持）；聊天内切换开场白未做。 |
| 世界书导入 | 支持酒馆 `entries` 对象，以及 JSON 角色卡的 `character_book.entries` 数组；PNG 角色卡的世界书经上一行的角色卡导入进入专用组合。重复内容导入保留原开关。 |
| 世界书触发 | 整本和单条启停、constant 常驻、主关键词任一匹配、selective 次关键词 0=AND ANY/1=NOT ALL/2=NOT ANY/3=AND ALL、scanDepth、caseSensitive、matchWholeWords、概率。关键词可用 `/pattern/flags`，支持 g/i/m/s/u。 |
| 世界书注入 | position=0/1 填入 worldInfoBefore/worldInfoAfter；position=4 按 depth、role（0 system/1 user/2 assistant）、order 注入聊天。depth=0 在最新消息后；关闭相应预设 marker 则该位置不注入。 |
| 预算 | 每本仅在 JSON 显式声明 token_budget 时另设单本配额，未声明则与酒馆一致只受总预算约束（2026-10-02 起，原缺省2048会让长条目世界书全部无法注入）；总世界书预算为上下文扣除回复预留后的25%，最高65536。常驻优先占预算，其次高order；总预算一旦溢出即停止激活后续条目（与酒馆一致），仅 ignoreBudget 条目继续尝试；最终文本按order升序排列，同order时入选越晚越靠前（对齐酒馆 unshift）。ignoreBudget忽略单本配额与溢出停止，不绕过总安全上限。使用本项目token估算器，最终请求超预算明确停止发送。 |

世界书扫描默认最近2条、大小写不敏感、普通子串匹配；支持条目覆盖扫描深度和匹配设置。**SillyTavern 的全局扫描设置不在普通世界书导出中，不宣称这些缺省值与用户原酒馆配置一致。**扫描输入是本轮请求的原始消息派生副本，不是气泡或整个数据库；旧消息超大但在扫描窗口外，不影响本轮扫描。

世界书关键词支持 `{{char}}`、`{{user}}`、`{{description}}`、`{{scenario}}` 常见替换；注入正文继续通过既有宏求值器。相同位置／深度条目组合后作为系统或指定角色消息发送。

## QuickJS / 小猫首批（2026-09-28）

已接入 Reborn2.3 / Meowssiah1.1 默认配置所需的 SPreset 纯逻辑流程：消息数组或合并文本后处理、按节点启用的 JS 工具工厂与 action、merge_tools、工具正文解包、输出脚本的 buffer/hold/state/final。原始函数不翻译、不靠名称识别。导入原 JSON 后沿用原有角色绑定和正则授权入口，不需要生成文本降级版。

浏览器 loader 不运行，模型凭证不进入脚本；JS 异常终止发送/处理，不静默跳过。高级选项的精确边界见 [ADR0042](../../../../../docs/项目记忆/决策记录/0042-QuickJS预设纯逻辑运行时.md)。小猫原有工具内正文等参数完整后显示；Kemini 传输正文增量显示见下一节。发送前重新估算脚本处理后的消息和完整工具定义，超限从原文副本恢复一次，仍超限则停止。

生命周期：ApiConfig 固定配置 → ChatSendApiRunner 创建 QuickJsPresetRuntime → 每轮 canonical 副本处理 → 输出解码 → finally 释放。JS 改写不回写已有消息；解码后的新正文才作为本次 rawReplyText。native library 与脚本资产随应用打包，无运行时 CDN 依赖。

## Kemini v3.1 B1：正文传输（2026-09-29）

已接入原版 Kemini Dramatron v3.1 的“防截断传输”链路：仅按脚本 ID／协议标记识别并读取配置，在 QuickJS 宿主运行通用正文传输协议，不执行整段 Tavern Helper。不限制脚本版本、文件名或内容哈希。匹配多份取第一份已启用的；锚点缺失追加控制提示词并记录 `transport_anchor_missing`；未识别或读取失败诊断后正常发送。

传输函数只承载正文，不进入业务工具 action。它可在预设 `function_calling=false` 时使用；模型 tools 能力不足或模型禁用工具时跳过，保留正常聊天并记录 `transport_skipped_model_without_tools`。原有业务工具与小猫工厂权限沿用旧规则。控制提示词、tool choice 和工具声明仅作用于本次请求副本。

OpenAI／Gemini 流式、非流式回复都经过解包，截断参数尝试恢复已收到的 content。普通正文与传输正文选最长者，避免重复；同轮业务调用保留并执行，后续请求不带已消费的传输封套。**OpenAI arguments delta／Gemini partialArgs 按约 50ms 合并后增量显示；Gemini 仅提供整块 args 时仍在结束后显示。** 普通正文立即参与最长选择，等长优先传输，不拼接。未完整的转义与 Unicode 不提前显示；预览不落库，最终保存以结束后解包为准。 原始聊天历史不改写，新回复的 rawReplyText 保存解包正文。

精确版本、配置读取、协议行为、回滚和作用域由 [ADR0043](../../../../../docs/项目记忆/决策记录/0043-预设传输工具与业务工具作用域.md) 统一规定。B2 显示顺序与历史重算尚未实施，行动选项和原生折叠尚未实现；面板联动、脚本变量持久化、事件桥接另行立项。可执行 HTML 继续清除。

本批验证：直接读取归档原版预设，使用真实 QuickJS／发送服务／Provider adapter 与 HTTP 边界替身；Kemini、既有小猫及相关流式／生图／压缩回归共 **98 项通过**。定向静态检查 0 error、0 warning，保留 11 条既有 `prefer_initializing_formals` info。证据位于仓库 `.codex-temp/kemini-b1-2026-09-29/` 的 `offline-regression-final.log`、`analyze-final.log` 和 `extraction-probe.json`。**真实模型请求未做**（当前会话环境未提供模型凭证），Debug 会话已停止，未构建、安装或宣称运行中的应用通过验收。

## 明确后推

- 世界书递归、向量检索、包含组、粘性／冷却／延迟、角色过滤、作者注、示例对话、Outlet 及非 normal 专用触发。依赖未支持位置或条件的条目在导入警告/条目说明中标记并跳过；递归开关只提示本版扫描聊天，不递归触发。
- 可执行 HTML、正则模式内宏替换 `substituteRegex`，以及完整的编辑事件语义仍后推；正则匹配改由 QuickJS，flags 按引擎实际支持编译。
- 高级可视化编辑、全资源库复用/删除/导出、云同步、角色包自动携带组合依赖、后台主动关怀/Analyzer 装配权限拓展。现有通用备份并不等于已携带本插件资源。
- 原有显示正则到气泡的完整重投影不是本批目标；既有审计记录的“清空显示文本回露原文／多模态分段绕过显示正则”不得因此被标成已修复。本批验收重点是最终请求上下文。

## 分层与存储

```text
TavernPluginDetailPage / TavernPresetDetailPage / TavernWorldBookPage / 角色预设选择弹窗
  → PresetRecipeImportController
  → TavernCompatibilityPort
  → SillyTavernPresetStore（本地JSON）

ChatSendBackendService.prepareApiConfig
  → resolvePreset(owner.recipeId)：显式绑定/默认值，一次性读取（兼容常开）
  → canonical raw派生历史 → 已授权消息正则
  → TavernWorldScannerPort：有界世界书扫描
  → 已授权 WORLD_INFO 正则
  → SillyTavernPresetAssembler：有序节点、marker、深度、宏、预算
  → ApiConfig（含固定的显示正则与 JS 配置快照）
  → ChatSendApiRunner / QuickJsPresetRuntime → Provider Adapter
```

存储目录：应用 documents 下 `aicove/sillytavern_presets/`。

- `st_preset_<hash>.json`：沿用既有预设信封；原始 `rawPreset` 保持不变，新增 `compatibilityData` 保存 `promptEnabled`、`regexEnabled`、`importedRegex`、`worldBooks`（源JSON、整本开关、entryEnabled）。既有 schemaVersion=2 信封的新增可选字段，旧文件无需迁移。
- `plugin_settings.json`：默认预设 ID；旧 enabled 字段不再控制全局启停。默认没有默认预设，保留既有显式角色绑定行为，不自动把新预设应用到所有角色。
- 本进程所有仓库实例串行写；读取校验信封ID与文件名一致，防止损坏信封将A的开关写进B；读-改-写在串行区中完成，临时文件flush后原子rename。写入/重导入失败不覆盖正常文件；队列空闲后释放Future。未承诺多进程同时编辑或断电的完整恢复保证。
- 单次导入≤2MiB；每书≤2000条、每组合≤32本、regex≤1000条、组合附加资源≤16MiB。世界书在可终止isolate中执行；正则由后台 QuickJS 执行，每次 native 调用1秒中断、批次1500ms预算并附失败警告；扫描窗口文本另有2M字符上限。
- 不改聊天DB schema、不更改raw message/blocks、不覆盖角色提示词，不把正则结果写成canonical历史。

诊断复用现有 `promptAssembly.sillyTavernPreset`：新增 effectivePresetId、worldInfo 的命中/跳过原因、位置、估算token；实际插入位置由 entries/finalMessages核对。`activated` 表示扫描命中，不保证marker开启或最终内容非空；最终装配结果才是模型收到的内容。未增加逐token或独立聊天正文日志。

回滚：先关闭酒馆插件，恢复原装配路径；资源保留。回退源码需仅撤回本批增量，不重置工作树，不删除资料；旧实现会忽略新附加数据。要彻底恢复旧版默认行为，应另行核对明确绑定的旧预设。

## 验证入口

```bash
flutter test --no-pub test/features/agent_context \
  test/features/chat/services/chat_send_service_test.dart \
  test/ui/features/plugins/tavern_plugin_detail_page_test.dart \
  test/ui/features/character/widgets/preset_recipe_section_test.dart
```

领域测试覆盖触发条件、扫描窗口、超时、大小写/整词/regex、概率、预算顺序、角色卡映射、并发开关保存/重开恢复、默认与显式绑定、请求快照不变。真实 `prepareApiConfig` 测试验证消息正则→世界书命中→世界书正则→最终消息，并与条目关闭、角色B及旧 enabled=false 仍常开的结果对照；未发远端模型请求。

UI测试通过真实导入按钮及文件选择替身导入三类JSON，验证逐条开关/授权/默认选择与文件重开，覆盖360/1000px，以及320px大字号1.8；角色选择另覆盖100条列表。Android验证用正常主入口 `flutter run --no-resident -d <设备号>`，不是以测试页面代替正式应用。

交付记录：相关122项通过，核心与新UI静态检查无问题；同级列表保留3条既有info。活跃工作树全量当时1156过133失败，包含旧审计与并行改造，不是本批通过声明；最终仅承诺上述相关回归。PKX110正常Debug主入口构建7ac8fdbd…已安装启动，收尾诊断`cb277496a62d4b56a255adaf7535bac5`确认构建期源码未变化、当前源码0差异。没有用真实模型请求替代离线最终messages断言。

### QuickJS 首批验收记录（2026-09-28）

- 58 项定向测试通过：原生超时/内存/异步/无宿主I/O、原始小猫回调、实际prompt正则与深度、工具工厂状态隔离、流式/非流式正文解码、回退、变换后预算、既有图像工具与上下文恢复。
- 额外请求组装检查4过1失败：停用酒馆后仍残留`B_MAIN`。将本批5个集成文件恢复为HEAD源码的隔离副本中，同一断言仍失败；这是当时旧总开关断言的失败记录，不计为该批通过。2026-10-02 首版口径明确兼容常开，旧 enabled=false 不应停用角色绑定；对应集成测试改验常开及条目开关，当前修理验证另记。
- 改动范围静态检查无error/warning，11条既有构造参数风格info。最终macOS与Android ARM64 Debug构建通过；Mac产物内真实QuickJS动态库再次执行两份原始输出回调通过，两端打包JS资产与源码一致。
- Android引擎动态库1,043,776字节，Mac引擎1,066,608字节（Debug产物；不是整个安装包增量或Release体积）。引擎源码版本/SHA/许可证随本地包保存。
- 未安装新应用、未重新导入原始预设、未调用生产模型；不宣称手机运行或真实生成验收。工具参数须完整后才能解包成正文；高级SPreset配置边界见ADR0042。

证据归档：仓库`.codex-temp/js-sandbox-research-2026-09-28/implementation-evidence/`及`packaged-runtime-results.json`。这批不改变此前发现的显示重投影缺口。

## 官方参考

- https://docs.sillytavern.app/usage/core-concepts/worldinfo/
- https://docs.sillytavern.app/usage/st-script/ （世界书字段的position/role/selectiveLogic映射）
- https://raw.githubusercontent.com/SillyTavern/SillyTavern/release/public/scripts/world-info.js

本批按查阅时的格式实施，未固定上游commit，不保证未来格式自动兼容。
