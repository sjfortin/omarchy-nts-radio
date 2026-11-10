# NTS Radio 2.3.4 — bounded artwork loading

Release: [v2.3.4](https://github.com/sjfortin/omarchy-nts-radio/releases/tag/v2.3.4).
Addresses the [remote artwork finding](https://github.com/omacom/omarchy-plugin-marketplace/issues/14565#issuecomment-6759787939).

Both browser and panel artwork use an isolated fetch/decode pipeline. Downloads
have a 2 MB encoded limit, a 10-second absolute deadline and validated HTTPS
redirects. Raster headers are checked before decoding; decoder memory, CPU,
output size and dimensions are limited. The supervisor kills the whole worker
process group and owns temporary-file cleanup. Qt receives only a validated,
fixed 384×384 RGB PPM thumbnail, with no original metadata or remote URL.

Admission is bounded to two active workers and 24 pending jobs, duplicate
subscriptions to 16 owners, and the LRU cache to 24 entries / 14.4 million
characters. Hidden or replaced frames cancel work and release decoded sources.
Python 3 and ImageMagick are required for thumbnails; unavailable helpers leave
the normal placeholder visible, without automatic installation.

Validation: 12 JavaScript, 36 Python and 75 QML cases passed (123 total), including
real chunked/oversized/slow HTTP responses, allowed and rejected redirects,
PNG/JPEG/WebP normalization, CLI resource-limit inheritance, supervisor deadlines,
output caps, cleanup, admission bursts, cache eviction and Qt thumbnail rendering.
Physical speaker checks remain outstanding as documented in earlier releases.

---

# NTS Radio 2.3.3 — PyChromecast connection cleanup

Release: [v2.3.3](https://github.com/sjfortin/omarchy-nts-radio/releases/tag/v2.3.3).
This patch addresses the [dependency cleanup finding](https://github.com/omacom/omarchy-plugin-marketplace/issues/14565#issuecomment-6759188606).

- Use the supported PyChromecast 14.0.10 `disconnect(timeout=0)` API; the old
  `blocking=False` keyword prevented cleanup from executing.
- Failed waits, stale candidates, replaced connections and shutdown candidates
  all receive stop requests. Retain their references until `socket_client` is
  no longer alive, with a bounded join budget. Admission returns busy while an
  old worker is retiring, so a sequence of slow attempts cannot accumulate
  dependency socket workers.
- Discovery retains CastInfo metadata, not a new socket client for every peer.
  A fresh client is constructed only for an admitted connection after previous
  workers terminate. Metadata discovery has an explicit timeout/device limit.
- Strict test doubles implement the real wait/disconnect/join signatures; a
  wrong keyword now fails the stop-request assertions. Tests cover wait failure,
  stale/replaced/connecting cleanup and 2,000 attempted connections while one
  retired worker remains alive.

Validation: 12 JavaScript, 22 Python and 67 QML cases passed (101 total). A
network-free contract check used the installed PyChromecast 14.0.10 disconnect
and join implementations with a fake socket client and verified stop requests,
retention while alive and release after termination. This is not a physical
speaker test. Previous bounded-paste and API/worker-admission fixes remain.

---

# NTS Radio 2.3.2 — bounded API and cast request admission

Release: [v2.3.2](https://github.com/sjfortin/omarchy-nts-radio/releases/tag/v2.3.2).
This patch addresses the [second marketplace review finding](https://github.com/omacom/omarchy-plugin-marketplace/issues/14565#issuecomment-6757516019)
about repeated IPC requests retaining unbounded work.

- `episode` admits one lookup and returns `busy` while it is pending. Later
  playback/output actions invalidate its play intent. Global API admission caps
  active/queued/retry/deferred-cache jobs at 32 and callback fan-out at 8 per
  job. Busy failures are synchronous and retain no deferred rejection closure.
  Cached replies share one bounded queue and one timer, so cache hits cannot
  bypass the pending-work limit. Retry accounting updates on every transition.
- `devices` reports `queued` / `started` / `busy`; repeat calls coalesce and do
  not extend the discovery timer. The Python bridge starts exactly one lazy
  worker and retains one discovery flag and one replaceable latest connection
  tuple. It cannot create one worker/future per command. Shutdown cancels pending
  work, rejects new admission and closes discovery browsers that arrive late.
  Slow browser/connection cleanup runs outside the admission lock.
- Burst tests submit 2,000 requests with network/device work held slow. They
  verify distinct-job caps, duplicate callback caps, bounded cached delivery,
  retry/active accounting, IPC busy results, one discovery command and one
  worker, latest-target replacement and shutdown resource cleanup.

Validation: 12 JavaScript, 18 Python and 67 QML cases passed (97 total). The
2.3.1 bounded-paste fix remains included. Physical cast testing remains
outstanding as documented below; these changes do not claim it was completed.

---

# NTS Radio 2.3.1 — bounded search clipboard transfers

Release: [v2.3.1](https://github.com/sjfortin/omarchy-nts-radio/releases/tag/v2.3.1).
This patch addresses the [marketplace review finding](https://github.com/omacom/omarchy-plugin-marketplace/issues/14565#issuecomment-6757314117)
about a hostile clipboard provider blocking the shared shell GUI during paste.

Search now consumes keyboard paste shortcuts and primary-selection middle-click
before TextInput can read the clipboard. An explicit Paste button uses the same
worker; right-click cannot expose native paste. The worker has a 4 KB byte cap,
a single two-second monotonic deadline, no partial-result insertion, and pipe /
producer-process-group cleanup on failure or cancellation. The shell receives a
bounded JSON response. Edits, selection changes, focus loss and page navigation
invalidate pending results. A separate three-second GUI guard handles helper
failure; there is no synchronous clipboard fallback.

Python tests exercise valid UTF-8, byte-boundary/overflow, infinite output,
silent and slow-drip providers, EOF without process exit, invalid UTF-8, failed
producers, descendant-writer cleanup and SIGTERM cancellation. QML tests cover
paste shortcuts, middle/right click, selection replacement, query length,
focus/edit/navigation cancellation, repeated requests, malformed responses,
GUI guard behavior, the explicit Paste button and ordinary typing.

Validation: 12 JavaScript, 15 Python and 58 QML test cases passed (85 total).
The installed Quickshell runtime compiled all four entry points. A separate
offscreen runtime check used the real ClipboardReader/helper with a fake
slow-drip producer: the transfer timed out while the GUI processed 113 timer
ticks. This did not access the user's real clipboard.

Python 3 and `wl-paste` are needed for paste; neither is installed automatically.
Manual search entry remains available if they are missing. Existing physical
cast checks remain outstanding as recorded below.

---

# NTS Radio 2.3.0 — release and verification

Release: [v2.3.0](https://github.com/sjfortin/omarchy-nts-radio/releases/tag/v2.3.0).
The release tag identifies the exact source commit. Marketplace re-verification
is requested separately and remains subject to its bot checks and maintainer
approval. The physical-device checks below remain outstanding.

## Implemented

- Latest-selection-wins archive resolution, cancellation through speaker
  connection, a 45 second overall deadline, and a 32 entry resolution cache.
- Paused output transfers stay paused and preserve their position.
- Archive replacements reuse mpv via `loadfile`, with per-file resume/title
  options and restart fallback. Mode changes restart on confirmed process exit
  rather than sleeping for 400 ms. IPC connection is attempted immediately.
- The cast command loop no longer waits up to 12 seconds for media activation.
  Connection requests reject superseded workers. Finite cast completion can
  advance the queue, and the archive position refreshes every five seconds.
- Recognized live and archive cast sessions are adopted after restart without
  reloading media. Paused archives stay paused. Login network failures retry;
  explicit playback/output actions cancel recovery. Legacy recovery covers live
  URLs only. Shutdown, reload and disable detach without stopping the speaker.
- Persistent queue (100), local deduplicated history (200), sleep timers and
  sleep-at-end; opt-in hourly saved-show discovery; backup export and validated
  import with preview and an automatic pre-import backup.
- Listening browser page, queue actions, loading stages, Cancel/Retry, `q`
  navigation and additional IPC commands. Queue/history views reuse delegates.
- English UI catalog through Omarchy Translations, locale-aware new numeric
  labels and browser mirroring/reading-direction keys. English is the only
  shipped language catalog; untranslated messages retain English fallback.
- HTTP status-aware retries, bounded IPC parsing and cast session metadata,
  and markup neutralization for the shell-owned tooltip.

No dependencies are installed automatically. Saved-show background requests
are disabled by default. State migration retains version 1 saved items and
resume data. New history and queue live in the same local library file.

## Measured performance

Offline benchmark on this machine, mpv 0.41.0, 12 trials, silent WAV, null audio,
monotonic timing, same `playback-restart` event for both paths:

| Path | Median | p95 |
|---|---:|---:|
| New process + IPC connection + initial load | 199.9 ms | 232.2 ms |
| Replace in an existing process | 10.9 ms | 17.3 ms |

The previous archive replacement path additionally imposed a fixed 400 ms
wait. These measurements isolate process/loading overhead. They do not measure
NTS network latency, SoundCloud/Mixcloud extraction or actual audible onset.
Reproduce with `python3 scripts/benchmark_player.py`.

`omarchy-shell nts-radio status` exposes the latest bounded software-stage
trace. UI trace durations use wall-clock elapsed time; the benchmark uses a
monotonic clock. No signed stream URLs are logged in the trace.

## Automated and visual checks

Final local checks: 12 JavaScript tests, 6 Python tests, and 46 QML test cases
passed. QML emitted no warnings. Manifest validation and `git diff --check`
passed, and all four entry points compiled against the installed runtime.
The installed Omarchy shell was restarted and its live IPC status confirmed the
new queue/history/sleep/recovery fields. The existing saved episode and all 14
resume entries remained present; playback stayed idle.
QML fixtures simulate processes, sockets and devices; they do not test real speaker hardware.
The Listening queue/tools screens were rendered and inspected at 800×700 and
548×410. All four entry points are compiled separately against the installed
Omarchy/Quickshell runtime without instantiating the live service.

## Physical device checks still required

- Start a live cast; restart the controller and verify the actual channel and
  working Stop control without a reload or audible interruption.
- Repeat with an archive playing and paused; verify episode, position, seek,
  pause/resume, queue completion and volume.
- Shut down the computer while casting, restart with network initially absent,
  and verify recovery when network access returns. Leave unrelated music on the
  speaker for the negative case.
- Confirm Cancel during resolution/connection, rapid episode/output changes,
  and expired/removed archive handling against actual hosts.
- Measure real cold/warm network starts and switching before making any broader
  latency claims. A speaker that strips custom media data cannot recover archive
  identity; live URL recovery remains available.

Sleep timers run on the computer. They cannot stop a speaker while the computer
is off; a missed deadline is handled after wake. Explicitly stop casting before
removing the plugin if the speaker should also stop.

## Store re-verification

The marketplace verifies exact commits. Use the [Plugin verification issue
form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml)
and select **Verify and publish a newer upstream commit**. Supply:

- Plugin ID: `sjfortin.nts-radio`
- Repository: `https://github.com/sjfortin/omarchy-nts-radio`
- The full 40-character SHA of the published repository HEAD, obtained after
  committing these changes. Do not use the old checkout SHA.

The bot checks compatibility and its automated baseline for that revision.
Marketplace maintainer approval completes publication; local validation alone
cannot grant marketplace verification. See the [current verification
process](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/VERIFICATION.md).
The verification request template is in [STORE-VERIFICATION.md](STORE-VERIFICATION.md).

Optional experiments from the audit remain deliberately separate: local
resolved-stream caching, direct remembered-device endpoint connection, and
rewriting older search/show lists for virtualization. They need real host/device
profiling and expiry/fallback testing before deployment.
