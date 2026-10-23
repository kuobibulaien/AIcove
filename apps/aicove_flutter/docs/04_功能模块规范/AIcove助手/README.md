# AIcove 助手与新手教程

- 状态：方向已确认（2026-10-17）；T1～T4 已实现（2026-10-17，离线测试与真实 DeepSeek 通过，Codex 验收，实机未验）；10-19 改名 AIcove酱并扩到全权限（ADR0093）
- 10-21 起：恒为工具模式（ADR0097），直接用插件和内置 aicove 空间，不再派活；剧本台词改用文档模式消息渲染，选项与 Key 输入放进跟随材质的交互组件卡片（仍是本机界面状态，不写消息表）；界面类设置（皮肤颜色、壁纸、分段、工具提示词、会话样式）全部开放给她改，另有「恢复默认界面设置」（通用设置·高级、设置加载失败页、她的工具三处）。
- 关联：ADR0073（引导 Agent，本方案定稿其授权与形态）、ADR0087 第 6 条（AIcove 默认空间）、ADR0064（内核与内置插件）、ADR0066（本地隐私优先）

## 目标

新用户装好 AIcove 后，跟着助手走完「拿到 Key → 填进来 → 能聊天」，不需要懂任何概念；老用户一键跳过。

接上模型之后，助手的**主要工作**（2026-10-17 用户明确）：帮用户写角色卡、改角色卡；排查插件为什么没生效；找出上下文的问题（太长、缺内容、指令打架）；理清酒馆预设、正则、世界书这些复杂配置；最终由它直接上手修改，保证用户的体验，只有重大决定才问用户。回答「API 是什么」这类常识只是顺带。

验收（T1）：清空数据首次启动 → 自动打开助手聊天 → 选「完全没用过」→ 跟着剧本拿到 DeepSeek Key 并粘贴 → 测试连接通过 → 默认聊天模型自动设好 → 写入一条固定开场白，之后的回复由真实模型生成，全程不进设置页；另测选「跳过全部教程」时不再出现任何引导。

## 不做

- 角色简介（description）目前不存数据库（会话表没有这一列，改了很快被数据库监听冲掉、重启为空），助手不能改简介，待单独修数据层与同步。
- 不做全屏多页向导；不做中心服务器、不内置 Key（ADR0073 第 3 条）。
- 第一版不碰语音通话教程、诊断体检（排在 T4）。

## 形态：一个内置角色，两个阶段

**助手是一个内置角色**：固定 id `aicove_assistant`，各设备相同，角色和会话都走现有同步。人设（名字、头像、说话风格）和普通角色一样可以改；工具、资料库、审批方式由只在助手会话里安装的内置插件 `aicove_assistant` 挂载，不在角色卡里，改人设不影响能力。每台设备只写入一次（本机标记 `aicove_assistant_seeded_v1`，新装和升级都会有），用户删掉后不会自动回来（设置首页「新手教程」入口已于 10-18 按用户要求移除；`restoreAssistant` 保留，暂无界面入口）。默认置顶在聊天列表。首次启动且没有可用模型时，自动打开一次助手聊天。

**阶段一 · 剧本（没有可用模型时）**：助手聊天页里显示固定剧本，用户点卡片推进，**不调用模型**。剧本卡片是本机界面状态，不写进消息表；剧本结束时写入一条普通助手消息作为开场，之后的对话照常落库、同步。

**阶段二 · Agent（有可用模型后）**：同一会话由真实模型驱动。

判定「有可用模型」：存在一个启用、能力含 `chat`、至少有一把 Key 的渠道，且默认聊天模型落在它上面。另一台设备同步过来的配置同样算数，此时直接进入阶段二。

## 阶段一剧本

第一张卡片先问经验：

> 你之前配置过 API、用过 AI Agent 吗？
> 「完全没有，带我一步步来」「配过 API，直接填 Key」「都会，跳过全部教程」

- **完全没有** → 从第 1 步走完整流程，每步附带「这是什么？」展开解释。
- **配过 API** → 直接到第 1 步的选服务商，然后第 3 步粘贴，不显示解释。
- **跳过全部教程** → 记为本机已跳过，不再弹任何引导；助手仍在列表里，没配模型时它的聊天页只显示一行「先到 设置 · 渠道 配好模型就能和我聊」。

