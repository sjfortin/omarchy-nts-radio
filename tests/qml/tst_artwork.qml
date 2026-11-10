import QtQuick
import QtTest
import "../../components" as Components

TestCase {
  id: test
  name: "BoundedArtwork"
  when: windowShown
  visible: true
  width: 200
  height: 200
  property var store: Components.ArtworkStore
  Component { id: frameComponent; Components.ArtFrame { width: 100; height: 100 } }
  function normalized() {
    return "data:image/x-portable-pixmap;base64," + Qt.btoa("P6\n384 384\n255\n" + "rgb".repeat(384 * 384))
  }
  function finish(index, result, code) {
    var slot = findChild(store, "artworkSlot" + index)
    slot.output = JSON.stringify(result)
    var worker = findChild(slot, "artworkWorker" + index)
    worker.running = false
    worker.exited(code || 0, 0)
  }
  function init() {
    store.queue = []
    for (var i = 0; i < 2; i++) {
      var slot = findChild(store, "artworkSlot" + i)
      if (slot && slot.job) {
        slot.job.cancelled = true
        finish(i, { ok: false }, 1)
      }
    }
    store.cache = ({})
    store.cacheCharacters = 0
    store.maxJobs = 24
    store.maxOwners = 16
    store.maxCacheEntries = 24
    store.maxCacheCharacters = 14400000
  }
  function test_nativeImageNeverReceivesRemoteUrlAndNormalizedRasterRenders() {
    var frame = createTemporaryObject(frameComponent, test, { source: "https://media.ntslive.co.uk/normal.png" })
    var image = findChild(frame, "normalizedArtwork")
    compare(String(image.source), "")
    compare(store.activeCount, 1)
    finish(0, { ok: true, uri: normalized() })
    verify(String(image.source).indexOf("data:image/x-portable-pixmap;base64,") === 0)
    tryCompare(image, "status", Image.Ready)
    verify(image.sourceSize.width <= 384 && image.sourceSize.height <= 384)
    frame.active = false
    compare(String(image.source), "")
  }
  function test_requestAndOwnerBurstsAreBounded() {
    var accepted = 0
    for (var i = 0; i < 2000; i++)
      if (store.acquire("https://media.ntslive.co.uk/" + i + ".png", i).accepted) accepted++
    compare(accepted, 24)
    compare(store.activeCount, 2)
    compare(store.queue.length, 22)
    compare(store.pendingJobs, 24)
  }
  function test_duplicateOwnersCoalesceAndLastReleaseCancels() {
    var url = "https://media.ntslive.co.uk/shared.png"
    var accepted = 0
    for (var i = 1; i <= 2000; i++) if (store.acquire(url, i).accepted) accepted++
    compare(accepted, 16)
    compare(store.activeCount, 1)
    var slot = findChild(store, "artworkSlot0")
    var worker = findChild(slot, "artworkWorker0")
    for (var j = 1; j < 16; j++) store.release(url, j)
    compare(worker.running, true)
    store.release(url, 16)
    compare(worker.running, false)
    compare(slot.job.cancelled, true)
    finish(0, { ok: true, uri: normalized() })
    compare(store.pendingJobs, 0)
    compare(Object.keys(store.cache).length, 0)
  }
  function test_rejectedRemoteProtocolNeverReachesImageAndDoesNotRetryForever() {
    var frame = createTemporaryObject(frameComponent, test, { source: "https://media.ntslive.co.uk/bad.png" })
    var image = findChild(frame, "normalizedArtwork")
    finish(0, { ok: true, uri: "https://evil.invalid/image" })
    compare(String(image.source), "")
    compare(frame.artworkFailed, true)
    store.capacityAvailable()
    compare(store.pendingJobs, 0)
  }
  function test_sourceChangeCancelsOldTransferAndIgnoresItsResult() {
    var frame = createTemporaryObject(frameComponent, test, { source: "https://media.ntslive.co.uk/old.png" })
    frame.source = "https://media.ntslive.co.uk/new.png"
    var first = findChild(store, "artworkSlot0")
    compare(first.job.cancelled, true)
    finish(0, { ok: true, uri: normalized() })
    compare(frame.localArtwork, "")
    finish(1, { ok: true, uri: normalized() })
    verify(frame.localArtwork.length > 0)
  }
  function test_cacheCountAndByteBudgets() {
    store.maxCacheEntries = 2
    store.maxCacheCharacters = 1500
    for (var i = 0; i < 100; i++) store.remember("url" + i, "x".repeat(1000))
    verify(Object.keys(store.cache).length <= 2)
    verify(store.cacheCharacters <= 1500)
    compare(store.cacheCharacters, 1000)
  }
}
