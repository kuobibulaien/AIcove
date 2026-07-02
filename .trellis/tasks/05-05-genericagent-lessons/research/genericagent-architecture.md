# Research: GenericAgent architecture

- Query: Research https://github.com/lsdefine/GenericAgent/tree/main for project goal, architecture, core abstractions, execution/runtime flow, prompt/context handling, tools/memory/planning support, examples, configuration surfaces, limitations, and light Aicove comparison.
- Scope: mixed
- Date: 2026-05-05

## Findings

### Repository Goal

GenericAgent is a minimal local autonomous-agent framework whose central bet is "self-evolution": start with a small seed runtime, give the model strong local execution tools, and let repeated task execution crystallize reusable SOPs/skills into the `memory/` layer. The README describes the system as a roughly 3K-line core with a roughly 100-line loop, using a small tool set to control browser, terminal, filesystem, keyboard/mouse, screen vision, and Android devices through ADB (README.md:297-310, README.md:402-438).

The public examples are deliberately system-control oriented: food ordering through an app/browser, quantitative stock screening, autonomous web exploration, Alipay expense tracing, Telegram/desktop/chat frontends, and optional scheduled/background operation (README.md:323-393; GETTING_STARTED.md:192-246).

### Files Found

External GenericAgent files and directories:

- `README.md`: project overview, self-evolution claim, quick start, feature list, memory/tool architecture, demos, and comparison table.
- `GETTING_STARTED.md`: beginner setup, model config examples, capability unlocking by asking the agent to install/configure dependencies.
- `agent_loop.py`: minimal turn loop and tool-dispatch engine.
- `agentmain.py`: app shell, model/session loading, task queue, CLI/task/reflect runtime modes, stream output handling.
- `ga.py`: concrete tool implementations, handler state, working-memory injection, file/browser/code tools, long-term memory trigger.
- `llmcore.py`: model provider sessions, streaming parsers, native/text tool protocols, history trimming, prompt/tool serialization, mixin failover.
- `assets/tools_schema.json`: mounted tool schema for `code_run`, file tools, web tools, working checkpoint, user interrupt, long-term memory update.
- `assets/sys_prompt.txt`: short behavioral root prompt focused on physical execution and tool probing.
- `mykey_template.py`: configuration template; variable names select session class/protocol and runtime session flags can be set by slash command.
- `pyproject.toml`: minimal dependency surface and optional UI/frontend extras.
- `TMWebDriver.py`: local browser bridge over websocket/HTTP long polling for real-browser JS execution.
- `frontends/`: Streamlit, Qt, Telegram, QQ, Feishu, WeCom, DingTalk, WeChat, desktop pet, and shared chat command utilities.
- `memory/`: L1/L2/L3/L4 memory/SOP/skill repository, ADB/OCR/browser/process helpers, scheduler/autonomous/subagent/verify SOPs.
- `memory/skill_search/`: built-in semantic skill search wrapper for a remote 105K skill-card index.
- `memory/L4_raw_sessions/compress_session.py`: session-log compression, history extraction, monthly archive, and raw log cleanup.
- `reflect/`: reflect scripts for autonomous idle work and scheduled JSON tasks.
- `plugins/langfuse_tracing.py`: opt-in tracing plugin installed by monkey-patching loop/log/tool hooks.

Local Aicove files inspected for light comparison:

- `README.md`: Aicove's Agent Context Runtime direction and current Interface/contract rules.
- `.trellis/spec/agent-context/index.md`: canonical project rule: Agent = model + context strategy + tool strategy + output contract + postprocessors.
- `.trellis/spec/project/overview.md`: project boundary and DB raw-message source-of-truth principle.
- `.trellis/spec/project/architecture-boundaries.md`: contract/adapter/service boundary rules.
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md`: long-term Agent Runtime, scheduler, context recipe, output pipeline design.
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md`: DB raw-message canonical request context rules.
- `apps/aicove_flutter/assets/prompt_defaults.json`: prompt/default schema for proactive analyzer, system-reminder semantics, memory L1/L2/L3/L4 templates.
- `apps/aicove_flutter/lib/src/core/services/system_reminder_service.dart`: Aicove system-reminder wrapping, placement, and semantics injection.
- `apps/aicove_flutter/lib/src/features/auto_reply/data/analyzer_scheduler.dart`: proactive scheduler state machine, trigger creation, background fallback.
- `apps/aicove_flutter/lib/src/features/auto_reply/data/context_analyzer.dart`: background analyzer agent, canonical-context loading, tool-preview-before-create flow.
- `apps/aicove_flutter/lib/src/features/agent_context/domain/agent_runtime_contracts.dart`: AgentDefinition, ContextProfile, permissions, output contract, scheduler/runtime/channel contracts.
- `apps/aicove_flutter/lib/src/features/agent_context/data/agent_context_assembler.dart`: context entry filtering, recipe rendering, transform pipeline, token-budget integration.
- `apps/aicove_flutter/lib/src/features/chat/application/standard_chat_agent.dart`: current standard ChatAgent wrapper around existing ChatSendUseCase.

