# GenericAgent 对 Aicove 的启发

## Sources Read

* External repo: https://github.com/lsdefine/GenericAgent/tree/main
* External paper abstract: https://arxiv.org/abs/2604.17091
* Local clone inspected under a temporary directory:
  * `README.md`
  * `GETTING_STARTED.md`
  * `pyproject.toml`
  * `agent_loop.py`
  * `agentmain.py`
  * `ga.py`
  * `llmcore.py`
  * `assets/tools_schema.json`
  * `assets/sys_prompt_en.txt`
  * `assets/global_mem_insight_template.txt`
  * `assets/insight_fixed_structure.txt`
  * `memory/memory_management_sop.md`
  * `memory/plan_sop.md`
  * `memory/scheduled_task_sop.md`
  * `memory/autonomous_operation_sop.md`
  * `reflect/scheduler.py`
  * `reflect/autonomous.py`
* Aicove files inspected:
  * `README.md`
  * `apps/aicove_flutter/docs/02_前后端分离与架构规范/Agent上下文管理总架构.md`
  * `apps/aicove_flutter/lib/src/features/agent_context/domain/agent_runtime_contracts.dart`
  * `apps/aicove_flutter/lib/src/features/agent_context/data/agent_context_assembler.dart`
  * `apps/aicove_flutter/lib/src/features/agent_context/data/agent_context_transform_pipeline.dart`
  * `apps/aicove_flutter/lib/src/features/agent_context/data/agent_context_token_budget.dart`
  * `apps/aicove_flutter/lib/src/features/agent_context/data/provider_message_renderer.dart`
  * `apps/aicove_flutter/lib/src/features/chat/application/standard_chat_agent.dart`
  * `apps/aicove_flutter/lib/src/features/background_agent/background_agent_service.dart`
  * `apps/aicove_flutter/lib/src/features/auto_reply/data/context_analyzer.dart`
  * `apps/aicove_flutter/lib/src/features/auto_reply/data/analyzer_scheduler.dart`
  * `apps/aicove_flutter/assets/prompt_defaults.json`

## What GenericAgent Actually Is

GenericAgent is a personal-computer autonomous agent seed rather than a product-facing app framework. Its pitch is a very small execution kernel plus a very small always-available tool surface. The project then grows capability through memory and SOPs instead of shipping many prebuilt workflows.

The central architectural thesis is "context information density maximization": long-horizon agents are limited by how much decision-relevant information they keep in a finite context, not merely by nominal context window length.

The practical implementation has four important pieces:

1. Minimal loop and tool dispatch.
   * `agent_loop.py` is a small loop around LLM response -> tool calls -> `handler.dispatch()` -> `StepOutcome`.
   * Each tool returns data, optional `next_prompt`, and optional exit.
   * `no_tool` is treated as a normal pseudo-tool path.
   * `turn_end_callback` enforces compact per-turn summaries.

2. Minimal atomic tools.
   * Core tools are file read/write/patch, code execution, web scan, JS execution, ask user, working checkpoint, long-term memory update.
   * Bigger capabilities are expected to be created from these primitives and crystallized into SOP/scripts.

3. Layered memory.
   * L1: tiny insight index, used only for routing.
   * L2: stable global facts.
   * L3: task SOPs and reusable scripts.
   * L4: raw session archive.
   * Memory update SOP has a strong rule: only action-verified knowledge can be remembered.

4. Context compression and continuity.
   * Tool descriptions are not repeated in full if unchanged.
   * Old tool/thinking/history blocks are compressed.
   * `update_working_checkpoint` provides a short in-run scratchpad.
   * Scheduler/reflect mode writes reports and archives sessions.

## Where Aicove Is Already Stronger

Aicove already has a more product-grade and domain-specific Agent architecture:

* `AgentDefinition`, `ContextProfile`, `ToolPolicy`-like allowed tools, `OutputContract`, `AgentRunRequest`, `AgentRuntime`, `AgentScheduler`, `DeliveryChannel`, and `AgentOutputEvent` already exist in `agent_runtime_contracts.dart`.
* The project direction explicitly says Aicove is an Agent context management system, not a prompt management system.
* `StandardChatAgent` already wraps foreground chat into an Agent run without breaking the old chat path.
* `BackgroundAgentService`, `ContextAnalyzer`, and `AnalyzerScheduler` already implement a dedicated proactive/background agent path with trace, tool preview, trigger creation, and session state.
* Aicove has stronger domain constraints: mental-health companionship, contact-level context, proactive care, plugin/multimodal output, and privacy-sensitive memory.

So the lesson is not "replace Aicove with GenericAgent". The better lesson is to borrow the information-density and self-evolution patterns while keeping Aicove's stricter product boundaries.

## Worth Borrowing Now

### 1. Memory pyramid for Agent Context

Aicove already has L1/L2/L3-ish memory prompt variables in `prompt_defaults.json`, but GenericAgent makes the hierarchy operational:

* L1 should be a very small routing index, not a rich profile.
* L2 should hold stable facts/profile.
* L3 should hold reusable contact-specific care patterns or conversation SOPs.
* L4 should archive raw or semi-raw session traces for offline distillation.

For Aicove, this maps cleanly to `AgentContextEntry` metadata and token-budget policy:

* `layer=memory`, `metadata.memoryLevel=L1/L2/L3/L4`
* L1 always tiny and high priority.
* L2 selected by contact scope.
* L3 recalled only when triggered by recent topic/emotion.
* L4 never injected raw into chat; only used by MemoryAgent/AnalyzerAgent for distillation.

