# fix: streaming chat scroll jank

## Goal

Fix the visible jank when the user scrolls the chat message list while an AI reply is streaming.

## What I Already Know

* Real-device recording reproduced the issue on Android device `3a845d3f`.
* Valid recording: `scratch/ui-recordings/aicove_stream_scroll_valid_20260521_1703.mp4`.
* `dumpsys gfxinfo` during the test reported 333 rendered frames, 23 janky frames, p90 32ms, p95 40ms, p99 69ms, 23 missed vsync, and 14 slow UI thread frames.

## Requirements

* Keep AI text streaming visible in the chat page.
* Improve scroll responsiveness while a reply is streaming.
* Keep chat history and send behavior unchanged.

## Acceptance Criteria

* [ ] Streaming reply still updates in the message list.
* [ ] Scrolling during streaming is visibly smoother on the connected Android device.
* [ ] Flutter analysis or compile checks do not introduce new blocking errors.
* [ ] Real-device recording is refreshed after the fix.

## Definition of Done

* Code change is scoped to the chat UI/update path.
* Existing architecture boundaries remain intact.
* `flutter pub get` and `flutter run --no-resident` are executed.

## Out of Scope

* Redesigning the chat UI.
* Changing model provider behavior.
* Reworking message storage.

## Technical Notes

* Start from chat page, message list widgets, and streaming update providers.