| 步 | 助手说 | 卡片／操作 |
|---|---|---|
| 1 选服务 | AIcove 本身不带 AI，要接一家「模型服务」；推荐 DeepSeek：国内直连、按量计费、便宜 | 「DeepSeek（推荐）」「其他家」（Gemini／OpenRouter／自定义 OpenAI 兼容地址）「我已经有 Key 了」→ 第 3 步 |
| 2 拿 Key | 分步图文：打开开放平台 → 注册登录 → 充值 → API Keys → 创建 → 复制（Key 只显示一次） | 「打开 DeepSeek 开放平台」（系统浏览器）；「我复制好了」 |
| 3 粘贴 | 把刚复制的 Key 粘贴到这里 | Key 输入框（剪贴板里是 `sk-` 开头时提示一键粘贴）；保存后**立即测试连接** |
| 4 校验 | 失败按原因说人话：Key 不对／余额不足／网络不通，并给下一步 | 「重新粘贴」「去充值」「换一家」 |
| 5 完成 | 接好了，默认用 `deepseek-flash` | 自动设默认聊天模型；切到阶段二，助手发出第一条真实模型回复 |

- 任何一步都能「先跳过」，下次进助手聊天页从原处继续（进度记本机）。
- 「其他家」复用现有「添加渠道」弹层（选格式、填地址和 Key），回来后列出所有有 Key 的聊天渠道模型，点一个即测试并设为默认。
- 剧本文案是固定写死的界面文字（只有这里是写给用户看的）。DeepSeek 充值门槛、页面路径等外部事实，上线前联网核实一次。

**Key 安全**：Key 只经输入卡片直接写入渠道配置，界面只显示 `sk-****abcd`；任何阶段 Key 的值都不进入模型上下文。

## 阶段二 Agent

### 工具

| 类别 | 工具 | 说明 |
|---|---|---|
| 文档（T2 ✅） | `aicove_docs_read(doc)` | 资料库目录写在系统提示词里，按 id 读全文（同技能包套路）；篇数少，暂不做检索 |
| 读角色（T2 ✅） | `aicove_list_roles`／`aicove_read_role` | 人设提示词、绘图提示、称呼、插件选择、绑定预设、思考档位、模型覆盖；隐私空间里的角色不出现 |
| 读预设（T2 ✅） | `aicove_list_presets`／`aicove_read_preset` | 按当前顺序的条目（开关、注入位置、内容截断 1500 字）、正则（授权、作用范围）、世界书条目、参数兼容、告警、被哪些角色绑定 |
| 查上下文（T2 ✅） | `aicove_inspect_context(role_id)` | 复用调试页「联系人上下文」同一套 `previewContext`（与真实发送同装配、不发请求不落库）：模型、预设、各插件是否注入及原因、系统提示词各来源、工具列表、token 与压缩阈值；聊天正文按角色只给条数和 token，记忆／摘要／历史类来源只给字数 |
| 改角色卡与预设（T3a ✅） | `aicove_update_role`／`aicove_create_role`／`aicove_set_role_plugins`／`aicove_bind_preset`／`aicove_toggle_preset_item`／`aicove_authorize_regex` | 经现有领域服务写入（角色走 `applyContactEdit`，预设走预设存储），写可撤销记录，按风险档自动审批 |
| 改设置（T3b ✅） | `aicove_settings_get`／`aicove_settings_set` | 类型化、白名单键：每个键声明类型、取值范围、中文说明、所在页面和**风险档**；经 `AppSettingsNotifier` 写入，写可撤销记录 |
| 要 Key（T3b ✅） | `aicove_request_key(provider_id)`＋只读的 `aicove_list_providers` | 在助手聊天页放一张 Key 输入卡片，值经 `editProvider` 直接写进渠道（没启用的同时启用），模型只拿到「卡片已显示」；不阻塞工具（工具超时只有 30 秒），用户什么时候填都行。渠道列表只给是否有 Key，不给 Key |
| 跳转（T3b ✅） | `aicove_open_page(target, id)` | 只接受预定义页面（模型、默认模型、渠道详情、通用、插件、个人资料、角色编辑、联系人上下文、预设详情），带 id 的先校验存在（隐私空间角色不存在），生成「去看看」按钮 |