### Architecture

GenericAgent has four practical layers:

1. Core loop and handler: `agent_loop.py` provides a generic `BaseHandler` and `agent_runner_loop`; `ga.py` implements the actual tools by naming convention (`do_<tool_name>`).
2. Runtime shell: `agentmain.py` loads tool schema, initializes memory files, loads LLM sessions, accepts queued tasks, and exposes CLI/task/reflect modes.
3. Model adapter layer: `llmcore.py` normalizes Claude/OpenAI-compatible APIs, native tool-call mode, text-protocol fallback, streaming parsers, history trimming, and multi-backend failover.
4. Evolving memory/frontends: `memory/` holds SOPs, helper scripts, and layered long-term memory; `frontends/` and `reflect/` expose the same agent through GUI, bots, task files, idle triggers, and cron-like schedules.

The system is deliberately file-first. Instead of a database-backed agent registry, durable capabilities are Markdown SOPs and Python helper scripts under `memory/`, while runtime scratch state and LLM logs live under `temp/`. This fits its "agent reads its own code and memory" philosophy but is a different operational posture from Aicove's planned DB/canonical context runtime.

### Core Abstractions

- `StepOutcome` wraps tool result data plus `next_prompt` and `should_exit`, letting each tool decide whether the loop continues, exits, or asks the model to react to the tool result (agent_loop.py:4-8, agent_loop.py:84-99).
- `BaseHandler.dispatch()` maps tool names to `do_<tool>` methods, runs before/after hooks, and handles unknown/bad JSON tools (agent_loop.py:14-29).
- `GenericAgentHandler` is the concrete tool/runtime state holder: parent app ref, `working` memory, cwd, current turn, history summaries, stop signal, and done hooks (ga.py:261-269).
- `GeneraticAgent` is the app orchestrator: lock, task queue, running state, model clients, slash commands, handler replacement, and streaming output queue (agentmain.py:42-52, agentmain.py:106-174).
- `BaseSession`, `ClaudeSession`, `LLMSession`, `NativeClaudeSession`, `NativeOAISession`, `ToolClient`, `NativeToolClient`, and `MixinSession` form the model adapter stack (llmcore.py:509-537, llmcore.py:587-607, llmcore.py:628-702, llmcore.py:730-829, llmcore.py:882-995).
- Memory layers are explicitly documented as L1 insight index, L2 global facts, L3 SOP/script records, and L4 session archive (memory/memory_management_sop.md:16-24).

### Execution / Runtime Flow

The core loop is simple and repeated:

1. Build initial messages from system prompt and user input (agent_loop.py:42-46).
2. Call `client.chat(messages, tools=tools_schema)` (agent_loop.py:53-56).
3. Parse tool calls; if none, synthesize a `no_tool` internal call (agent_loop.py:63-65).
4. Dispatch each tool through the handler, collecting tool results and next prompts (agent_loop.py:67-93).
5. Run turn-end callback, then replace the loop message list with a single new user message containing `next_prompt` and tool results; full history is kept by the backend session, not by repeatedly passing the whole `messages` list here (agent_loop.py:96-98; agentmain.py:147-149).
6. Stop on explicit exit, task-done outcome, max turns, or handler done-hook exhaustion (agent_loop.py:93-99).

`agentmain.py` adds three runtime modes:

- Normal interactive REPL / frontend queue mode (`put_task`, `run`) (agentmain.py:106-174).
- File-IO subagent mode via `--task`, where `temp/{task}/input.txt`, `output*.txt`, `reply.txt`, `_stop`, `_keyinfo`, and `_intervene` provide a low-friction subagent protocol (agentmain.py:176-223; memory/subagent.md:3-15).
- Reflect mode via `--reflect`, where a Python module's `check()` is polled and can trigger tasks, used by scheduler/autonomous scripts (agentmain.py:224-255; reflect/scheduler.py:62-130; reflect/autonomous.py:1-6).

