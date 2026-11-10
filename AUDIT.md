# Plugin audit — 2026-11-10

Implementation follow-up: see [RELEASE.md](RELEASE.md) for the 2.3.0 changes,
validation, and the experiments still awaiting host/device profiling. The audit
below records the original source review before implementation.

Scope: source review of local playback, archive resolution, casting, API fetching,
library persistence and browser lists; existing automated checks. No playback
code was changed and no live listening session was interrupted. Findings below
are source-derived; user-visible reproduction and latency measurements remain
necessary before claiming a measured speedup.

## Priority fixes

1. **Rapid cast episode selection can leave Connecting stuck.**
   `Service.qml:569–575` changes the selected episode and sets `resolvingCast`,
   then ignores the return from `resolver.start()`. `Resolver.qml:81` refuses
   work while another resolution runs. Selecting B while A resolves therefore
   never starts B; A's completion is discarded by the source check in
   `Service.qml:591`. Implement latest-selection-wins resolution with request
   generations, cancellation and a pending replacement. Test A → B → C and
   output changes during both cached and uncached resolutions.

2. **Pause does not cancel pending cast resolution.**
   `Service.qml:514` pauses the backend but leaves the resolver and
   `resolvingCast` active. Its completion subsequently calls `caster.play()`
   (`Service.qml:589`). A pause while Connecting can thus start audio later.
   Cancel the pending playback intent and reject obsolete completions. Include
   a test that pauses before resolution finishes and verifies no play command.

3. **Changing archive output starts paused audio.**
   `Service.qml:727–742` unconditionally calls `playEpisode()` after stopping
   the old backend. The live path preserves whether playback was active;
   the archive path does not. Preserve play/pause intent and position across
   the transfer, including a transfer while resolving.

4. **Resolver has no overall deadline or cache size bound.**
   `Resolver.qml:91` supplies a socket timeout, but there is no QML timer that
   bounds the complete subprocess lifetime. Add a total deadline with an
   actionable retry state. Expired cache entries are ignored but never removed,
   and new episodes keep adding entries (`Resolver.qml:144`). Add a small
   count-bound cache and prune expired entries.

5. **Cast play blocks subsequent bridge commands.**
   `scripts/cast.py`, `Bridge.play()`, calls `block_until_active(timeout=12)`
   directly from the stdin command loop. Pause, stop and another selection can
   wait behind it. Move activation waiting off the command loop, with serialized
   device mutations and request generations so old workers cannot win a race.

## Performance opportunities

| Opportunity | Evidence and proposed change | Expected benefit / limit |
|---|---|---|
| Remove fixed restart wait | `Player.qml`, `restartAfterStop`, waits 400 ms. Start the requested replacement from confirmed process exit, retaining a bounded fallback. | Removes a deliberate wait on warm archive replacement; actual improvement must be measured. |
| Reuse mpv for archive → archive | `loadSource()` always destroys mpv, even when both sources use archive mode. Explore IPC `loadfile` with per-file resume options and state reset. | Avoid process, socket and MPRIS initialization; host URL extraction remains. Preserve mode-specific options and test against the installed mpv. |
| Shorten displayed startup delay | IPC connection starts on a 200 ms timer; playing state waits for property observations. Attempt connection immediately, then retain retries. | Faster UI confirmation; this alone does not make sound start earlier. |
| Avoid repeated archive extraction | Local playback resolves the source afresh through mpv; the existing resolver cache only helps casting. Explore a separate local-compatible resolved-source cache. | Helps replay and output transfers. Preserve HLS/DASH support, handle signed URL expiry, and retain page-URL fallback. |
| Faster remembered-device connection | Cold casting discovers for six seconds before connecting; see `Caster.qml:306` and `Bridge._connect_now()`. Investigate a validated cached endpoint with mDNS fallback. | Potentially reduces cold cast startup; device addresses change, so discovery must remain available. |
| Virtualize growing lists | Show/search/saved collections use Repeaters; every displayed row remains instantiated as more results load. | ListView/GridView delegate reuse can reduce UI memory and layout work for large collections. Profile before rewriting bounded home shelves. |
| Distinguish HTTP failures | Fetcher returns only success/failure; Api retries even permanent HTTP failures after 1.2 s. | Return status/failure class and retry transient errors only, improving failure feedback. |

Live channel switching already uses IPC `loadfile` in the same mpv process.
Keep that path. API concurrency limits, duplicate request sharing, bounded API
cache, adaptive schedule refresh and archive-only position polling are also
good existing choices.

## Feature shortlist

| Feature | User value | Relative effort |
|---|---|---|
| Play next / queue | Build an evening of archive listening; reorder and remove queued episodes. | Medium–large |
| Sleep timer | Stop after 15/30/60 minutes or at episode end, locally and when casting. | Small–medium |
| Listening history | Find recently heard shows, with replay and resume actions. Keep it local and clearable. | Small–medium |
| New episodes from saved shows | A “New from your shows” shelf with an opt-in, bounded refresh policy. | Medium |
| Loading stages and retry | Show Resolving / Connecting / Buffering, plus Cancel and Retry. Makes delays understandable and recoverable. | Medium |
| Library export/import | Back up and move saved items and resume positions through a validated format. | Small–medium |
| Language support | Add English translation catalog and live Omarchy language integration, then expand languages. | Medium |

Suggested order: playback intent/cancellation fixes → startup measurement and
event-driven restarts → sleep timer and queue → saved-show discovery.

## Verification and measurement plan

Executed successfully:

- `node tests/search.test.cjs`: 7 passed.
- Offscreen `/usr/lib/qt6/bin/qmltestrunner -input tests/qml -import tests/support`:
  22 passed, 0 failed. Test fixtures emit undefined-color warnings; clean those
  up so new warnings remain visible.

The current suites cover search and selected API/UI behavior, not Player,
Resolver, Service playback transitions or the cast bridge. Add focused tests
for the five priority findings before changing their state machines.

Record monotonic timestamps for selection, request dispatch, resolver finish,
process start/exit, IPC readiness, file-loaded and playback-ready. Keep diagnostics
bounded and omit signed media URLs. Playback-ready is a software proxy; verify
audible start separately.

Compare cold live start, live 1 ↔ 2, cold archive, archive → archive, archive
resume, local ↔ cast and rapid repeated selections. Use repeated trials and
report median and p95 with network conditions and cache state. Also test offline
recovery, missing dependencies, pause/cancel during startup and expired sources.
No end-to-end latency or memory benchmark was performed in this audit.
