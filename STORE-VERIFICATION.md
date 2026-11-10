# Store verification request — v2.3.6

Use the marketplace's [Plugin verification issue form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
for the exact source commit identified by the `v2.3.6` release tag.

**Request:** Verify and publish a newer upstream commit  
**Plugin ID:** `sjfortin.nts-radio`  
**Repository:** `https://github.com/sjfortin/omarchy-nts-radio`  
**Commit:** Resolve `v2.3.6` to its full 40-character commit SHA and confirm it
is the published repository HEAD before submitting.

The 2.3.1 patch fixes the explicit-paste transfer issue raised in marketplace
request #14565. It intercepts native paste and bounds clipboard transfer outside
the GUI with a byte cap, an overall deadline and process-group cleanup. The
request must target the new published HEAD, not the superseded 2.3.0 commit.

The 2.3.2 patch additionally bounds API/IPC admission, callback fan-out and cast
worker creation in response to the second review finding. Burst tests hold
responses/discovery slow while submitting 2,000 calls.

The 2.3.3 patch fixes the PyChromecast disconnect signature and retains retiring
socket workers until termination. No new socket worker is admitted while an
old one is still retiring. Metadata-only discovery avoids unused socket clients.

The 2.3.4 patch isolates remote artwork fetch/decode with byte, dimension,
process resource and absolute time limits. Qt receives only normalized 384px
rasters; active workers, pending work and thumbnail cache are bounded.

The 2.3.5 patch bounds finite resolver/import operations with a supervisor:
absolute deadlines, producer output caps, forced process-group cleanup and
reaping. Backup import rejects nonregular files and recovers busy state on exit.

The 2.3.6 patch handles supervisor launch failure without an exited signal,
clearing partial state and releasing resolver/import admission for retry.

## Release summary

NTS Radio 2.3.6 adds a persistent archive queue, local listening history, sleep
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

Validation: 12 JavaScript tests, 42 Python tests and 79 QML test cases passed;
GitHub Actions, manifest validation, and compilation against the installed
Omarchy runtime passed. Physical speaker/shutdown recovery checks have not been
performed and must not be represented as completed.

The marketplace's bot and maintainer workflow must run on the published SHA.
This request template is not a verification result.