The launcher can start Streamlit UI, selected bot frontends, and scheduler reflect process, and it also injects an idle autonomous task after 30 minutes of inactivity (launch.pyw:81-144, launch.pyw:65-77).

### Prompt / Context Handling

GenericAgent optimizes for contextual information density rather than large persistent prompts:

- Root system prompt is intentionally short: physical execution permission, probe-first behavior, failure escalation, and mandatory summary (assets/sys_prompt.txt:1-7).
- `agentmain.get_system_prompt()` loads the root prompt, adds today's date, and appends `get_global_memory()` (agentmain.py:36-40).
- `get_global_memory()` injects cwd, memory path, fixed insight structure, and `memory/global_mem_insight.txt`; it does not load all SOPs by default (ga.py:569-580).
- After each tool, `_get_anchor_prompt()` injects a compact working-memory block with folded earlier context, last 30 history summaries, current turn, `key_info`, and related SOP pointer (ga.py:525-537).
- `turn_end_callback()` forces a `<summary>`-style compact record into `history_info`; every 10 turns it re-injects global memory, and every 7/65 turns it adds anti-retry warnings (ga.py:539-567).
- `llmcore.trim_messages_history()` compresses tags and pops older history when serialized cost exceeds the configured context window (llmcore.py:90-103).
- Text-protocol tools are serialized once, then replaced with "tools still active" on subsequent calls to reduce repeated tool-schema tokens (llmcore.py:749-775).

Light Aicove comparison: this maps closely to Aicove's context-layer thinking, but Aicove already has a stronger typed target: `AgentContextLayer`, `ContextProfile`, `AgentOutputContract`, `AgentContextRecipe`, and canonical DB-derived messages (agent_runtime_contracts.dart; Agent上下文管理总架构.md). GenericAgent's strongest reusable idea is not its exact prompt format; it is the discipline of injecting only an index + compact working memory + referenced SOPs, rather than dumping every memory detail into every request.

### Tools, Memory, Planning, and Scheduling Support

Mounted tools:

- `code_run`: arbitrary Python or PowerShell execution with timeout and streamed stdout (assets/tools_schema.json:1-11; ga.py:12-90; ga.py:280-303).
- `file_read`, `file_patch`, `file_write`: line-aware reads, unique-block patching, and whole-file write/append/prepend with file-reference expansion (assets/tools_schema.json:12-36; ga.py:188-200; ga.py:210-236; ga.py:354-418).
- `web_scan`, `web_execute_js`: real-browser simplified DOM scan and JS execution through `TMWebDriver` (assets/tools_schema.json:37-53; ga.py:113-140; ga.py:163-172; TMWebDriver.py:37-49, TMWebDriver.py:184-243).
- `update_working_checkpoint`: short-term notepad auto-injected across turns (assets/tools_schema.json:54-60; ga.py:430-440).
- `ask_user`: interrupt for human decisions (assets/tools_schema.json:61-67; ga.py:93-96; ga.py:305-310).
- `start_long_term_update`: model-initiated memory distillation flow after a task, guided by memory SOP (assets/tools_schema.json:68-72; ga.py:494-509).

Memory support:

- L1 is a small navigational insight index; L2 stores stable environment facts; L3 stores compact SOPs/scripts; L4 archives raw/compressed sessions (memory/memory_management_sop.md:16-59).
- Memory write policy is action-verified only: do not store model guesses, unverified plans, volatile state, or generic common knowledge (memory/memory_management_sop.md:1-15, memory/memory_management_sop.md:73-92).
- L4 archival compresses `temp/model_responses` logs, extracts merged history, appends `all_histories.txt`, zips monthly archives, and deletes processed raw files when not dry-run (memory/L4_raw_sessions/compress_session.py:154-236).

Planning/subagent support:

- Plan mode explicitly says to use subagents for exploration, keep main context clean, write `plan.md`, mark steps, and require independent verification before declaring done (memory/plan_sop.md:1-21, memory/plan_sop.md:73-113, memory/plan_sop.md:138-160, memory/plan_sop.md:175-245).
- Subagent SOP defines a file-IO protocol, intervention files, map-reduce mode, and constraints around shared browser/keyboard resources (memory/subagent.md:3-15, memory/subagent.md:26-37).
- Verify SOP is adversarial: "run it", require tool evidence, check edge cases, and produce `VERDICT` (memory/verify_sop.md:1-16, memory/verify_sop.md:29-65).

