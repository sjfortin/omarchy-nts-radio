import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: test
  name: "RequestAdmission"
  when: windowShown
  Component { id: apiComponent; Plugin.Api { concurrency: 0 } }
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: casterComponent; Plugin.Caster {} }
  property var api
  function init() { api = createTemporaryObject(apiComponent, test) }

  function test_curlFailedLaunchReleasesSlotAndRetries() {
    api.concurrency = 1
    var process = findChild(api, "curlRequest")
    verify(process !== null)
    process.failNextStart = true
    var replies = 0
    api.get("https://www.nts.live/recovery", function(text, ok) {
      compare(text, "recovered")
      verify(ok)
      replies++
    })
    compare(api.inFlight, 0)
    compare(api.retryQueue.length, 1)
    compare(replies, 0)
    tryCompare(process, "running", true)
    compare(api.inFlight, 1)
    process.stdout.streamFinished("recovered")
    process.running = false
    compare(api.inFlight, 1)
    process.exited(0, 0)
    compare(api.inFlight, 0)
    compare(replies, 1)
  }
  function test_distinctSlowRequestsStayBoundedAndRejectSynchronously() {
    var accepted = 0, rejected = 0
    for (var i = 0; i < 2000; i++) {
      if (api.get("https://www.nts.live/test/" + i, function(text, ok, reason) {
        if (!ok && reason === "busy") rejected++
      })) accepted++
    }
    compare(accepted, 32)
    compare(rejected, 1968)
    compare(api.pendingJobs, 32)
    compare(api.queue.length, 32)
    compare(api.deferredReplies.length, 0)
  }
  function test_duplicateFanOutIsCapped() {
    var rejected = 0
    for (var i = 0; i < 2000; i++)
      api.get("https://www.nts.live/one", function(text, ok, reason) { if (reason === "busy") rejected++ })
    compare(api.queue.length, 1)
    compare(api.queue[0].callbacks.length, 8)
    compare(rejected, 1992)
  }
  function test_cacheHitsCannotFloodDeferredCallbacks() {
    var rejected = 0, replies = 0
    for (var i = 0; i < 2000; i++) {
      var url = "https://www.nts.live/cached/" + i
      api.store(url, "cached")
      api.get(url, function(text, ok, reason) { if (ok) replies++; else if (reason === "busy") rejected++ })
    }
    compare(api.deferredReplies.length, 32)
    compare(rejected, 1968)
    compare(replies, 0)
    tryCompare(api, "pendingJobs", 0)
    compare(replies, 32)
  }
  function test_retryAndActiveSlotsCountTowardAdmission() {
    api.maxPendingJobs = 4
    api.inFlight = 3
    verify(api.get("https://www.nts.live/wait", function() {}))
    compare(api.get("https://www.nts.live/reject", function() {}), false)
    var slot = { job: { url: "https://www.nts.live/retry", kind: "", epoch: -1, tries: 0, callbacks: [] } }
    api.slotFinished(slot, "", false, 503)
    compare(api.pendingJobs, 4)
    compare(api.retryQueue.length, 1)
    compare(api.get("https://www.nts.live/still-reject", function() {}), false)
  }
  function test_ipcEpisodeHasOnePendingLookupAndBusyResult() {
    var service = createTemporaryObject(serviceComponent, test)
    service.libraryLoaded = true
    var client = findChild(service, "apiClient")
    client.concurrency = 0
    compare(service.requestIpcEpisode("show", "episode0"), "loading show/episode0")
    for (var i = 0; i < 2000; i++) compare(service.requestIpcEpisode("show", "episode" + i), "busy")
    compare(client.queue.length, 1)
    compare(client.queue[0].callbacks.length, 1)
    service.pause()
    client.deliver(client.queue[0], "", false)
    compare(service.ipcEpisodePending, false)
    compare(service.archiveError, "")
    compare(service.archiveEpisode, null)
  }
  function test_ipcApiRejectionRetainsNoPendingWork() {
    var service = createTemporaryObject(serviceComponent, test)
    var client = findChild(service, "apiClient")
    client.concurrency = 0
    client.maxPendingJobs = 0
    for (var i = 0; i < 2000; i++) compare(service.requestIpcEpisode("show", "episode" + i), "busy")
    compare(service.ipcEpisodePending, false)
    compare(client.pendingJobs, 0)
    compare(service.archiveError, "Request queue busy — try again")
  }
  function test_deviceBurstSendsOneDiscoveryWithoutTimerExtension() {
    var caster = createTemporaryObject(casterComponent, test)
    var process = findChild(caster, "bridge")
    compare(caster.discover(), "queued")
    for (var i = 0; i < 2000; i++) compare(caster.discover(), "busy")
    compare(process.writes.length, 0)
    caster.handleLine(JSON.stringify({ event: "ready" }))
    compare(process.writes.length, 1)
    compare(JSON.parse(process.writes[0]).cmd, "discover")
    for (var j = 0; j < 2000; j++) compare(caster.discover(), "busy")
    compare(process.writes.length, 1)
    caster.handleLine(JSON.stringify({ event: "devices", devices: [] }))
    compare(caster.discover(), "started")
    compare(process.writes.length, 2)
  }
}