### 2. "Action-verified only" memory writing

GenericAgent's memory SOP is blunt but valuable: no execution, no memory. In Aicove terms:

* Do not write long-term memory just because the model inferred something.
* Prefer storing observations grounded in actual conversation messages, user-confirmed preferences, or successful/failed proactive outcomes.
* For proactive care, a "worked well" pattern should require evidence such as user response, no opt-out, or later positive engagement.

This is especially important for a mental-health app because false or overconfident memory is not just annoying; it can distort the relationship.

### 3. Agent step outcome, not just final result

GenericAgent's `StepOutcome(data, next_prompt, should_exit)` is simple but points to a useful missing abstraction in Aicove.

Aicove currently has `AgentRunResult` status and `AgentOutputEvent`, but for multi-round background agents we may want an internal step contract:

* `continueWithPrompt`
* `emitToolResult`
* `askUser`
* `awaitExternal`
* `complete`
* `abort`

This would make `BackgroundAgentService`, proactive analyzer preview loops, future MemoryAgent, and RendererAgent share the same continuation semantics instead of each service owning its own loop rules.

### 4. Run-local working checkpoint

GenericAgent's working checkpoint is not long-term memory; it is a compact scratchpad that survives turns inside one task.

Aicove can use the same idea for long proactive/background runs:

* Keep a structured `AgentRunScratchpad` in trace metadata or run state.
* Store only compact, current-run facts: selected trigger candidate, failed preview reason, revised fire time, safety concerns, user preference constraints.
* Inject it as `runtimeFacts`, not as user/profile memory.

This would reduce repeated analysis inside `ContextAnalyzer` and make long multi-tool runs more stable.

### 5. Tool surface should be atomic; workflows should be SOPs/recipes

GenericAgent succeeds because the base tool surface is small and composable. For Aicove:

* Keep plugin tools atomic: generate TTS, draw image, create proactive trigger, preview proactive reply, write memory candidate, etc.
* Put multi-step behavior in Agent recipes / SOP nodes / output pipeline, not inside one giant tool.
* Add safety tier, allowed agent kinds, and delivery mapping to tool metadata.

This aligns with Aicove's existing `ToolPolicy`/`OutputContract` direction.

### 6. Token-density tricks for tool schemas and context

GenericAgent avoids repeating full tool instructions when unchanged and compresses old tool/thinking blocks.

Aicove can borrow this cautiously:

* In trace/runtime, track which tool policy/schema was rendered.
* For native provider calls, keep full schema where required by API, but avoid duplicating verbose natural-language tool descriptions in system prompt.
* For old trace/history blocks, keep summarized tool call facts rather than raw payloads in future Agent context.

### 7. Scheduled reports as first-class artifacts

GenericAgent scheduler tasks generate report files and use those reports as proof of completion.

Aicove's proactive system already has `AnalyzerScheduler`, trigger logs, and heartbeat. It could benefit from a report-like artifact for sensitive flows:

* why analyzer chose silence/trigger
* what context was used
* which safety checks passed
* why preview was accepted or rejected

This would improve auditability without surfacing implementation details to the user.

## Worth Watching Later

* L4 session archive compression: useful for long-term MemoryAgent and analytics, but should be privacy-scoped and opt-in.
* Self-evolving skills: valuable if converted into "care playbooks" or "agent recipes", not arbitrary code-writing tools.
* Multi-frontend adapter model: Aicove can treat notification, foreground chat, background trace, memory store, and future channel integrations as delivery-channel adapters.
* Reflect/autonomous mode: useful for backend maintenance jobs and offline memory distillation, risky for direct user-facing autonomy.

## Do Not Copy Directly

* Arbitrary OS/browser/ADB control does not fit a patient-facing companion app.
* Runtime package installation and self-written executable tools are unsafe for mobile and healthcare-adjacent contexts.
* GenericAgent's memory is personal-computer oriented; Aicove needs consent, scope, deletion, privacy, and clinical safety boundaries.
* The small monolithic Python style is inspiring for clarity, but Aicove should keep its typed Flutter/FastAPI interfaces and traceability.
* "Use more autonomy" is the wrong takeaway. The right takeaway is "use more verified, compressed, context-aware continuity."

## Suggested Aicove Direction

1. Short term:
   * Add memory-level metadata and selection rules to Agent Context.
   * Add a run-local scratchpad concept for background/proactive agent runs.
   * Add richer trace for selected memory entries, tool policy, output contract, and budget decisions.

2. Medium term:
   * Introduce a MemoryAgent post-run distiller that outputs memory candidates with evidence, confidence, scope, and expiry.
   * Make proactive care outcomes feed back into contact-specific care playbooks only after evidence.
   * Extend Agent Context Studio nodes to include "SOP / playbook" nodes separate from raw memory.

3. Later:
   * L4 session archive for offline summarization.
   * Recipe-based tool workflows with safety tiers.
   * Scheduled audit reports for proactive/background agents.

## Bottom Line

GenericAgent is strongest as a proof that agent capability can grow from a small kernel if memory is dense, verified, and reusable. Aicove already has a better domain architecture; the opportunity is to add GenericAgent-style memory crystallization and run continuity to Aicove's existing Agent Context Runtime, not to import GenericAgent's unrestricted desktop autonomy.
