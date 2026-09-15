# Active task

`.trellis/tasks/08-21-novelai-v5-full-default`

# Goal

Implement the approved NovelAI V5 Full upgrade in the Flutter client. V5 Full must
be the default for fresh installs and historical built-in NovelAI defaults, while
explicit V3/Furry V3/V4/custom selections remain intact. NovelAI model discovery
must remain a zero-network controlled catalog.

# Read first

- `.trellis/tasks/08-21-novelai-v5-full-default/prd.md`
- `.trellis/tasks/08-21-novelai-v5-full-default/design.md`
- `.trellis/tasks/08-21-novelai-v5-full-default/implement.md`
- `.trellis/tasks/08-21-novelai-v5-full-default/research/novelai-v5-api.md`
- `README.md`
- `.trellis/spec/frontend/index.md`
- `apps/aicove_flutter/docs/04_功能模块规范/绘图功能/图片渠道适配说明_20260306.md`

# Ownership and allowed files

You own implementation only in these files unless a directly related test helper
requires one additional file; if so, flag it in the receipt before changing it:

- `apps/aicove_flutter/lib/src/features/settings/data/support/ui_models_store_support.dart`
- `apps/aicove_flutter/lib/src/features/settings/data/local/ui_models_store_local_data_source.dart`
- `apps/aicove_flutter/lib/src/core/api/agent_image_api_support.dart`
- `apps/aicove_flutter/test/features/settings/provider_protocol_compat_test.dart`
- `apps/aicove_flutter/test/features/settings/app_settings_notifier_test.dart`
- `apps/aicove_flutter/docs/04_功能模块规范/绘图功能/图片渠道适配说明_20260306.md`

You are not alone in this repository. Preserve all pre-existing user and agent
changes. Do not revert, reformat, or edit unrelated files. Do not touch either
Trellis task directory, do not commit, push, publish, deploy, access credentials,
or make real NovelAI requests.

# Required implementation

1. Make the controlled text-to-image catalog exactly this order:
   - `nai-diffusion-5-full`
   - `nai-diffusion-5-curated`
   - `nai-diffusion-4-5-full`
   - `nai-diffusion-4-5-curated`
   - `nai-diffusion-4-full`
   - `nai-diffusion-4-curated-preview`
   - `nai-diffusion-3`
   - `nai-diffusion-furry-3`
2. Fresh built-in NovelAI provider:
   - use persisted key `custom_config` (not `customConfig`)
   - default `nai-diffusion-5-full`
   - visible models start with V5 Full (V5 Curated may be second)
   - fresh data includes the new migration id as already applied.
3. NovelAI normalization must preserve controlled catalog priority, then retain
   unknown existing model IDs in their original order; generic alphabetic sorting
   must not reorder NovelAI models.
4. Add an idempotent one-time local migration for every provider recognized as
   NovelAI by id/base URL/requestFormat:
   - merge the controlled catalog before unknown existing IDs
   - put V5 Full first in visible models and preserve other visible values
   - update missing defaults and historical defaults V4.5 Curated, V4.5 Full,
     and old V4.5 Curated Preview alias to V5 Full
   - preserve explicit V3, Furry V3, V4, and unknown custom default IDs
   - preserve tokens, base URL, enabled state, capabilities, and unknown
     `custom_config` entries
   - after migration, later user changes must survive reload.
5. API support empty-model default becomes V5 Full.
6. V5 Full and Curated use structured prompt fields and minimal V5 parameters:
   `params_version=4`, default `scale=7.0`, default 23 steps, Euler Ancestral,
   `v4_prompt`, and `v4_negative_prompt`. Explicit generation arguments still win.
7. V5 must use the structured-model reserved key set. `image_parameters` cannot
   override core fields or inject V3-only legacy/qualityToggle/sm/sm_dyn fields.
8. Remove cross-model enum fallback for every explicit NovelAI model. Keep only
   deterministic old-ID alias normalization. One generation call means one HTTP
   request and failures preserve the selected model in the request/log/error path.
9. Preserve existing V4/V4.5 and V3/Furry V3 compatible payload behavior.
10. Update the image provider document with the current catalog, V5 request branch,
    zero-network catalog rule, and no silent cross-model fallback.

# Tests

Add focused tests covering at least:

- preview returns exact order and makes zero HTTP requests
- fresh settings survive SharedPreferences write/reload with V5 Full default
- migration of historical defaults, preservation of V3/custom defaults, multiple
  NovelAI providers, full field preservation, idempotence, and post-migration user choice
- V5 Full and Curated request bodies
- V5 protected-core override attempt
- enum error causes exactly one request for V5, V4.5, and V3
- Furry V3 remains on the legacy branch
- existing V4.5/V3 expectations stay green.

Run `dart format` on changed Dart files, then run these from
`apps/aicove_flutter`:

```sh
flutter test --timeout 60s test/features/settings/provider_protocol_compat_test.dart
flutter test --timeout 60s test/features/settings/app_settings_notifier_test.dart
```

If a command fails, diagnose and fix within scope. Return a structured receipt with
changed files, tests, any remaining concern, and the runId for resume.
