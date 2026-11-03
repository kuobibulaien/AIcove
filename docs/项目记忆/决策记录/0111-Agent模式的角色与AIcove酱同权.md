---
status: accepted
date: 2026-10-23
---

# 0111：Agent 模式的角色与 AIcove酱 同权

## 背景

用户新建了一个工作模式为「工具模式」（`RoleAgentMode.tool`，界面上叫 Agent 模式）的角色，想让它像 Pi 一样干活，结果：

- 读不到角色库，`aicove_*` 工具一个都没有；
- `workspace_open`、`workspace_list` 都失败，它没有任何工作区授权；
- 它放出的 `roles` 快捷面板只显示「这个面板只在 AIcove酱的聊天里能用」。

根因是几处能力都按会话 id（`kAicoveAssistantId`）判断，而不是按工作模式：管理插件只装给 AIcove酱 的会话（ADR0073）、工具策略只给她（ADR0107）、默认工作区只内置授权给她、shell 里的渠道 Key 只给她（ADR0109 补充二）、快捷面板和撤销条、审批、卡片只在她的聊天页渲染（ADR0094）。

用户的定位：做 Agent 是做通用能力，AIcove酱 只是多了一层看板娘身份；短期目标是能替代 Pi。用户已决定：自己建的 Agent 直接给全权限、不加审核；聊天模式的角色保持现状。

## 决定

1. **能力跟工作模式走**：凡是 `conv.effectiveAgentMode == RoleAgentMode.tool` 的会话（AIcove酱 恒为工具模式），都安装 `aicove_assistant` 插件，拿到与 AIcove酱 相同的读写工具、设置工具、卡片、体检和 codemode 分组。插件 id 不改（避免迁移已存数据），显示名改为「AIcove 管理」，块状态按各自会话 id 读取。
2. **工具策略相同**：Agent 会话用同一份 `_assistantToolPolicy`，按 ADR0107 默认直接执行；「修改前每次问我」仍是用户主动打开的全局开关，聊天页「更多」菜单里所有 Agent 会话都显示。
3. **工作区**：工具模式角色可用本机全部工作区（不再只看角色名下授权）；新建的工作区仍记到角色名下。所有 Agent 的 `bash` 都带渠道 Key 环境变量（规则同 ADR0109 补充二）。
4. **界面**：快捷面板（`MoeUiBlockScope.actions`）、撤销条、卡片与审批面板（`AssistantActivityPanel`）在所有 Agent 会话里显示。非 Agent 会话里的面板提示改为「这个面板只在 Agent 模式的聊天里能用」；面板里「交给 AIcove酱」按钮改为「写进输入框」。
5. **提示词去身份**：插件提示词从「你是 AIcove酱，住在 AIcove 里的小管家」改为「你是 AIcove 里的 Agent」，性格要求改为「保持角色卡里的性格」。
6. **仍只属于 AIcove酱**：文档样式默认、工作模式锁定、新手引导剧本（含缺模型提示）、出厂角色卡、体检对她的豁免、角色工具里「你自己的聊天」提示。
7. **聊天模式不变**：仍只拿 `delegate_task` 派活（ADR0097），没有管理工具、工作区和快捷面板。

本决定取代 ADR0073「能力由只在助手会话里安装的内置插件挂载」、ADR0094 决定 2「只在助手会话渲染」，以及 ADR0109 补充二「渠道 Key 只给 AIcove酱 的 bash」。

## 代价

- 任何 Agent 都能删角色、改设置、跑 shell（带全部渠道 Key）、读其他可见角色的聊天和记忆；用户建 Agent 即等于授权，不再有逐角色的能力隔离。
- 卡片、审批、撤销条的状态仍是全局一份（不按会话分），两个 Agent 同时在跑时，一方的卡片或审批可能出现在另一方的聊天页。
- 已有的工具模式角色升级后立刻获得全部能力，不提示。

## 验证

- 复现测试先失败后通过：`tool_mode_agent_parity_test` 断言工具模式角色有 `aicove_list_roles`、`workspace_open`、工具策略、去身份的提示词和面板目录，能打开默认工作区和一个从未授权过的工作区并列目录；聊天模式角色仍没有这些。`chat_message_list_agent_panels_test` 断言聊天页给 Agent 会话开快捷面板时能列出角色，不开时显示新提示。
- 扩展包安装（`aicove_package_install`）的工作区授权也改为本机全部工作区，原先仍按 AIcove酱 的角色授权计算。
- 快捷面板开关由聊天页按会话工作模式传给 `ChatMessageList`（`quickPanels`），列表本身不去查会话：在列表里监听会话会拉起会话列表，曾让语音气泡手势测试卡死。
- 在只含 HEAD 与本次改动的临时工作树里：analyze 无 error；请求组装 golden `tool_mode_web_search` 重新生成（多出管理工具、去身份提示词、默认工作区可见、bash 渠道 Key 说明）；chat/services、assistant、ui_blocks、ui/chat、workspace 相关测试除 3 个真实模型测试外全部通过（`workspace_image_real_model_test` 2 项为 0110 记录的既有问题，`codemode_real_model_test` 对照项为真实模型波动，主目录同批运行时通过）。
- 应用内实际用新建 Agent 跑通未验。
