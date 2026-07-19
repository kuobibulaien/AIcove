# 智能回复建议(Smart Reply)

## Goal

在聊天页新增「智能回复建议」辅助功能:用户不知道怎么回复 AI 伴侣时,可手动开启该功能,由 AI 根据当前对话上下文生成 3 个候选回复供用户选用,降低回复压力(产品定位:心理陪伴场景,帮助抑郁症患者减轻表达负担)。

## Confirmed Facts(来自用户)

- 功能可由用户**手动开启/关闭**,开关入口位于聊天页「回到底部」小按钮旁边。
- 开启后出现一个**小气泡**,点击气泡展开 **3 个候选回复选项**。
- 业界参照:Smart Reply(Gmail / LinkedIn 同类功能)。

## Confirmed Facts(来自代码库)

- 项目为 Flutter + Riverpod + Drift;聊天 UI 相关:`apps/aicove_flutter/lib/src/ui/features/chat/widgets/`(消息列表/viewport/回到底部按钮)、composer 在 `apps/aicove_flutter/lib/src/features/chat/presentation/widgets/composer.dart`。
- 项目宪法 #4:新增 Agent 必须先定义 `AgentDefinition` / `ContextProfile` / `ContextAssembler` / `OutputNormalizer`;聊天上下文必须取自 DB raw message 真相源,禁止拿 UI 投影喂模型。
- UI 强约束:颜色走 `tokens.dart`,组件优先 Moe 系列;可复用组件:`FrostedGlassContainer`(悬浮气泡)、`MoePopupMenu`(Overlay 点击展开先例)、`MoeSwitch`、`MoeToast`;宽窄屏断点 900px 需双端适配。
- 详细代码调研进行中:research/codebase-survey.md(grok-hands 产出)。

## Requirements(草稿,待收敛)

- R1 开关:聊天页内快捷开关,位置在「回到底部」按钮旁;状态需持久化。
- R2 气泡:开启后在聊天区显示小气泡入口;点击展开 3 个候选回复。
- R3 生成:基于当前会话上下文(DB 真相源)生成 3 个候选,候选之间需方向/语气有区分度(多样性是该功能核心)。
- R4 选用:点击某个候选后,将文本**填入输入框(composer),用户可编辑后再手动发送**(用户已确认);不直接发送,避免误触与不可反悔。
- R5 宽窄屏均可用。

## Acceptance Criteria

- [ ] TBD(待 Q1/Q2 收敛后补全)

## 自主决策(用户扫读否决)

- **生成时机 = 按需生成 + 按消息缓存**:点气泡时才调用模型(而非每条 AI 消息后自动预生成);同一条 AI 消息的候选生成一次后缓存,重复点气泡不重复扣 token。理由:预生成会让每条 AI 消息都产生成本,而该功能是「偶尔卡壳才用」,按需更省;缓存兜住「点开又关掉再点开」。代价:首次点气泡有 1~3s 等待(用加载态兜住)。
- **单次调用出 3 个候选**:一次模型调用返回 3 条(结构化输出),不循环调 3 次。理由:省时省钱,且便于在同一上下文里保证 3 条互相有区分度。
- **多样性策略**:prompt 显式要求 3 个候选覆盖不同方向/语气(如 认同倾诉 / 追问细节 / 轻松带过),避免雷同(Smart Reply 的核心教训)。
- **模型选择**:复用当前会话已配置的 provider/模型走非流式一次性调用;若有更快的小模型配置则优先(待调研确认链路后定)。
- **像用户口吻**:把用户最近几条消息作为 few-shot 注入,让候选贴近用户平时说话风格,而非 AI 腔。
- 其余 UI/结构细节待 design.md 补全。

## Out of Scope(初判)

- 不做自动检测「用户卡壳」被动触发(输入停留检测),只做手动开关。
- 云端 cloud_backend 不参与(项目当前默认只做本地客户端)。

## Open Questions

- 暂无阻塞性问题(Q1 点击行为已确认填入输入框;Q2 生成时机已转为自主决策)。
