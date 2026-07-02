这个“四层分级记忆”的实现，核心不是搞了一个很复杂的向量库，而是一个非常朴素但很狠的策略：**常驻 prompt 里只放索引，不放详情；详情全部留在文件里，模型需要时再用 `file_read` 打开。**

GA 大概是这么做的：

1. `agentmain.py` 的 `get_system_prompt()` 只拼三块东西：根系统提示词、当天日期、`get_global_memory()`。
2. `ga.py` 的 `get_global_memory()` 只读取两个小文件：`assets/insight_fixed_structure*.txt` 和 `memory/global_mem_insight.txt`。
3. `global_mem_insight.txt` 就是 L1：一个极短导航索引。它里面只写“L2 在哪、L3 有哪些 SOP、L4 在哪、什么场景该读哪个文件”，不展开具体内容。
4. L2 / L3 / L4 都不默认注入 prompt。L2 是事实库文件，L3 是 SOP / skill / helper 脚本，L4 是历史会话归档。模型看到索引后，如果判断需要，才自己调用 `file_read` 读对应文件。

所以它省 token 的关键不是“记忆少”，而是“常驻记忆极少”。正常一个 `Hello` 请求，它不会把一堆工具说明、所有 SOP、历史归档、能力文档都塞进上下文，只塞一个小索引。

它还有几个配套省 token 设计：

1. 工具说明去重：`llmcore.py` 的 `ToolClient._prepare_tool_instruction()` 会记住 `last_tools`。如果工具 schema 没变，后续轮次不再重复完整工具 JSON，只提示“工具仍然有效”。
2. 历史压缩：`compress_history_tags()` 会压缩旧的 `<thinking>`、`<tool_use>`、`<tool_result>`，`trim_messages_history()` 超过 context window 后会裁掉旧历史。
3. 工作记忆短摘要：`update_working_checkpoint` 不是长期记忆，而是短期 checkpoint；每轮只注入一小段关键状态，避免把完整执行过程拖进 prompt。
4. 每轮 summary：`turn_end_callback()` 会逼模型给出 `<summary>`，历史里更多保存“这一轮发生了什么”的短摘要，而不是完整展开。

四层可以这样理解：

- **L1 Insight Index**：常驻 prompt，极短，负责导航。
- **L2 Global Facts**：稳定事实库，不常驻，需要才读。
- **L3 Skills / SOPs**：可复用流程和脚本，不常驻，需要才读。
- **L4 Session Archive**：历史会话归档，不常驻，主要用于长期回溯和蒸馏。

它打 Claude Code / OpenClaw 那个 token 对比，思路上就赢在这里：很多 agent 框架会把大量工具说明、环境说明、行为规范、能力文档、历史上下文一股脑塞进初始 prompt；GA 初始只给“短根 prompt + 工具 schema + 记忆索引”。真正的大知识都变成“可寻址文件”，不是“默认上下文”。

不过要注意：我在 GA 源码里看到的是 `Full prompt length` 打印字符长度，不是 token 数；你说的 `Hello: GA 2298 tokens / Claude Code 22821 / OpenClaw 43321` 这个具体数字我没有本地复现，应该是论文/评测里的 token 统计。机制上是对的：**索引常驻，详情按需读取**，这就是它 token 开销低的主因。

对 Aicove 的启发很直接：我们的记忆系统也不能把“画像、回忆、技能、历史总结”全都塞给 ChatAgent。更好的形态是：

- L1 常驻：极短用户/角色记忆索引。
- L2 按联系人选取：稳定事实和用户明确偏好。
- L3 按触发召回：某类安抚方式、关怀 SOP、care playbook。
- L4 只给 MemoryAgent / AnalyzerAgent 做离线蒸馏，不直接进聊天。

这样 AI 才会既“记得住”，又不会每次说一句话都背着一整箱历史上场。

源码对应位置主要是：

- `agentmain.py#get_system_prompt`
- `ga.py#get_global_memory`
- `assets/global_mem_insight_template.txt`
- `assets/insight_fixed_structure.txt`
- `memory/memory_management_sop.md`
- `llmcore.py#ToolClient._prepare_tool_instruction`
- `llmcore.py#compress_history_tags`
- `llmcore.py#trim_messages_history`

参考：GenericAgent 仓库 https://github.com/lsdefine/GenericAgent/tree/main ，核心 loop https://github.com/lsdefine/GenericAgent/blob/main/agent_loop.py ，工具与记忆入口 https://github.com/lsdefine/GenericAgent/blob/main/ga.py ，模型/提示词压缩逻辑 https://github.com/lsdefine/GenericAgent/blob/main/llmcore.py 。