Scheduling/autonomy:

- Scheduled tasks are JSON files under `sche_tasks/` with `schedule`, `repeat`, `enabled`, `prompt`, and optional delay window; scheduler emits a report path into the prompt (memory/scheduled_task_sop.md:1-17; reflect/scheduler.py:76-130).
- Idle autonomous mode simply returns an `[AUTO]` prompt every 30 minutes; the real guardrails are in `autonomous_operation_sop.md` (reflect/autonomous.py:1-6; memory/autonomous_operation_sop.md:18-43).
- Skill search exposes a remote 105K skill-card semantic index with `search(query, env=None, category=None, top_k=10)` and env overrides for API URL/key (memory/skill_search/SKILL.md:1-24, memory/skill_search/SKILL.md:59-64).

### Configuration Surfaces

- `mykey.py` / `mykey.json`: required model/backend configuration; variable names choose `NativeClaudeSession`, `NativeOAISession`, text-protocol sessions, or `MixinSession` failover (llmcore.py:6-27; mykey_template.py:12-40).
- Session config fields include auth, base URL, model, context window, retries, timeouts, reasoning effort, thinking settings, temperature, max tokens, stream, API mode, fake Claude Code prompt, and user-agent (mykey_template.py:69-113).
- Runtime slash command `/session.<field>=<value>` mutates backend attributes such as reasoning effort, temperature, max tokens, or thinking budget (agentmain.py:111-125; mykey_template.py:58-67).
- `assets/tools_schema*.json` is selected by model family/language and OS shell replacement (agentmain.py:14-18, agentmain.py:80-90).
- `GA_LANG` selects Chinese/English prompt/memory templates from locale/env (agentmain.py:1-2, agentmain.py:20).
- `pyproject.toml` keeps minimal core dependencies and optional UI/all-frontends extras instead of installing every possible bot/UI package up front (pyproject.toml:1-16, pyproject.toml:18-33).
- Launcher flags start optional bot frontends and scheduler (`--tg`, `--qq`, `--feishu`, `--wecom`, `--dingtalk`, `--sched`, `--llm_no`) (launch.pyw:81-131).
- `langfuse_config` in mykey activates tracing plugin by import side effect (plugins/langfuse_tracing.py:1-18).

### Examples and Runtime Surfaces

- Interactive CLI: `python agentmain.py` (GETTING_STARTED.md:130-147).
- GUI: `python launch.pyw` starts Streamlit inside pywebview (README.md:339-368; launch.pyw:19-24, launch.pyw:140-144).
- Bot frontends: Telegram, QQ, Feishu, WeCom, DingTalk, WeChat, plus desktop/pet/frontends listed under `frontends/` (README.md:371-393; GitHub `frontends/` listing lines 222-304).
- Subagent/file mode: `python agentmain.py --task {name} [--input ...] [--bg]` (memory/subagent.md:3-15; agentmain.py:176-223).
- Reflect/autonomous/scheduled mode: `python agentmain.py --reflect reflect/scheduler.py` or launcher `--sched` (agentmain.py:224-255; launch.pyw:127-131).

### Limitations and Risks

- It is intentionally high-trust and high-power. `code_run`, `file_write`, `file_patch`, real-browser JS, process control, and package installation are core capabilities, not sandboxed product-user tools (ga.py:12-90; ga.py:188-200; ga.py:368-399; TMWebDriver.py:184-243).
- The "self-evolving" guarantee depends on the model following SOPs and writing concise, verified memory. There is no typed schema, permissioned database transaction, or policy engine around most memory writes.
- File-based memory and temp logs are easy for a local power-user agent to inspect, but they are not directly appropriate for Aicove's multi-contact, healthcare-adjacent, mobile/cloud setting.
- Some mechanisms deliberately monkey-patch runtime functions for tracing (`plugins/langfuse_tracing.py`), which is pragmatic but brittle for a production app.
- L4 archival can delete processed raw logs when run with `dry_run=False` (memory/L4_raw_sessions/compress_session.py:220-230). This is fine for its local scratch model but should be treated differently from Aicove's durable audit/canonical context requirements.
- Browser/keyboard/mobile control examples are strong demonstrations of agency, but they are not aligned with Aicove's user-facing safety boundary unless wrapped behind explicit tool policy, consent, and trace contracts.

### Light Aicove Comparison

Worth borrowing now:

