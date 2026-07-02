# Agent management panel shows agents and chat contacts

## Goal

Make the Agent management panel at `/api/v1/prompt-defaults-admin/panel` manage real Agent Context assembly graphs, not just show empty Agent cards. Built-in proactive reply, memory, and contact chat agents must have editable node-flow graphs whose saved state is persisted and exported into a project-side runtime artifact that the Flutter project can consume.

## What I Already Know

* The user wants proactive reply agent, memory agent, and chat contacts visible in the Agent management panel.
* Root `README.md` defines the architecture direction as Agent Context Runtime, with `Chat / Proactive / Analyzer / Memory / Renderer` sharing the same `AgentDefinition` surface.
* Each contact should map to an independent `chat_agent:<contactId>`.
* The main panel entry is `/api/v1/prompt-defaults-admin/panel`; Agent Context data is stored in `cloud_backend/data/agent_context_admin.json`.
* `cloud_backend/agent_context_admin_api.py` already has agent kinds, default permissions, trigger policies, delivery channels, contact listing, and chat-agent ensure endpoints.
* Current agent listing reads only persisted `document.agents`; default document starts with `agents: []`.
* `contacts/chat-agents/ensure-all` only processes draft contacts unless `userId` is passed. The current panel's "同步联系人" button sends only `{ includeDrafts: true }`, so real DB contacts are not included.
* User clarified on 2026-05-06 that the previous implementation is insufficient: the panel must write/manage actual node assembly flowcharts and the saved graph must sync into the project, not remain a visual-only backend admin state.
* Prompt defaults already expose useful virtual prompt nodes for Agent Build, including `auto_reply.analyzer.default`, `auto_reply.agent.objective`, `auto_reply.context.runtime_instruction`, `memory.summary.default`, `memory.summary.extra_instruction`, `memory.summary.role_persona.*`, `memory.role_scoped.root`, `memory.profile_prompt.root`, `memory.merge.prompt`, and `memory.reenrich.default`.
* Existing backend graph save endpoint persists `agentGraph` and derives `bindings`, but built-in agents currently start with empty graphs and no project-side export/consumer artifact.
* User clarified on 2026-05-06 that the Agent Build right panel must show the actual prompt text received by the selected Agent, and graph prompt nodes must expose prompt preview plus editing inside the node properties panel.
* User corrected on 2026-05-06 that `auto_reply.agent.objective` is for the chat model that generates the final proactive reply. It must not be linearly connected after `auto_reply.analyzer.default` as though all three proactive prompts are one model request.

## Requirements

* The Agent management panel must include system-level agents for proactive reply and memory, using the existing `AgentDefinition` shape and kind-specific defaults.
* The panel must make contact-backed `chat_agent:<contactId>` agents discoverable from existing contacts, not only from web draft contacts.
* The implementation should preserve the current JSON-document storage model and avoid database migrations.
* Existing user-created agents and bindings must not be deleted or overwritten.
* Agent cards should clearly distinguish Chat / Proactive / Memory kinds through the existing kind labels.
* Built-in proactive and memory agents must be seeded with meaningful default graph nodes from the prompt defaults virtual node library, so selecting them immediately shows an assembly flowchart on the canvas.
* Saving a graph must continue to persist both `agentGraph` and derived `bindings`.
* The backend must expose or run a project sync step that writes the saved Agent Context document/graph data into a Flutter project artifact under `apps/aicove_flutter/assets/` or generated Dart, so the app has a concrete source to load.
* The Flutter project must include a small consumer/loader for that synced artifact, so the graph is not only stored in `cloud_backend/data/agent_context_admin.json`.
* The Agent properties panel must preview the actual assembled prompt/messages produced from the current graph, using the prompt defaults text instead of a mock-only summary.
* Prompt nodes selected on the graph must preview their referenced prompt template in the right properties panel.
* Prompt nodes selected on the graph must allow editing title/description/template/variables through the prompt defaults persistence and codegen path, while keeping generic Agent Context node/assets mutation blocked for prompt-default virtual nodes.
* Saving a prompt node edit must refresh the prompt defaults document, regenerate Dart prompt defaults, refresh the Agent Build node library, and keep the Agent Context Flutter artifact in sync.
* Built-in proactive graph seeding must separate stages:
  * Analyzer stage: `auto_reply.analyzer.default` plus `auto_reply.context.runtime_instruction` belong to the background analyzer/trigger-decision request.
  * Reply generation stage: `auto_reply.agent.objective` belongs to the chat/proactive reply generation request.
  * The default graph must not connect analyzer prompt nodes directly into the chat-generation prompt as a single prompt chain.
