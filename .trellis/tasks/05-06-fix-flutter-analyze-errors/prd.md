# fix: flutter analyze blocking errors

## Goal

Make the main Flutter project analyzer pass its blocking error stage by fixing the current `flutter analyze` errors and nearby high-value warnings without broad lint cleanup.

## What I already know

- User asked to run project-wide `flutter analyze`.
- Command run from `apps/aicove_flutter` failed with 121 issues.
- Blocking errors are concentrated in tests:
  - `test/debug_chat_list_temp_test.dart`: missing required `viewportController`.
  - `test/features/chat/data/history_store_adoption_test.dart`: stale `ContextAnalyzer.analyzeAndSchedule` calls.
  - `test/features/chat/presentation/widgets/composer_draft_persistence_test.dart`: callback signature mismatch.
  - `test/features/chat/presentation/widgets/composer_submit_timing_test.dart`: callback signature mismatch.
- User approved fixing the analyzer blockers after the report.

## Assumptions

- Scope is limited to analyzer blockers and nearby warning-level cleanup where the fix is obvious.
- Avoid adding or changing dependencies in this task unless investigation shows it is required for analyzer correctness.
- Do not do a large `info` lint sweep.

## Requirements

- Fix all current `flutter analyze` error-level findings in the main Flutter project.
- Prefer updating tests to current production APIs instead of weakening production code to satisfy stale tests.
- Remove nearby stale imports or invalid overrides if they are directly related and low risk.
- Preserve existing behavior; this is a compatibility/quality fix, not a feature change.

## Acceptance Criteria

- [ ] `flutter analyze` from `apps/aicove_flutter` reports no `error` findings.
- [ ] Any remaining findings are documented by severity/category.
- [ ] No unrelated WIP files are reverted or committed.

## Definition of Done

- Relevant specs are loaded through Trellis context.
- Fixes are scoped to current analyzer blockers.
- Analyzer is rerun after changes.
- Long-term docs/spec update is considered; update only if new durable knowledge is discovered.

## Out of Scope

- Broad style-only cleanup of all `info` lints.
- Dependency updates unless unavoidable.
- UI changes and responsive visual validation.
- Commit/push unless explicitly confirmed later.

## Technical Notes

- Root README project constitution was read.
- Flutter docs index `apps/aicove_flutter/docs/README.md` was read.
- Initial analyzer command:
  - `cd apps/aicove_flutter`
  - `flutter analyze`
