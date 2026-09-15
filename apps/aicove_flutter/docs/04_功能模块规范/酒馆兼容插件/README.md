# 酒馆兼容插件（测试）

日期：2026-09-06。范围：标准聊天中的预设、正则、世界书实际上下文装配及逐条开关；不是完整 SillyTavern 复刻。

## 使用入口

1. 聊天插件 → **酒馆兼容插件（测试）**，与绘图、语音并列。
2. 导入 Chat Completion / Prompt Manager 预设 JSON，或者创建基础组合。
3. 进入组合的「预设／正则／世界书」标签，导入资源、查看内容并逐条开关。修改自动保存，共享此组合的角色从下一次请求起生效。
4. 角色编辑页仅选择酒馆预设绑定；未绑定时使用插件页标星的默认预设。没设默认预设或总开关关闭时使用 AIcove 原模式。
5. 正则须额外授权整个预设运行；未授权时即使单条开启也不执行。明确绑定丢失不静默换预设，应重新选择。总配置损坏可在插件页确认停用并重置默认选择，不删除资源和角色绑定。

“插件预设”在这里是一个完整组合：原始酒馆提示词预设 + 导入正则 + 世界书 + 各类条目开关。角色沿用 `Conversation.recipeId`，不增加第二份独立绑定，也不添加没有实际工具权限意义的角色插件勾选框。

## 实际兼容范围

| 分类 | 本批实际行为 |
|---|---|
| 预设 | 复用既有 `prompts` / `prompt_order`、role、深度、顺序、attach、宏／会话变量、prefill、请求参数解析。选定顺序组的条目可逐条开关；保留导入顺序，不提供可视化重排编辑器。 |
| 正则导入 | 支持单个酒馆脚本对象、脚本数组、`regex_scripts` 包装，以及预设内已支持的根/扩展/SPreset 脚本。按 ID 去重，原文件已有 ID 优先；无 ID 由内容生成。 |
| 正则执行 | 保留输入/AI历史/推理的既有副本转换；新增 WORLD_INFO placement=5，作用于命中的世界书请求内容。按 disabled、授权、promptOnly/markdownOnly、placement、深度筛选。 |
| 世界书导入 | 支持酒馆 `entries` 对象，以及 JSON 角色卡的 `character_book.entries` 数组；不读取 PNG 角色卡。重复内容导入保留原开关。 |
| 世界书触发 | 整本和单条启停、constant 常驻、主关键词任一匹配、selective 次关键词 0=AND ANY/1=NOT ALL/2=NOT ANY/3=AND ALL、scanDepth、caseSensitive、matchWholeWords、概率。关键词可用 `/pattern/flags`，支持 g/i/m/s/u。 |
| 世界书注入 | position=0/1 填入 worldInfoBefore/worldInfoAfter；position=4 按 depth、role（0 system/1 user/2 assistant）、order 注入聊天。depth=0 在最新消息后；关闭相应预设 marker 则该位置不注入。 |
| 预算 | 每本使用 JSON 的 token_budget，缺省2048；总世界书预算为上下文扣除回复预留后的25%，最高65536。常驻优先占预算，其次高order；最终文本按order升序排列。ignoreBudget只忽略单本配额，不绕过总安全上限。使用本项目token估算器，最终请求超预算明确停止发送。 |

世界书扫描默认最近2条、大小写不敏感、普通子串匹配；支持条目覆盖扫描深度和匹配设置。**SillyTavern 的全局扫描设置不在普通世界书导出中，不宣称这些缺省值与用户原酒馆配置一致。**扫描输入是本轮请求的原始消息派生副本，不是气泡或整个数据库；旧消息超大但在扫描窗口外，不影响本轮扫描。

世界书关键词支持 `{{char}}`、`{{user}}`、`{{description}}`、`{{scenario}}` 常见替换；注入正文继续通过既有宏求值器。相同位置／深度条目组合后作为系统或指定角色消息发送。

## 明确后推

