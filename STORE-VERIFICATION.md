# Store verification request — v2.3.0

Use the marketplace's [Plugin verification issue form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
for the exact source commit identified by the `v2.3.0` release tag.

**Request:** Verify and publish a newer upstream commit  
**Plugin ID:** `sjfortin.nts-radio`  
**Repository:** `https://github.com/sjfortin/omarchy-nts-radio`  
**Commit:** Resolve `v2.3.0` to its full 40-character commit SHA and confirm it
is the published repository HEAD before submitting.

## Release summary

NTS Radio 2.3.0 adds a persistent archive queue, local listening history, sleep
timers, optional saved-show discovery, and validated library backup transfer.
It improves archive switching and playback cancellation, and recovers recognized
live/archive cast sessions after controller restart without reloading the stream.

## Review notes

- No auto-install hooks or new automatic dependency installation.
- The existing mpv/curl/yt-dlp/Python subprocess architecture remains explicit.
- Saved-show background discovery is opt-in and bounded.
- Library/history/queue stay local; backup import is size-bound, validated,
  previewed and backed up before replacement.
- Cast recovery checks only the remembered device and recognized NTS identity.
  It does not start new playback, and user playback/output actions cancel it.
- A cast continues when its controller exits. Explicit Stop ends speaker playback.
- Python cast tests use mocks; physical device checks are tracked in RELEASE.md.

Validation: 12 JavaScript tests, 6 Python tests and 46 QML test cases passed;
GitHub Actions, manifest validation, and compilation against the installed
Omarchy runtime passed. Physical speaker/shutdown recovery checks have not been
performed and must not be represented as completed.

The marketplace's bot and maintainer workflow must run on the published SHA.
This request template is not a verification result.