### 自动审批（参考 Claude Code auto mode 与 Codex Auto-review）

调研要点（来源见文末）：两家都是**先走确定性规则、再交给独立的审核模型**；审核模型只看「用户说了什么＋Agent 要做什么」，**不看 Agent 自己的解释和工具返回的内容**，防止被说服、防止网页／文件里的注入；被拒后把理由还给主 Agent 让它换更安全的做法，连续被拒几次就停下问人；用户的泛泛请求不算授权具体的危险操作（「整理一下」不等于「全删掉」）。

AIcove 的取舍：设置项数量有限、每项都能事先标风险，所以**大部分判断由风险档确定性完成，审核模型只处理中间地带**，省一次请求也更可预期。

| 风险档 | 例子 | 处理 |
|---|---|---|
| 只读 | 查设置、读文档、读空间投影 | 直接执行 |
| 可撤销 | 主题、材质、壁纸、思考档位、在已配好的渠道里换模型、开关普通插件 | 直接执行；聊天里出一条「已把 X 改成 Y · 撤销」 |
| 需审核 | 一次改多项、改角色卡／预设内容、新建渠道、用户没直接提到的改动 | 审核模型判「放行／拒绝（附理由）／交给用户」 |
| 重大 | 删除数据、开启云同步或局域网配对、把聊天发给一家新的服务商（换到另一家渠道的模型）、读聊天记录、导出数据 | **始终**弹卡片问用户，审核模型不能代批；卡片可选「本次对话内都允许」（仅限读聊天记录这类读取） |
| 禁止 | 读 Key 的值、把数据发到用户没给过的地址 | 不提供这样的工具；`SecretRedactor` 兜底 |

- 审核模型：默认用助手同一个模型，单独一次请求，输入只含用户消息和本次工具调用（参数），输出 `{verdict, reason}`；请求失败或解析不了按「交给用户」处理，不默认放行。
- 熔断：同一轮连续 3 次被拒，停下并把情况告诉用户。
- 用户可在助手设置里改成「每次都问我」（等同现有 `manual`），重大档在任何模式下都问。
- 落地（T3a）：助手会话的 run 挂 `AgentToolPolicy(customGate: AssistantToolGate)`，闸门按工具和参数同步判风险档（只读、可撤销直接放行；需审核、重大转审批端口）；`AssistantApprovalPort` 对重大档只问用户，对需审核档请审核模型，审核失败或解析不了交给用户；内核新增 `ExplainingApprovalPort`，拒绝理由以「未获允许：…」回给主 Agent。每次判定照旧发 `ToolGated` 事件进 trace（只含工具名和结果，不含参数）。ADR0073 原「无限制模式」不再需要，由本表取代。

### 内置资料库：写给 Agent 看的 AIcove 现状

模型本来就懂 API、Key、Token 是什么，资料库不重复这些常识，只写**模型不可能知道的 AIcove 现状**，并标注适用版本：

- **产品定位与边界**：本地优先、不是治疗产品、不支持 Web、没有中心服务器（Key 只能用户自己的）。
- **功能地图**：底栏三页（聊天／空间／设置）各有什么、每个设置页叫什么、在哪一层；界面用语对照（如「空间」以前叫「工作区」）。
- **设置项清单**：由 `settings_set` 的白名单注册表**自动生成**（键、中文名、取值、风险档、所在页面），保证文档和工具不会对不上。
- **渠道与模型**：内置有哪些渠道、各自能力（聊天／语音／识别／生图）、推荐默认值、思考档位怎么生效。
- **功能依赖关系**：例如语音通话需要「音色预设＋渠道 Key＋识别来源」，主动回复、记忆、后台任务各自依赖什么。
- **已知限制与未实现**：哪些功能还没做或只做了一半，避免助手向用户承诺不存在的功能。
- **常见故障 → 排查路径**：401／402／超时分别是什么意思、该看哪里。
- **沟通指引**：用户选过「完全没有经验」时用大白话、一次只给一步。

