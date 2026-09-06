import QtQuick

import "NtsApi.js" as NtsApi

// The plugin's whole relationship with the NTS API.
//
// Pages never touch the network. They ask for a URL built by NtsApi.js and get
// a parsed result back through a callback; everything between — queueing,
// concurrency, timeouts, retries, caching, and the fact that a response is a
// subprocess's stdout — lives here.
//
// Two rules hold this together:
//   * a cache miss or a cache failure must never prevent a fresh request, and
//   * a failed request must never throw. Callers get ok=false and a null
//     payload, which is a state the UI can render.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  // Enough to fill a home page in one pass without opening a dozen sockets
  // against nts.live the moment a window appears.
  property int concurrency: 3
  property int timeoutSeconds: 15

  // Metadata changes on the order of hours; five minutes keeps a session
  // snappy without ever showing something meaningfully stale. Search results
  // get their own shorter life because a query is cheap to redo and a user
  // retyping the same thing usually wants it again, not from a minute ago.
  property int cacheTtlMs: 300000
  property int searchCacheTtlMs: 120000

  // Bounded so a long session cannot grow the cache without limit. Entries
  // are evicted oldest-first, which for a browser is also least-recently-shown.
  //
  // Two bounds, because a count on its own is not one. NTS answers a show page
  // carrying its first page of episodes in about 40KB and a search in about
  // 16KB, so 120 entries is somewhere between three and five megabytes of raw
  // JSON — held as QML strings, which are UTF-16, and held for the life of the
  // shell rather than the life of the window, because this object belongs to
  // the service. The byte ceiling is the one that actually describes the cost.
  property int maxCacheEntries: 120
  property int maxCacheBytes: 2000000

  // url -> { text, atMs }. Deliberately a plain object and deliberately not
  // bound to anything in the UI: nothing should re-render because a cache
  // entry landed.
  property var cache: ({})
  property int cacheCount: 0
  property int cacheBytes: 0

  // Pending work, oldest first: { url, callback, ttl, tries }
  property var queue: []
  property int inFlight: 0

  // True while anything at all is outstanding. Pages use it for a single
  // quiet loading state rather than tracking their own requests.
  readonly property bool busy: inFlight > 0 || queue.length > 0

  // ------------------------------------------------------------------ cache

  function cached(url, ttl) {
    var entry = cache[url]
    if (!entry) return null
    var life = ttl === undefined ? cacheTtlMs : ttl
    if (life <= 0) return null
    if (Date.now() - entry.atMs > life) return null
    return entry.text
  }

  function store(url, text) {
    if (text === "") return
    if (cache[url]) {
      cacheCount--
      cacheBytes -= cache[url].text.length
    }
    cacheCount++
    cacheBytes += text.length
    cache[url] = { text: text, atMs: Date.now() }
    if (cacheCount <= maxCacheEntries && cacheBytes <= maxCacheBytes) return

    // Oldest first, which for a browser is also least-recently-shown. Evicting
    // a quarter of the entries in one pass keeps this amortised rather than
    // running on every insert once a cap is reached, and the loop keeps going
    // while the byte ceiling is still exceeded — one very large response should
    // not be able to sit above the limit just because the count is fine.
    var entries = []
    for (var key in cache) entries.push({ key: key, atMs: cache[key].atMs })
    entries.sort(function(a, b) { return a.atMs - b.atMs })

    var drop = Math.max(1, Math.floor(entries.length / 4))
    for (var i = 0; i < entries.length; i++) {
      if (i >= drop && cacheCount <= maxCacheEntries && cacheBytes <= maxCacheBytes) break
      cacheBytes -= cache[entries[i].key].text.length
      cacheCount--
      delete cache[entries[i].key]
    }
    if (cacheCount <= 0) {
      // Belt and braces: an empty table has no bytes in it, whatever the
      // running total says.
      cacheCount = 0
      cacheBytes = 0
    }
  }

  // ------------------------------------------------------------- scheduling

  // The one entry point. `callback(text, ok)` is always called exactly once,
  // on the next turn at the earliest — never synchronously from inside get(),
  // so a caller can rely on its own state being settled first even on a cache
  // hit.
  function get(url, callback, options) {
    var target = String(url || "")
    if (target === "" || typeof callback !== "function") return

    var settings = options && typeof options === "object" ? options : {}
    var ttl = settings.ttl === undefined ? cacheTtlMs : settings.ttl

    if (settings.force !== true) {
      var hit = cached(target, ttl)
      if (hit !== null) {
        Qt.callLater(function() { callback(hit, true) })
        return
      }
    }

    var next = queue.slice()
    next.push({ url: target, callback: callback, ttl: ttl, tries: 0 })
    queue = next
    pump()
  }

  // Convenience wrappers so a page names what it wants rather than a URL, and
  // parsing lives next to fetching instead of in a page's callback.
  function getJson(url, parse, callback, options) {
    get(url, function(text, ok) {
      if (!ok) { callback(null, false); return }
      var parsed = null
      try {
        parsed = parse(text)
      } catch (e) {
        // A parser that throws on a malformed body is a bug, but it must not
        // take the window down with it.
        console.warn("nts-radio: parse failed for " + url + ": " + e)
        parsed = null
      }
      callback(parsed, parsed !== null)
    }, options)
  }

  function search(query, types, limit, offset, callback) {
    var url = NtsApi.searchUrl(query, types, limit, offset)
    getJson(url, NtsApi.parseSearch, callback, { ttl: searchCacheTtlMs })
  }

  function show(alias, callback) {
    var url = NtsApi.showUrl(alias)
    if (url === "") { Qt.callLater(function() { callback(null, false) }); return }
    getJson(url, NtsApi.parseShow, callback)
  }

  function showEpisodes(alias, limit, offset, callback) {
    var url = NtsApi.showEpisodesUrl(alias, limit, offset)
    if (url === "") { Qt.callLater(function() { callback(null, false) }); return }
    getJson(url, NtsApi.parseEpisodeList, callback)
  }

  function episode(showAlias, episodeAlias, callback) {
    var url = NtsApi.episodeUrl(showAlias, episodeAlias)
    if (url === "") { Qt.callLater(function() { callback(null, false) }); return }
    getJson(url, NtsApi.parseEpisode, callback)
  }

  function tracklist(showAlias, episodeAlias, callback) {
    var url = NtsApi.tracklistUrl(showAlias, episodeAlias)
    if (url === "") { Qt.callLater(function() { callback(null, false) }); return }
    getJson(url, NtsApi.parseTracklist, callback)
  }

  function collection(which, limit, callback) {
    getJson(NtsApi.collectionUrl(which, limit), NtsApi.parseEpisodeList, callback)
  }

  // ------------------------------------------------------------------- pool

  function pump() {
    while (queue.length > 0 && inFlight < concurrency) {
      var slot = freeSlot()
      if (!slot) return
      var next = queue.slice()
      var job = next.shift()
      queue = next
      slot.job = job
      inFlight++
      if (!slot.start(job.url)) {
        // start() refuses only on an empty URL or a busy slot, neither of
        // which should reach here — but a job that never completes would
        // hang its caller forever, so finish it rather than drop it.
        slot.job = null
        inFlight--
        deliver(job, "", false)
      }
    }
  }

  function freeSlot() {
    for (var i = 0; i < pool.count; i++) {
      var slot = pool.objectAt(i)
      if (slot && !slot.busy && !slot.job) return slot
    }
    return null
  }

  function slotFinished(slot, text, ok) {
    var job = slot.job
    slot.job = null
    inFlight = Math.max(0, inFlight - 1)
    if (!job) return

    if (ok) {
      store(job.url, text)
      deliver(job, text, true)
      pump()
      return
    }

    // One retry, and only for a transport-level failure — a network that
    // dropped mid-request is worth asking again, a 404 is not, and curl -f
    // has already collapsed both into the same exit code so the retry is
    // bounded rather than clever. Anything past that is reported.
    if (job.tries < 1) {
      job.tries++
      retryQueue.push(job)
      retryTimer.restart()
      pump()
      return
    }

    deliver(job, "", false)
    pump()
  }

  function deliver(job, text, ok) {
    try {
      job.callback(text, ok)
    } catch (e) {
      console.warn("nts-radio: request callback threw: " + e)
    }
  }

  property var retryQueue: []

  Timer {
    id: retryTimer
    interval: 1200
    onTriggered: {
      if (root.retryQueue.length === 0) return
      var next = root.queue.slice()
      for (var i = 0; i < root.retryQueue.length; i++) next.push(root.retryQueue[i])
      root.retryQueue = []
      root.queue = next
      root.pump()
    }
  }

  Instantiator {
    id: pool
    model: root.concurrency
    active: true

    delegate: Fetcher {
      id: slot
      // Set while this slot owns a job; also what marks it busy in the window
      // between being handed work and the Process actually starting.
      property var job: null
      timeoutSeconds: root.timeoutSeconds
      onFinished: function(text, ok) { root.slotFinished(slot, text, ok) }
    }
  }

  // This object belongs to the service, so it outlives every window that uses
  // it and is destroyed only when the plugin is disabled or the shell goes
  // down. Dropping in-flight work here stops a callback firing into a page —
  // or a slot — that is already gone.
  Component.onDestruction: {
    queue = []
    retryQueue = []
    for (var i = 0; i < pool.count; i++) {
      var slot = pool.objectAt(i)
      if (!slot) continue
      slot.job = null
      slot.abort()
    }
  }
}