- 世界书递归、向量检索、包含组、粘性／冷却／延迟、角色过滤、作者注、示例对话、Outlet 及非 normal 专用触发。依赖未支持位置或条件的条目在导入警告/条目说明中标记并跳过；递归开关只提示本版扫描聊天，不递归触发。
- 正则 JavaScript 扩展／可执行 HTML／不支持的 flags、正则模式内宏替换 `substituteRegex`，以及完整的编辑事件语义。已有 regex 引擎安全边界继续保留。
- 高级可视化编辑、全资源库复用/删除/导出、云同步、角色包自动携带组合依赖、后台主动关怀/Analyzer 装配权限拓展。现有通用备份并不等于已携带本插件资源。
- 原有显示正则到气泡的完整重投影不是本批目标；既有审计记录的“清空显示文本回露原文／多模态分段绕过显示正则”不得因此被标成已修复。本批验收重点是最终请求上下文。

## 分层与存储

```text
TavernPluginDetailPage / PresetRecipeSection
  → PresetRecipeImportController
  → TavernCompatibilityPort
  → SillyTavernPresetStore（本地JSON）

ChatSendBackendService.prepareApiConfig
  → resolvePreset(owner.recipeId)：总开关 + 显式绑定/默认值，一次性读取
  → canonical raw派生历史 → 已授权消息正则
  → TavernWorldScannerPort：有界世界书扫描
  → 已授权 WORLD_INFO 正则
  → SillyTavernPresetAssembler：有序节点、marker、深度、宏、预算
  → ApiConfig（含固定的显示正则快照）→ 原有 Provider Adapter
```

存储目录：应用 documents 下 `aicove/sillytavern_presets/`。

- `st_preset_<hash>.json`：沿用既有预设信封；原始 `rawPreset` 保持不变，新增 `compatibilityData` 保存 `promptEnabled`、`regexEnabled`、`importedRegex`、`worldBooks`（源JSON、整本开关、entryEnabled）。既有 schemaVersion=2 信封的新增可选字段，旧文件无需迁移。
- `plugin_settings.json`：总开关和默认预设 ID。默认启用但没有默认预设，保留既有显式角色绑定行为，不自动把新预设应用到所有角色。
- 本进程所有仓库实例串行写；读取校验信封ID与文件名一致，防止损坏信封将A的开关写进B；读-改-写在串行区中完成，临时文件flush后原子rename。写入/重导入失败不覆盖正常文件；队列空闲后释放Future。未承诺多进程同时编辑或断电的完整恢复保证。
- 单次导入≤2MiB；每书≤2000条、每组合≤32本、regex≤1000条、组合附加资源≤16MiB。世界书和正则匹配在可终止isolate中执行，超1500ms停止并附警告；扫描窗口文本另有2M字符上限。
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

领域测试覆盖触发条件、扫描窗口、超时、大小写/整词/regex、概率、预算顺序、角色卡映射、并发开关保存/重开恢复、默认与显式绑定、请求快照不变。真实 `prepareApiConfig` 测试验证消息正则→世界书命中→世界书正则→最终消息，并与条目关闭、角色B及插件关闭结果对照；未发远端模型请求。

UI测试通过真实导入按钮及文件选择替身导入三类JSON，验证逐条开关/授权/默认选择与文件重开，覆盖360/1000px，以及320px大字号1.8；角色选择另覆盖100条列表。Android验证用正常主入口 `flutter run --no-resident -d e949b887`，不是以测试页面代替正式应用。

交付记录：相关122项通过，核心与新UI静态检查无问题；同级列表保留3条既有info。活跃工作树全量当时1156过133失败，包含旧审计与并行改造，不是本批通过声明；最终仅承诺上述相关回归。PKX110正常Debug主入口构建7ac8fdbd…已安装启动，收尾诊断`cb277496a62d4b56a255adaf7535bac5`确认构建期源码未变化、当前源码0差异。没有用真实模型请求替代离线最终messages断言。

## 官方参考

- https://docs.sillytavern.app/usage/core-concepts/worldinfo/
- https://docs.sillytavern.app/usage/st-script/ （世界书字段的position/role/selectiveLogic映射）
- https://raw.githubusercontent.com/SillyTavern/SillyTavern/release/public/scripts/world-info.js

本批按查阅时的格式实施，未固定上游commit，不保证未来格式自动兼容。