- Context density pattern: keep a tiny index always in context, store detailed SOPs separately, and pull them only when needed. This maps to Aicove's `ContextProfile` + `AgentContextEntry` + recipe/node model.
- Per-turn compact summaries and working checkpoint: Aicove can adapt this as traceable `AgentRun` state rather than free-form hidden memory, especially for Analyzer/Proactive flows.
- Action-verified memory rule: Aicove memory summarization already says "do not invent"; GenericAgent's "No Execution, No Memory" is a useful stronger formulation for memory writes and tool-derived facts.
- Tool-preview-before-side-effect discipline: Aicove's `ContextAnalyzer` already requires `preview_proactive_reply` before `create_proactive_trigger_from_preview`, which is directionally similar to GenericAgent's plan/verify and human-interrupt style.
- Scheduler report-path injection: Aicove's proactive/background tasks could benefit from standard output/report contracts per run, but stored through Aicove trace/state rather than arbitrary files.

Worth watching:

- L4 session archive: Aicove has L3/L4 memory prompt concepts in `prompt_defaults.json`; GenericAgent shows a concrete archive/compress/extract loop, but Aicove should adapt it to DB raw-message truth and explicit memory scopes.
- Skill search / external skill library: useful inspiration for future Node Studio or Agent Builder discovery, but unsafe to directly import executable SOPs/scripts.
- Native-tool vs text-protocol fallback: Aicove provider adapters may need similar provider-specific tool rendering, but the final contract should live in `ProviderAdapter` / Agent Runtime, not in prompt text.

Not suitable to copy directly:

- Arbitrary local `code_run` and unrestricted filesystem/browser control in a patient-facing app.
- Python-variable-name-driven provider configuration (`native_claude_config`, `mixin_config`) as product config UX.
- File-backed global memory shared by all tasks; Aicove needs contact/conversation-scoped memory and canonical DB provenance.
- Monkey-patch tracing and loose plugin loading for production observability.
- UI/browser automation as a default "tool" for Aicove; Aicove tools should remain explicit contracts with consent, availability, output schema, and delivery channels.

## Related Specs

- `.trellis/spec/README.md`
- `.trellis/spec/agent-context/index.md`
- `.trellis/spec/project/overview.md`
- `.trellis/spec/project/architecture-boundaries.md`
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md`
- `apps/aicove_flutter/docs/02_前后端分离与架构规范/聊天请求上下文真相源与组装规范.md`

## External References

- GitHub repository: https://github.com/lsdefine/GenericAgent/tree/main
- README: https://github.com/lsdefine/GenericAgent/blob/main/README.md
- Getting started: https://github.com/lsdefine/GenericAgent/blob/main/GETTING_STARTED.md
- Core loop: https://github.com/lsdefine/GenericAgent/blob/main/agent_loop.py
- Runtime shell: https://github.com/lsdefine/GenericAgent/blob/main/agentmain.py
- Tool handler: https://github.com/lsdefine/GenericAgent/blob/main/ga.py
- LLM adapters: https://github.com/lsdefine/GenericAgent/blob/main/llmcore.py
- Tool schema: https://github.com/lsdefine/GenericAgent/blob/main/assets/tools_schema.json
- Memory SOP: https://github.com/lsdefine/GenericAgent/blob/main/memory/memory_management_sop.md
- Plan SOP: https://github.com/lsdefine/GenericAgent/blob/main/memory/plan_sop.md
- Subagent SOP: https://github.com/lsdefine/GenericAgent/blob/main/memory/subagent.md
- Verify SOP: https://github.com/lsdefine/GenericAgent/blob/main/memory/verify_sop.md
- Scheduler: https://github.com/lsdefine/GenericAgent/blob/main/reflect/scheduler.py
- pyproject: https://github.com/lsdefine/GenericAgent/blob/main/pyproject.toml

## Caveats / Not Found

- GitHub REST API returned an anonymous rate-limit error, so repository traversal used GitHub HTML pages and raw file reads instead of recursive API listing.
- I did not clone the repository because the active researcher constraints only allow writes under this task's `research/` directory. No temp clone was created.
- I did not run GenericAgent locally, install dependencies, or verify the README's self-bootstrap/code-size claims by execution.
- I did not inspect every frontend/bot implementation in full; focus stayed on core runtime, memory, planning, scheduling, config, and representative frontend/common command surfaces.
- Line references are from the `main` branch as read on 2026-05-05 and may drift as the public repository changes.
