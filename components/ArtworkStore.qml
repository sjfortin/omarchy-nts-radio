pragma Singleton
import QtQuick
import Quickshell.Io
import "../Model.js" as Model

// No remote Image sources. Two isolated workers normalize raster bytes, and
// the shared shell only retains bounded PPM data URIs. No per-request closures.
Item {
  id: root
  visible: false
  property int maxJobs: 24
  property int maxOwners: 16
  property int maxCacheEntries: 24
  property int maxCacheCharacters: 14400000
  property var queue: []
  property int activeCount: 0
  property var cache: ({})
  property int cacheCharacters: 0
  property double serial: 0
  property int nextOwner: 0
  readonly property int pendingJobs: queue.length + activeCount
  signal ready(string url, string uri)
  signal rejected(string url)
  signal capacityAvailable()

  function newOwner() { nextOwner++; return nextOwner }
  function pending(url) {
    for (var i = 0; i < queue.length; i++) if (queue[i].url === url) return queue[i]
    for (var j = 0; j < pool.count; j++) {
      var slot = pool.objectAt(j)
      if (slot && slot.job && !slot.job.cancelled && slot.job.url === url) return slot.job
    }
    return null
  }
  function acquire(source, owner) {
    var url = Model.safeArtwork(source)
    if (!url) return { accepted: false, uri: "" }
    var hit = cache[url]
    if (hit && Date.now() - hit.at < 1800000) {
      hit.used = ++serial
      return { accepted: true, uri: hit.uri }
    }
    var job = pending(url)
    if (job) {
      if (job.owners.indexOf(owner) >= 0) return { accepted: true, uri: "" }
      if (job.owners.length >= maxOwners) return { accepted: false, uri: "" }
      job.owners.push(owner)
      return { accepted: true, uri: "" }
    }
    if (pendingJobs >= maxJobs) return { accepted: false, uri: "" }
    queue = queue.concat([{ url: url, owners: [owner], cancelled: false }])
    pump()
    return { accepted: true, uri: "" }
  }
  function release(url, owner) {
    var job = pending(url)
    if (!job) return
    job.owners = job.owners.filter(function(value) { return value !== owner })
    if (job.owners.length) return
    job.cancelled = true
    queue = queue.filter(function(value) { return value !== job })
    for (var i = 0; i < pool.count; i++) {
      var slot = pool.objectAt(i)
      if (slot && slot.job === job) slot.cancel()
    }
    capacityAvailable()
  }
  function invalidate(url) {
    var entry = cache[url]
    if (!entry) return
    cacheCharacters -= entry.uri.length
    delete cache[url]
  }
  function remember(url, uri) {
    invalidate(url)
    cache[url] = { uri: uri, at: Date.now(), used: ++serial }
    cacheCharacters += uri.length
    var keys = Object.keys(cache).sort(function(a, b) { return root.cache[a].used - root.cache[b].used })
    while (keys.length > maxCacheEntries || cacheCharacters > maxCacheCharacters) invalidate(keys.shift())
  }
  function pump() {
    for (var i = 0; i < pool.count && queue.length; i++) {
      var slot = pool.objectAt(i)
      if (!slot || slot.job) continue
      var job = queue[0]
      queue = queue.slice(1)
      slot.job = job
      activeCount++
      slot.start(job.url)
    }
  }
  function completed(slot, payload, code) {
    var job = slot.job
    slot.job = null
    activeCount = Math.max(0, activeCount - 1)
    if (job && !job.cancelled && job.owners.length) {
      var result = null
      if (code === 0 && payload.length <= 600200) {
        try { result = JSON.parse(payload) } catch (e) {}
      }
      if (result && result.ok === true && typeof result.uri === "string"
          && result.uri.length <= 600000 && result.uri.indexOf("data:image/x-portable-pixmap;base64,") === 0) {
        remember(job.url, result.uri)
        ready(job.url, result.uri)
      } else rejected(job.url)
    }
    pump()
    capacityAvailable()
  }
  Instantiator {
    id: pool
    model: 2
    delegate: Item {
      id: slot
      required property int index
      objectName: "artworkSlot" + index
      property var job: null
      property string output: ""
      function start(url) {
        output = ""
        var path = decodeURIComponent(String(Qt.resolvedUrl("../scripts/artwork.py")).replace(/^file:\/\//, ""))
        worker.command = ["python3", path, url]
        worker.running = true
        guard.restart()
      }
      function cancel() { worker.running = false }
      Timer { id: guard; interval: 12000; onTriggered: slot.cancel() }
      Process {
        id: worker
        objectName: "artworkWorker" + slot.index
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: slot.output = String(text || "") }
        stderr: StdioCollector { waitForEnd: true }
        onExited: function(code, status) {
          guard.stop()
          var payload = slot.output
          slot.output = ""
          root.completed(slot, payload, code)
        }
      }
    }
  }
  Component.onDestruction: {
    queue = []
    for (var i = 0; i < pool.count; i++) {
      var slot = pool.objectAt(i)
      if (slot && slot.job) { slot.job.cancelled = true; slot.cancel() }
    }
  }
}
