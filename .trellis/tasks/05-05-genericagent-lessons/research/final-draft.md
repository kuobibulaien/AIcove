我仔细读了 GenericAgent 的 README、核心源码、工具 schema、记忆 SOP、计划/调度机制，也对照看了我们 Aicove 现有的 Agent Context Runtime、StandardChatAgent、BackgroundAgentService、ContextAnalyzer、AnalyzerScheduler 和 prompt_defaults。

研究记录已经落在：

- [genericagent-lessons.md](C:/ide/aicove/.trellis/tasks/05-05-genericagent-lessons/research/genericagent-lessons.md)
- [genericagent-architecture.md](C:/ide/aicove/.trellis/tasks/05-05-genericagent-lessons/research/genericagent-architecture.md)

核心判断：GenericAgent 不适合被我们“搬过来”，但非常值得借它的思想。它最厉害的不是工具多，而是：用很小的原子工具面，配合高密度分层记忆，把每次成功任务沉淀成以后可复用的 SOP/技能。换成 Aicove 的语言，就是“让 Agent Context 不只是装配 prompt，而是能从真实交互里沉淀可验证、可追踪、可复用的陪伴经验”。

最值得马上借鉴的 4 点：

1. **分层记忆要更像运行机制，而不只是提示词块**  
   GenericAgent 的 L1/L2/L3/L4 很清楚：L1 只做极简索引，L2 放稳定事实，L3 放 SOP/技能，L4 放会话归档。我们现在 `prompt_defaults.json` 已经有 L1/L2/L3/L4 的影子，下一步可以把它真正落到 `AgentContextEntry` 的 metadata、优先级和 token budget 上：L1 常驻但极短，L2 按联系人装配，L3 触发式召回，L4 只给 MemoryAgent/AnalyzerAgent 做离线蒸馏，绝不直接塞进聊天。

2. **长期记忆必须“证据优先”**  
   GenericAgent 的记忆 SOP 有一句精神很硬：“没有行动验证，不写记忆”。这对 Aicove 特别重要。用户画像、主动关怀偏好、有效安抚方式，不应该因为模型猜到了就写进长期记忆；应该来自真实聊天、用户确认、主动消息后的反馈、无打扰/正反馈等证据。这样能避免 AI 把一次性的情绪误判固化成长期人格理解。

3. **给 Agent 增加 run-local scratchpad**  
   GenericAgent 的 `update_working_checkpoint` 很朴素，但有用：长任务中间把当前关键状态压成一个短 scratchpad。Aicove 的主动关怀/后台分析也可以有类似 `AgentRunScratchpad`，只存本轮运行事实，比如候选触发时间、预览回复为何被拒、当前安全顾虑、用户刚表达的边界。它属于 `runtimeFacts`，不是长期记忆。

4. **工具保持原子，复杂行为放到 recipe/SOP/output pipeline**  
   GenericAgent 的基础工具很少，复杂能力靠组合和沉淀。我们也应该避免把“主动关怀完整流程”“记忆总结完整流程”塞进一个巨型工具。更好的方向是：插件工具保持原子，Agent Recipe / Node Studio / OutputPipeline 负责编排。工具 metadata 里增加 safety tier、allowed agent kinds、delivery mapping，会和我们现有 `ToolPolicy + OutputContract + DeliveryChannel` 很合拍。

中期可以考虑的方向：

- 做一个 MemoryAgent 的“事后蒸馏器”：每次聊天或主动关怀结束后，基于 trace 和用户反应产出 memory candidates，带 evidence、scope、confidence、expiry，而不是直接写记忆。
- 在 Agent Context Studio 里增加 “SOP / care playbook” 节点，和角色卡、世界书、记忆分开管理。
- 给 BackgroundAgent/ProactiveAgent 增加标准化运行报告：本轮用了哪些上下文、为什么选择沉默/触发、preview 为什么通过或失败，方便审计和调试。
- 后续做 L4 会话归档压缩，但要基于我们的 DB raw message 真相源和隐私边界，而不是 GenericAgent 那种本地文件日志模型。

不建议照搬的部分：

- 任意 `code_run`、文件系统写入、真实浏览器注入、ADB 控制，这些是个人电脑 Agent 的强执行力，不适合患者陪伴 App。
- 自动安装依赖、自动写脚本、自动扩展工具，在我们的场景里风险太高。
- 文件型全局记忆不适合 Aicove；我们需要联系人/会话作用域、用户同意、可删除、可追溯。
- GenericAgent 的 3K 行极简单体风格很有启发，但我们的 Flutter/FastAPI typed contract、trace、provider adapter、delivery channel 不能退回去。

对我们现有架构的直接启发是：Aicove 的大方向已经比 GenericAgent 更适合产品化。我们已经有 `AgentDefinition`、`ContextProfile`、`AgentRunRequest`、`OutputContract`、`AgentOutputEvent`、`StandardChatAgent` 和后台主动关怀链路。下一步不是推翻，而是补上 GenericAgent 最强的那块：**高密度、可验证、可复用的上下文沉淀机制**。

我建议优先排一个小任务：设计 `AgentRunScratchpad + MemoryEvidence + CarePlaybookNode` 三个概念，不急着写大功能，先把它们放进 Agent Context Runtime 的类型和 trace 设计里。这个会让主动关怀和长期陪伴的“越来越懂你”变得更稳，不会靠模型自由发挥硬撑。

本轮没有改生产代码，也没有运行 `flutter run --no-resident`，因为只是研究和文档沉淀。参考来源：GenericAgent 仓库 https://github.com/lsdefine/GenericAgent/tree/main ，README https://github.com/lsdefine/GenericAgent/blob/main/README.md ，核心 loop https://github.com/lsdefine/GenericAgent/blob/main/agent_loop.py ，工具 handler https://github.com/lsdefine/GenericAgent/blob/main/ga.py ，模型适配 https://github.com/lsdefine/GenericAgent/blob/main/llmcore.py ，论文摘要 https://arxiv.org/abs/2604.17091 。