存放在 `assets/aicove_docs/*.md`，随版本发布；每次发版前按项目记忆与界面布局说明核对一遍。

## 回复里的交互组件

助手回复可以带能点、能改的组件（清单、步骤、决策树、测验、指标、数据表、联动计算面板），用户的操作下一轮回传给模型。格式、组件、分批见 [交互组件方案](交互组件方案.md)（ADR0091）。她还能放出「快捷面板」（角色、绘图预设、音色预设、设置、渠道列表），用户点选后打开编辑页或直接改，见 [快捷面板方案](快捷面板方案.md)（ADR0094）。

## 分批

| 批 | 内容 | 依赖 |
|---|---|---|
| T1 ✅ | 内置助手角色（固定 id、置顶、可重建）＋经验选择卡＋剧本卡片＋Key 输入与测试连接（复用 `ProviderDetailActions.testModel`，先测后存）＋自动设默认模型＋设置页「新手教程」入口 | 无 |
| T2 ✅ | 助手专属只读工具（资料库、角色、预设、上下文预览）＋6 篇写给 Agent 的资料＋能力说明提示词；只在助手自己的会话里装配 | T1 |
| T3a ✅ | 直接上手修改角色卡与预设（见上表）＋自动审批（风险档闸门、审核请求、熔断、确认卡片、撤销条） | T2 |
| T3b ✅ | 设置白名单与风险档、设置项清单文档自动生成、Key 输入卡片、跳转按钮 | T3a |
| T4 ✅ | 语音通话资料、只读体检 `aicove_checkup`、「修改前每次问我」开关 | T3 |

## T1 实现位置

- 剧本状态与动作：`lib/src/features/assistant/`（`domain/assistant_onboarding.dart` 状态、失败分类、`hasUsableChatModel`；`application/assistant_onboarding_controller.dart` 本机进度 `assistant_onboarding_v1`、先测后存、完成写开场白）
- 内置角色：`assets/characters/preset_characters.json` 的 `aicove_assistant` 条目、人设 `assets/characters/prompts/aicove_assistant.md`；写入与恢复在 `ConversationsNotifier`（`_seedAssistantOnce`／`restoreAssistant`）
- 界面：`lib/src/ui/features/assistant/`（剧本视图、自动打开与设置入口）；聊天页在助手会话且剧本未结束时用剧本视图替换消息列表与输入框
- 测试：`test/features/assistant/`、`test/ui/features/assistant/`（`--dart-define=WRITE_ASSISTANT_PREVIEW=true` 生成源码渲染预览）

## T2 实现位置

- **只读与隐私边界**（Codex 两轮验收后定）：上下文预览只返回结构与大小（来源名＋字数、插件注入状态、工具名、按角色的消息条数与 token、告警条数），不返回任何正文、装配告警原文或插件异常原文——装配结果会混入聊天正文与记忆（预设宏、运行时规则块），按来源名过滤拦不住。预览通过 `PluginRequestContext.readOnly` 告诉插件不启动后台工作（记忆插件不续跑整理）。**接受的例外**：预览仍可能写入派生缓存（MVU 状态表，按原文推算、读取时自愈）和幂等的一次性迁移（旧绘图组合转预设、音色与插件提示词旧配置迁移），这些写入只取决于输入、与真实发送或打开对应页面时的写入相同，不改变用户可见的数据含义，不为预览另做纯内存路径。

- 工具：`lib/src/features/assistant/application/assistant_toolset.dart`（依赖都是函数注入，工具执行时才读取，避免与上下文预览互相依赖）；接线 `assistant_providers.dart`
- 装配：`assistant_plugin.dart` 内置插件，`ChatSendBackendService` 只在 `conv.id == aicove_assistant` 时安装——能力属于助手的会话，不在可编辑的角色卡里；模型不支持工具调用时只注入一段说明
- 资料库：`assets/aicove_docs/*.md`，目录 `domain/aicove_docs.dart`；改了功能要同步改这里，尤其 `known_limits.md`
- 测试：`test/features/assistant/assistant_request_test.dart`（真实装配、隐私空间不可见、预览不含聊天正文、资料随包）、`assistant_real_model_test.dart`（需要 `DEEPSEEK_API_KEY`；「小雪为什么不画画」时模型自己依次调了列角色、读角色、预览上下文、读资料，结论正确）