* Tests should cover graph seeding and project sync serialization.

## Acceptance Criteria

* [x] `GET /api/v1/agent-context-admin/agents` returns at least the built-in proactive and memory agents when the document has no such agents.
* [x] Selecting `proactive_agent:default` immediately shows a non-empty graph with proactive prompt nodes split by semantic stage.
* [x] Selecting `memory_agent:default` immediately shows a non-empty graph with memory prompt nodes.
* [x] Existing user-created agents remain present after load and are not overwritten.
* [x] The panel can create chat agents for real contacts by passing a `userId`, while still supporting draft contacts.
* [x] `chat_agent:<contactId>` remains the stable id format for contact chat agents.
* [x] Saving a graph updates `agentGraph` and derived `bindings`.
* [x] A project sync endpoint or save hook writes a Flutter-consumable Agent Context artifact from the backend document.
* [x] Flutter has a minimal loader/contract test for the synced Agent Context artifact.
* [x] Selecting an Agent shows a right-side "actual prompt" preview built from the saved/current graph prompt nodes and grouped by stage when graph nodes declare a stage.
* [x] Selecting a prompt graph node shows that prompt's real template and allows editing it from the node property panel.
* [x] Prompt-node edits persist to `apps/aicove_flutter/assets/prompt_defaults.json` and regenerate `prompt_builtin_defaults.g.dart`.
* [x] No database migration or new dependency is introduced.

## Definition of Done

* Tests added or updated where practical.
* Backend import/compile check passes.
* Local endpoint behavior verified where the dev server is available.
* Docs/spec update considered; only update durable docs if the API contract or panel workflow changes.

## Out of Scope

* Moving Agent Context storage from JSON to database.
* Rebuilding the admin panel with a frontend framework.
* Full Flutter App migration of Agent Context editing.
* Full real runtime execution migration of every proactive/memory path. This task must create the project-side synced source and loader, but does not have to fully replace all existing runtime prompt assembly call sites.

## Technical Approach

Recommended MVP:

1. Keep the backend bootstrap helpers for built-in `proactive_agent:default` and `memory_agent:default`, but seed their `agentGraph` with default prompt nodes when the graph is missing or empty.
2. Derive graph nodes from prompt-default virtual assets so the same nodes shown in the node library are saved into the graph:
   * proactive analyzer stage: `auto_reply.analyzer.default`, `auto_reply.context.runtime_instruction`
   * proactive reply generation stage: `auto_reply.agent.objective`
   * memory: `memory.summary.default`, `memory.summary.extra_instruction`, `memory.summary.role_persona.generic_instruction`, `memory.summary.role_persona.context_instruction`, `memory.role_scoped.root`, `memory.profile_prompt.root`, `memory.merge.prompt`, `memory.reenrich.default`
3. For built-in proactive graph bootstrap, use node `config.stage` and/or separate graph lanes to distinguish analyzer from reply generation. Only connect nodes that belong to the same semantic request stage.
4. When saving or bootstrapping graphs, keep `bindings` synchronized with `agentGraph` using the existing graph-to-bindings conversion.
5. Add a project sync endpoint/save hook that writes a compact Flutter-consumable JSON artifact such as `apps/aicove_flutter/assets/agent_context_defaults.json`.
6. Add a minimal Flutter loader/parser for that artifact so app code and tests can consume the same saved graph source.
7. Add a dedicated prompt-default-node update API for graph prompt nodes. This API should call the existing prompt defaults codegen path, then refresh Agent Context artifact metadata without changing generic virtual prompt node read-only protection.
8. Add an Agent prompt preview API that reads the selected graph's enabled prompt nodes, resolves prompt defaults templates, and returns rendered message rows plus concatenated text for the panel.
9. Keep current JSON document storage and API route shapes; no database migration.

## Technical Notes

* Relevant backend API: `cloud_backend/agent_context_admin_api.py`.
* Relevant panel file: `cloud_backend/prompt_defaults_admin_panel.html`.
* Relevant docs: `cloud_backend/README.md`, `cloud_backend/Agent上下文系统Web管理端实施说明_20260430.md`, `README.md`.
* Current local data summary: agent document has persisted assets and no contact drafts; do not overwrite existing content.
