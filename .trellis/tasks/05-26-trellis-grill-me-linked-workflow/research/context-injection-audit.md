# Context Injection Audit

## Findings

* Codex SessionStart currently injects about 24k characters.
* The largest block is `<workflow>` at about 16.8k characters because it includes detailed Phase 1/2/3 instructions.
* `<workflow>` and `<task-status>` both describe the next action, so the new-session payload repeats planning and execution guidance.
* `<current-state>` includes both `ACTIVE TASKS` and `MY TASKS`; with 13 active tasks this repeats task inventory information.
* `<guidelines>` inlines `.trellis/spec/guides/index.md`, although most turns only need the path and can read it on demand.
* UserPromptSubmit currently injects about 521 characters and is already compact enough.

## Recommended Change

Make SessionStart compact:

* Keep current developer, git summary, current task, spec index paths, and short task-status guidance.
* Replace detailed workflow body with a short phase index plus pointers to `workflow.md` and `get_context.py --mode phase`.
* List thinking-guide paths instead of inlining the guide body.
* Do not change UserPromptSubmit unless later evidence shows it is still noisy.

## Files

* `.codex/hooks/session-start.py`
* `.trellis/workflow.md`
* `.trellis/tasks/05-26-trellis-grill-me-linked-workflow/prd.md`