## T3a 实现位置

- 风险档、闸门、审核模型、审批端口：`application/assistant_review.dart`；写工具与撤销写回：`application/assistant_write_tools.dart`；确认卡片状态：`application/assistant_approvals.dart`；接线：`assistant_providers.dart`、`ChatSendBackendService._assistantToolPolicy`（只在助手会话、非预览、内核 runner 时挂；旧 runner 没有闸门，助手退回只读）。
- 风险档：读工具只读；预设条目开关可撤销；改／建角色、换绑预设、正则授权需审核；开启联网搜索（「全部插件」含它）为重大——聊天内容会用于搜索请求。
- 审核请求：同一渠道和模型、不带预设／工具／回复处理器，输入只有用户最近 6 句话和本次调用（字符串参数截到 2000 字）。熔断：同一 run 连续 3 次被拒（审核拒绝或用户拒绝）后不再审核，直接让主 Agent 告诉用户。
- 撤销：复用 `FileChangeJournal`（本机 JSON、不同步、留最近 50 条），新增 `CheckedChangeApplier`：撤销前确认修改后的值仍在，被别处改过就拒绝，不覆盖新内容。新建角色撤销＝移进回收站。
- 角色写入前从数据库读（列表状态跟随数据库监听，刚写完可能还是旧值），多个写入串行（列表 notifier 按整表写回，并发会丢改动）；风险判断用同步的列表状态，可能落后一次写入片刻，对隔着一轮模型请求的调用无影响。
- 界面：助手聊天页输入框上方 `AssistantActivityPanel`，待确认卡片（允许／不要，run 停止等待时自动收起并按拒绝处理）与最近 3 条可撤销修改。
- 测试：`test/features/assistant/assistant_review_test.dart`（分档、端口、熔断、解析）、`assistant_request_test.dart` 的 writes 组（真实装配挂闸门、改角色保留绘图提示且可撤销、改后再改拒绝撤销、隐私空间不可改、联网搜索为重大、预设开关与新建角色撤销）、`test/ui/features/assistant/assistant_activity_panel_test.dart`；真实 DeepSeek：「把小雪的简介改成…」模型调 `aicove_update_role`、审核放行、写入成功、没打扰用户；只问问题却要整段重写人设时审核判拒绝并说明理由。

## T3b 实现位置

- 设置白名单：`application/assistant_settings.dart`（`kAssistantSettings`，13 项：深浅色、材质、皮肤、字体、界面缩放、新会话默认样式、发送自动回底、消息分段、隐藏用户头像、语音消息展开、我的名字、默认聊天模型、上下文窗口）；资料库 `settings` 页由 `assistantSettingsDoc()` 按白名单现生成，不是资产文件。风险：我的名字、上下文窗口需审核；默认聊天模型同渠道内可撤销，换到另一家渠道为重大，且校验渠道启用、能聊天、有 Key、确有此模型；其余可撤销。
- 工具：`application/assistant_settings_tools.dart`（读写与撤销写回 `AssistantSettingApplier`）、`application/assistant_cards.dart`（卡片状态、渠道列表、Key 卡片、跳转按钮）；界面在 `AssistantActivityPanel`（Key 卡片的输入直接写渠道，跳转按钮按 target 打开对应页面）。
- 测试：`test/features/assistant/assistant_settings_test.dart`（写入与撤销、改后再改拒绝撤销、未知键与越界值不写、换渠道为重大、无模型拒绝、渠道列表不含 Key、隐私空间角色不能跳转、资料页覆盖全部键）、面板测试的 Key 卡片用例；真实 DeepSeek：「换深色＋填 OpenRouter 的 Key」模型调了设置读写、渠道列表和 Key 卡片，深色生效、卡片出现、回复不含 Key、没打扰用户。

## T3 验收修复（Codex 第一轮，2026-10-17）

