# brainstorm: prompt panel contact nodes context preview

## Goal

Improve the prompt management panel so it can show which nodes are actually involved for a selected contact, and provide a preview of the prompt context that will be used.

## What I already know

* The user wants a more detailed change to the prompt management panel.
* The panel should show the nodes that a contact actually involves.
* The panel should provide a context preview.
* The relevant product surface is the cloud Backend Agent Context Studio in `cloud_backend/prompt_defaults_admin_panel.html`.
* The backend already has contact and ChatAgent APIs under `/api/v1/agent-context-admin/contacts` and `/agents/{agent_id}/graph`.
* The backend already has `/agents/{agent_id}/prompt-preview`, returning ordered prompt node previews and stage groups.
* The current panel shows Agent Build graph and a generic prompt preview in the Agent property panel, but does not expose a contact-first view of the actual graph nodes and preview.

## Assumptions (temporary)

* "Contact" refers to a synced or draft contact listed by the Agent Context Studio contacts API.
* "Node" refers to Agent Build graph nodes for that contact's `chat_agent:<contactId>`.
* The MVP can reuse the existing graph and prompt preview APIs without introducing a new schema.

## Open Questions

* Whether the context preview should show only prompt nodes or also non-prompt context assets such as memory, runtime facts, lorebook, and tool policy.

## Requirements (evolving)

* Show contact-specific involved nodes in the prompt management panel.
* Add a context preview for the selected contact or prompt assembly.
* Prefer a contact-first debugging panel that resolves `contactId -> chat_agent:<contactId> -> agentGraph -> prompt-preview`.

## Acceptance Criteria (evolving)

* [ ] A selected contact exposes its actually involved prompt nodes in the panel.
* [ ] The user can preview relevant context before using or saving prompt configuration.
* [ ] Existing prompt management flows continue to work.
* [ ] Contact preview uses actual graph nodes from the selected ChatAgent, not a separate hand-built list.
* [ ] Prompt preview remains grouped by stage when the graph has stages.

## Definition of Done (team quality bar)

* Tests added or updated where appropriate.
* `flutter pub get` and app run verification completed.
* Narrow and wide screen views checked.
* Docs or Trellis specs updated only if behavior or conventions change.

## Out of Scope (explicit)

* Unknown until repository inspection and requirement clarification are complete.

## Technical Notes

* Task created at `.trellis/tasks/05-26-prompt-panel-contact-node-context-preview`.
* Read `README.md`, frontend/backend Trellis indexes, Agent Context docs, cloud backend docs, and main panel implementation.
* Relevant files: `cloud_backend/agent_context_admin_api.py`, `cloud_backend/prompt_defaults_admin_panel.html`, `cloud_backend/tests/test_agent_context_admin_api.py`.
