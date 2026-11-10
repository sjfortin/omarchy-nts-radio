import QtQuick
import QtTest
import "../.." as Plugin
import "../../Library.js" as Library
import "../../Model.js" as Model

TestCase {
  id: test
  name: "Playback"
  when: windowShown
  width: 800
  height: 600
  visible: true
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: resolverComponent; Plugin.Resolver {} }
  Component { id: playerComponent; Plugin.Player {} }
  Component { id: casterComponent; Plugin.Caster {} }

  property var service
  property var caster
  property var player
  property var resolver

  function episode(name) {
    return { valid: true, showAlias: "show", episodeAlias: name, name: name,
      audioUrl: "https://soundcloud.com/nts/" + name, artworkSmall: "", artworkLarge: "" }
  }
  function init() {
    service = createTemporaryObject(serviceComponent, test)
    verify(service !== null)
    service.libraryLoaded = true
    caster = findChild(service, "caster")
    player = findChild(service, "player")
    resolver = findChild(service, "resolver")
  }
  function finishProcess(process, code) { process.running = false; process.exited(code || 0, 0) }

  function test_latestCastSelectionWins() {
    service.outputMode = "cast"
    service.playEpisode(episode("a"), 0)
    var process = findChild(resolver, "resolve")
    verify(resolver.busy)
    service.playEpisode(episode("b"), 0)
    compare(resolver.queuedSource, episode("b").audioUrl)
    finishProcess(process, 1)
    tryCompare(resolver, "pendingSource", episode("b").audioUrl)
    compare(process.command[process.command.length - 1], episode("b").audioUrl)
  }
  function test_pauseCancelsResolutionAndLateReply() {
    service.outputMode = "cast"
    service.playEpisode(episode("a"), 123)
    service.pause()
    compare(service.resolvingCast, false)
    compare(service.loading, false)
    resolver.resolved(episode("a").audioUrl, "https://example.test/a.mp3", "audio/mpeg")
    compare(caster.wanted, false)
    compare(service.archiveNeedsLoad, true)
    compare(service.positionSec, 123)
  }
  function test_cachedResolutionCannotBeatCancellation() {
    var local = createTemporaryObject(resolverComponent, test)
    var count = 0
    local.resolved.connect(function() { count++ })
    local.store(episode("a").audioUrl, "https://example.test/a.mp3", "audio/mpeg")
    local.start(episode("a").audioUrl)
    local.abort()
    wait(1)
    compare(count, 0)
  }
  function test_pausedOutputTransferStaysPaused() {
    service.playEpisode(episode("a"), 200)
    service.pause()
    service.setOutput("cast", "speaker", "Speaker")
    compare(service.loading, false)
    compare(service.playbackRequested, false)
    compare(service.archiveNeedsLoad, true)
    compare(service.positionSec, 200)
    service.play()
    compare(service.resolvingCast, true)
    compare(service.pendingResumeSec, 200)
  }
  function test_resolverDeadlineAndCacheBound() {
    var local = createTemporaryObject(resolverComponent, test, { deadlineMs: 10, maxCacheEntries: 2 })
    var failures = 0
    local.failed.connect(function() { failures++ })
    local.start(episode("a").audioUrl)
    tryCompare(local, "generation", 2)
    compare(failures, 1)
    var process = findChild(local, "resolve")
    verify(process.command[1].indexOf("finite_helper.py") >= 0)
    finishProcess(process, 1)
    compare(local.busy, false)
    local.start(episode("b").audioUrl)
    verify(local.busy)
    finishProcess(process, 1)
    compare(local.busy, false)
    local.store("a", "one", "audio/mpeg")
    local.store("b", "two", "audio/mpeg")
    local.store("c", "three", "audio/mpeg")
    compare(Object.keys(local.cache).length, 2)
  }
  function test_legacyLiveRecoveryDoesNotReload() {
    var local = createTemporaryObject(casterComponent, test)
    var recovered = null
    local.sessionRecovered.connect(function(session) { recovered = session })
    local.adopting = true
    local.handleLine(JSON.stringify({ event: "status", connected: true,
      state: "PLAYING", content: Model.streamUrl(2), volume: 40 }))
    compare(recovered.channel, 2)
    compare(local.wanted, true)
    compare(findChild(local, "bridge").writes.length, 0)
  }
  function test_archiveRecoveryAndUnrelatedMusic() {
    var local = createTemporaryObject(casterComponent, test)
    local.adopting = true
    local.handleLine(JSON.stringify({ event: "status", connected: true, state: "PAUSED",
      content: "https://cdn.test/audio", position: 123, duration: 3600,
      session: { mode: "archive", episode: episode("a") } }))
    compare(local.wanted, true)
    compare(local.paused, true)
    compare(local.positionSec, 123)
    var unrelated = createTemporaryObject(casterComponent, test)
    unrelated.adopting = true
    unrelated.handleLine(JSON.stringify({ event: "status", connected: true,
      state: "PLAYING", content: "https://other.test/music" }))
    compare(unrelated.wanted, false)
    compare(unrelated.adopting, false)
  }
  function test_recoveryRestoresServiceArchive() {
    service.recoveryPending = true
    caster.adopting = true
    caster.handleLine(JSON.stringify({ event: "status", connected: true, state: "PLAYING",
      content: "https://cdn.test/audio", position: 300, duration: 3600,
      session: { mode: "archive", episode: episode("a") } }))
    compare(service.outputMode, "cast")
    compare(service.archiveEpisode.episodeAlias, "a")
    compare(service.positionSec, 300)
    compare(service.playing, true)
  }
  function test_sleepTimerCancelsPendingPlay() {
    service.outputMode = "cast"
    service.playEpisode(episode("a"), 0)
    service.sleepDeadlineMs = Date.now() - 1
    service.updateSleepTimer()
    compare(service.resolvingCast, false)
    compare(service.sleepDeadlineMs, 0)
    compare(service.playbackRequested, false)
  }
  function test_queueCompletionAndSleepAtEnd() {
    service.enqueueEpisode(episode("a"), false)
    service.enqueueEpisode(episode("b"), false)
    verify(service.playNextQueued())
    compare(service.archiveEpisode.episodeAlias, "a")
    compare(service.queue.length, 1)
    service.setSleepAtEnd()
    service.episodeFinished()
    wait(1)
    compare(service.queue.length, 1)
    compare(service.sleepAtEpisodeEnd, false)
    service.episodeFinished()
    wait(1)
    compare(service.archiveEpisode.episodeAlias, "b")
    compare(service.queue.length, 0)
  }
  function test_archiveReuseUsesOneProcessAndResume() {
    var local = createTemporaryObject(playerComponent, test)
    local.loadSource("archive", episode("a").audioUrl, 0)
    var process = findChild(local, "mpv")
    process.started()
    tryCompare(local, "ipcAvailable", true)
    local.loadSource("archive", episode("b").audioUrl, 99)
    compare(process.running, true)
    compare(local.processActive, true)
    compare(local.rejoining, true)
    compare(local.startPositionSec, 99)
    local.handleLine(JSON.stringify({ event: "file-loaded" }))
    compare(local.rejoining, false)
  }
  function test_cancelAfterResolutionBeforeSpeakerConnection() {
    service.outputMode = "cast"
    service.playEpisode(episode("a"), 77)
    resolver.resolved(episode("a").audioUrl, "https://cdn.test/audio", "audio/mpeg")
    compare(caster.playWhenConnected, true)
    service.pause()
    compare(caster.playWhenConnected, false)
    compare(caster.wanted, false)
    compare(service.positionSec, 77)
  }
  function test_archiveEofAdvancesOnlyAfterProcessExit() {
    var local = createTemporaryObject(playerComponent, test)
    var completed = 0
    local.finished.connect(function() { completed++ })
    local.loadSource("archive", episode("a").audioUrl, 0)
    local.handleLine(JSON.stringify({ event: "end-file", reason: "eof" }))
    compare(completed, 0)
    finishProcess(findChild(local, "mpv"), 0)
    compare(completed, 1)
    compare(local.processActive, false)
  }
  function test_userActionCancelsRecovery() {
    service.recoveryPending = true
    caster.adopting = true
    service.pause()
    caster.handleLine(JSON.stringify({ event: "status", connected: true, state: "PLAYING",
      content: Model.streamUrl(1), session: { mode: "live", channel: 1 } }))
    compare(service.outputMode, "local")
    compare(caster.wanted, false)
  }
  function test_permanentHttpErrorDoesNotRetry() {
    var api = findChild(service, "apiClient")
    api.concurrency = 0
    var replies = 0
    api.get("https://www.nts.live/not-found", function(text, ok) { replies++; compare(ok, false) })
    var slot = { job: api.queue[0] }
    api.queue = []
    api.slotFinished(slot, "", false, 404)
    compare(replies, 1)
    compare(api.retryQueue.length, 0)
  }

  function test_playSelectedQueueItemRemovesIt() {
    service.enqueueEpisode(episode("a"), false)
    service.enqueueEpisode(episode("b"), false)
    verify(service.playQueued(1))
    compare(service.archiveEpisode.episodeAlias, "b")
    compare(service.queue.length, 1)
    compare(service.queue[0].episodeAlias, "a")
  }
  function test_resolverFailedStartThenSuccessfulRetry() {
    var local = createTemporaryObject(resolverComponent, test, { deadlineMs: 30 })
    var process = findChild(local, "resolve")
    var failures = 0
    var successes = 0
    local.failed.connect(function() { failures++ })
    local.resolved.connect(function() { successes++ })
    process.failNextStart = true
    local.start(episode("a").audioUrl)
    compare(local.busy, false)
    compare(local.pendingSource, "")
    compare(local.resolveOutput, "")
    compare(failures, 1)
    wait(50)
    compare(failures, 1) // Failed-start timer was stopped.
    local.start(episode("b").audioUrl)
    verify(local.busy)
    local.resolveOutput = "mp3\thttps://cdn.test/retry.mp3"
    finishProcess(process, 0)
    compare(local.busy, false)
    compare(successes, 1)
    compare(local.resolveOutput, "")
  }
  function test_resolverSupersededStartingRequestPreservesLatest() {
    var local = createTemporaryObject(resolverComponent, test)
    var process = findChild(local, "resolve")
    process.deferStart = true
    var failures = 0
    var resolvedSource = ""
    local.failed.connect(function() { failures++ })
    local.resolved.connect(function(source) { resolvedSource = source })
    local.start(episode("a").audioUrl)
    local.resolveOutput = "stale"
    local.start(episode("b").audioUrl)
    tryCompare(local, "pendingSource", episode("b").audioUrl)
    compare(failures, 0)
    compare(local.resolveOutput, "")
    process.started()
    local.resolveOutput = "mp3\thttps://cdn.test/latest.mp3"
    finishProcess(process, 0)
    compare(resolvedSource, episode("b").audioUrl)
    compare(local.busy, false)
  }
  function test_importFailedStartThenSuccessfulRetry() {
    service.importDeadlineMs = 30
    var process = findChild(service, "importReader")
    process.failNextStart = true
    verify(service.previewImport("/tmp/failure.json"))
    compare(service.transferBusy, false)
    compare(service.importActive, false)
    compare(service.importBody, "")
    compare(service.importPreview, null)
    verify(service.libraryTransferMessage.indexOf("Could not start") >= 0)
    verify(service.previewImport("/tmp/retry.json"))
    verify(service.transferBusy)
    service.importBody = Library.serialize(Library.emptyLibrary())
    finishProcess(process, 0)
    compare(service.transferBusy, false)
    verify(service.importPreview !== null)
    var message = service.libraryTransferMessage
    wait(50)
    compare(service.libraryTransferMessage, message)
    compare(service.importBody, "")
  }
  function test_importDeadlineReleasesBusyAndAllowsRetry() {
    service.importDeadlineMs = 10
    verify(service.previewImport("/tmp/stalled.json"))
    var process = findChild(service, "importReader")
    compare(process.command[2], "import")
    verify(process.command[1].indexOf("finite_helper.py") >= 0)
    verify(!service.previewImport("/tmp/second.json"))
    tryCompare(process, "running", false)
    compare(service.transferBusy, true) // Keep admission closed until cleanup exits.
    finishProcess(process, 1)
    compare(service.transferBusy, false)
    compare(service.importBody, "")
    compare(service.importPreview, null)
    verify(service.previewImport("/tmp/retry.json"))
    finishProcess(process, 1)
    compare(service.transferBusy, false)
  }
  function test_importAppliesOnlyAfterBackup() {
    service.enqueueEpisode(episode("old"), false)
    var imported = Library.enqueue(Library.emptyLibrary(), episode("new"), false)
    service.importPreview = imported
    service.applyImport()
    compare(service.queue[0].episodeAlias, "old")
    tryCompare(service, "transferBusy", false)
    compare(service.queue[0].episodeAlias, "new")
  }
  function test_followedDiscoveryIsOptInAndDropsLateResponses() {
    var api = findChild(service, "apiClient")
    api.concurrency = 0
    service.library = Library.toggleShow(service.library, { alias: "show", name: "Show" }, Date.now())
    service.refreshFollowed()
    compare(api.queue.length, 0)
    service.followSavedShows = true
    compare(api.queue.length, 1)
    compare(service.refreshingFollowed, true)
    service.followSavedShows = false
    api.deliver(api.queue[0], "{}", true)
    compare(service.followedEpisodes.length, 0)
    compare(service.refreshingFollowed, false)
  }
  function test_pausingArchiveLoadCancelsProcessAndRetainsOffset() {
    var local = createTemporaryObject(playerComponent, test)
    local.loadSource("archive", episode("a").audioUrl, 87)
    local.pause()
    compare(local.wanted, false)
    compare(local.paused, true)
    compare(local.startPositionSec, 87)
    compare(findChild(local, "mpv").running, false)
  }

}
