import QtQuick
import QtTest
import "../.." as Plugin
import "../../pages" as Pages
import "../../components" as Components
import "../../NtsApi.js" as NtsApi

TestCase {
  id: test
  name: "AuditFixes"
  visible: true
  width: 800
  height: 600
  when: windowShown

  Plugin.Api {
    id: api
    concurrency: 0
  }

  QtObject {
    id: fakeApi
    property var episodeCallbacks: []
    function episode(show, slot, callback) { episodeCallbacks.push(callback) }
    function show(show, callback) { callback(null, false) }
    function tracklist(show, slot, callback) { callback(null, false) }
  }

  QtObject {
    id: fakeService
    property var api: fakeApi
    property int scrollSpeed: 100
    property bool playing: false
    property bool ytdlAvailable: true
    property var library: ({ shows: [], episodes: [], resume: [] })
    function isEpisodeSaved(episode) { return false }
    function isCurrentEpisode(episode) { return false }
    function resumePositionFor(episode) { return 0 }
  }

  Pages.EpisodePage {
    id: episodePage
    width: 800
    height: 600
    service: fakeService
  }

  Pages.SavedPage {
    id: savedPage
    width: 800
    height: 600
    active: false
    visible: false
    service: fakeService
  }

  Components.SeekBar {
    id: seekBar
    width: 200
    position: 50
    duration: 100
    accessibleName: "Test volume"
    onSeeked: function(value) { lastSeek = value }
    property real lastSeek: -1
  }

  function init() {
    api.queue = []
    api.retryQueue = []
    api.cache = ({})
    api.cacheCount = 0
    api.cacheBytes = 0
    fakeApi.episodeCallbacks = []
    episodePage.episode = null
    fakeService.library = ({ shows: [], episodes: [], resume: [] })
  }

  function test_duplicateRequestsShareAJob() {
    var calls = []
    api.get("https://www.nts.live/test", function(text, ok) { calls.push("first") })
    api.get("https://www.nts.live/test", function(text, ok) { calls.push("second") })
    compare(api.queue.length, 1)
    compare(api.queue[0].callbacks.length, 2)
    api.deliver(api.queue[0], "ok", true)
    compare(calls.join(","), "first,second")
  }

  function test_newSearchDropsQueuedOldSearchOnly() {
    api.get("https://www.nts.live/old", function() {}, { kind: "search" })
    api.get("https://www.nts.live/detail", function() {})
    compare(api.queue.length, 2)
    api.invalidateSearch()
    compare(api.queue.length, 1)
    compare(api.queue[0].url, "https://www.nts.live/detail")
    api.get("https://www.nts.live/new", function() {}, { kind: "search" })
    compare(api.queue[1].epoch, api.searchEpoch)
  }

  function test_failedEpisodeDetailsCanRetry() {
    var item = NtsApi.emptyEpisode()
    item.showAlias = "test"
    item.episodeAlias = "broadcast"
    item.name = "Broadcast"
    episodePage.episode = item
    compare(fakeApi.episodeCallbacks.length, 1)
    fakeApi.episodeCallbacks[0](null, false)
    compare(episodePage.detailFailed, true)
    compare(episodePage.detailLoaded, false)
    episodePage.fetchDetails("test", "broadcast")
    compare(fakeApi.episodeCallbacks.length, 2)
    fakeApi.episodeCallbacks[1](item, true)
    compare(episodePage.detailFailed, false)
    compare(episodePage.detailLoaded, true)
  }

  function test_savedShelfLoadsInBatchesWithKeyboard() {
    var shows = []
    for (var i = 0; i < 100; i++)
      shows.push({ alias: "show" + i, name: "Show " + i,
        artworkSmall: "", artworkLarge: "", location: "" })
    fakeService.library = ({ shows: shows, episodes: [], resume: [] })
    compare(savedPage.visibleShows.length, 48)
    savedPage.cursor = 47
    savedPage.moveCursor(1)
    compare(savedPage.visibleShows.length, 96)
    compare(savedPage.cursor, 48)
  }

  function test_seekBarAcceptsArrowKey() {
    seekBar.forceActiveFocus()
    keyClick(Qt.Key_Right)
    compare(seekBar.lastSeek, 55)
  }
}