- 插件风险：列表状态里找不到角色（刚新建）按重大处理；执行时按数据库重算，库里是重大而闸门判得更低就拒绝并请模型重新调用（重新调用时按新状态判档）。
- 撤销：`CheckedChangeApplier.applyIfCurrent` 把「核对＋写回」放在一起，角色在角色存储的串行队列里一次完成（`editIf`／`deleteIf`）；预设与设置仍是先核对再写回，中间只有本机一次读写的间隔，用户恰在这一瞬间改同一项的情况接受不处理。新建角色的撤销记下创建后的字段，被改过、已产生消息或进了隐私空间都拒绝撤销。所有角色写入（含撤销）在存储层拒绝隐私空间角色。
- 设置：默认模型的撤销记录整个有序列表；「我的名字」清空记为 null，与读取一致；参数类型不对（插件列表不是列表、开关不是布尔）一律 invalid，不再按默认值执行。
- 审核：字符串参数超过 8000 字不交审核模型，直接问用户（不凭前缀放行）。
- 面板：卡片增减时按尺寸变化通知重新测量，聊天列表底部留白跟着变。

## T3 验收修复（Codex 第二轮，2026-10-17）

- 「每次问我」：闸门和审批端口每次调用时实时读开关（运行中途打开立即生效）；开着时，没登记风险档但声明为非只读的工具（如 `delegate_task`、绘图）也要问用户。
- 插件风险绑定实际判档：闸门判 `aicove_set_role_plugins` 时按参数记下判档结果和当时的插件选择；执行时库里的选择和判档时不同、且判档不是重大，就拒绝并请模型重新调用，不会把可撤销档的批准用到另一份选择上。
- 角色撤销用数据库事务：`editIf`／`deleteIf` 的核对（是否存在、隐私空间、字段、消息数）和写入在同一个 Drift 事务里，角色编辑页保存或同步写入只能落在核对前或写入后；另外要求列表状态与库里同一版本（`updatedAt` 按毫秒比较），列表落后时拒绝撤销，避免列表通知器按旧状态整表写回。
- 新建角色的撤销记录额外存创建后的 `updatedAt`：头像、壁纸、音色、思考档位等任何保存都会改它，改过就拒绝撤销。
- 默认模型：校验、判档、撤销记录都先按设置层同一规则规范化模型引用（`deepseek: x` → `deepseek:x`）并去重，撤销不再误报「之后又被改过」。
- 新建角色先校验所有文本参数类型，再调用创建。
- 体检按实际生效的预设检查：角色没绑定时看全局默认预设，默认预设丢失或酒馆配置损坏单独报错。
- 资料：语音识别各家适配器统一写「都还没用真实 Key 验证」；通话思考改为「能关就关，关不了用最低档」。

## T3 验收修复（Codex 第三轮，2026-10-17）

- 插件判档按调用分开：（第四轮改为）内核 `GatedToolExecutor` 给每次执行一个 `ToolCallScope`（Zone 里的对象，闸门判档、审批端口、工具本身都在里面运行），判档把「参数、档位、当时的插件选择」记在本次的 scope 里，执行端只读自己 scope 的记录；重大判档还要 `scope.outcome == approved` 才算用户同意。不依赖提供商调用 id（Gemini 流式等会重复）。审批请求 `ApprovalRequest` 另加了可选的 `callId`。
- 插件写入在最终写入的同一个事务里再核对一次：库里的插件选择仍是判档时那份、且（未经重大确认时）写入不会新开联网搜索，否则拒绝并请模型重试。（第四轮）撤销记录仍先写：记录写不进（日志损坏、目录不可写）就不改；（第五轮）「写记录→守卫写入→拒绝时收回」整组在 `FileChangeJournal.commitIf` 里持日志锁完成，撤销要排在整组之后，不会拿到还没落地的记录。
- 角色列表只写改动的那一行：`ConversationsNotifier.updateOne`／`createNew`／`addOne`（第四轮：首次打开预设角色的 `openRoleChat` 改用 `addOne`）不再把整份列表写回（整表写回会用列表状态里别的角色的旧副本盖掉更新的保存，撤销刚提交就被抵消）；测试替身随 `setAll` 一并替换 `saveOne`。
- 剩余：`_listMatches` 在列表通知还没到时会短暂拒绝本可执行的撤销（提示「之后又被改过」，用户稍后重试即可）；`updatedAt` 是毫秒时间戳，同一毫秒内的两次保存分不出来。

## T4 实现位置

- 资料：`assets/aicove_docs/voice_call.md`（怎么打、三样配置、常见提示、通话限制）。
- 体检：`application/assistant_checkup.dart`，只读、无正文：默认模型不可用、启用却没 Key 的聊天渠道、绑定预设丢失、预设关了函数调用却开了绘图／联网搜索、预设正则未授权、一个插件都没开、开了语音却打不了电话（复用 `VoiceCallFactory.unavailableReason`，只查配置不建连；全局语音插件关着时不查）；隐私空间角色跳过。
- 「修改前每次问我」：助手聊天页「更多」菜单切换，存本机 `assistant_always_ask_v1`；开着时可撤销档也要确认，需审核档不走审核模型直接问用户；助手没有工具能改它。
- 测试：`test/features/assistant/assistant_checkup_test.dart`、`assistant_review_test.dart` 的 always-ask 与超长参数用例。

## 全权限（ADR0093，2026-10-19）

改名 AIcove酱，工作范围扩到几乎整个软件。新范围都实现 `application/assistant_tool_group.dart` 的 `AssistantToolGroup`（工具＋风险＋确认文案），由 `assistantToolGroupsProvider` 装进助手会话、审批闸门和确认卡片。

| 工具组 | 文件 | 工具 | 风险 |
|---|---|---|---|
| 设置 | `assistant_settings.dart` 白名单 | 原 13 项＋压缩／记忆模型、材质模糊与底色、内置壁纸、图片预览、句末标点、Windows 窗口行为、主动关怀各项 | 可撤销；跨渠道换模型重大 |
| 模型渠道 | `assistant_provider_tools.dart` | add（Key 卡片带草稿，粘贴后才建渠道）、update、list_remote_models、set_provider_models、test、delete | 改名启停选模型可撤销；停用需审核；改地址、删除重大 |
| 角色 | `assistant_role_tools.dart` | set_role_look（内置图／其他角色的图）、pick_role_image（选图卡片）、voice、thinking、flags、delete、clear_chat、import_role_card（按钮打开新建页并自动导入） | 可撤销（走角色撤销日志）；删除、清空重大 |
| 酒馆预设 | `assistant_preset_tools.dart` | import_preset（链接直接导、无链接给按钮）、add_preset_regex、add_world_book（她自己写或下载的 JSON）、set_preset_options、set_default_preset、delete_preset | 需审核；删除重大 |
| 插件选项 | `assistant_plugin_option_tools.dart` | 时间感知两项、联网搜索三项 | 可撤销 |
| 读正文 | `assistant_private_read_tools.dart` | read_role_chat、read_role_memory、revoke_read | 未授权角色重大，同意后本机记住；隐私空间永不可读 |

页面按钮（aicove_open_page）补了酒馆、语音、绘图、表情包、联网搜索、时间感知、MCP、主动关怀、同步与备份、局域网同步、账号。暂不覆盖的范围见 ADR0093「代价」。

测试：`test/features/assistant/assistant_{provider,role,preset,private_read,plugin_option}_tools_test.dart`、`assistant_settings_test.dart` 嵌套设置用例、`assistant_real_model_test.dart`「channel and tune a role」真实 DeepSeek 用例。

## 调研来源

- Anthropic 工程博客：Claude Code auto mode（两层防御、两段式分类器、剥离 Agent 文本与工具结果、3 连拒／20 次拒停）<https://www.anthropic.com/engineering/claude-code-auto-mode>
- Claude Code 文档：权限模式与 auto mode 的判定顺序（allow／ask／deny 规则先于分类器，ask 规则分类器不能代批）<https://code.claude.com/docs/en/permission-modes>、<https://code.claude.com/docs/en/auto-mode-config>
- OpenAI：Codex Auto-review（独立审核 Agent、拒绝附理由让主 Agent 换路、3 连拒熔断）<https://alignment.openai.com/auto-review>、<https://learn.chatgpt.com/docs/sandboxing/auto-review>
