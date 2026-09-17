import QtQuick
import QtTest
import "../../pages" as Pages
import "../../NtsApi.js" as NtsApi

TestCase {
  id: test
  name: "ArchiveSearch"
  visible: true
  width: 1080
  height: 760
  when: windowShown

  QtObject {
    id: fakeApi
    property var requests: []
    property var playbackRequests: []
    function search(query, types, limit, offset, callback) {
      if (!query) return
      requests.push({ query: query, type: types[0], limit: limit, offset: offset, callback: callback })
    }
    function episode(show, episode, callback) { playbackRequests.push(callback) }
  }
  QtObject {
    id: fakeService
    property var api: fakeApi
    property int scrollSpeed: 100
    property bool playing: false
    property var played: null
    property string archiveError: ""
    function isCurrentEpisode(episode) { return false }
    property var saved: []
    function isEpisodeSaved(episode) { return saved.some(function(item) { return NtsApi.sameEpisode(item, episode) }) }
    function toggleSaveEpisode(episode) {
      if (isEpisodeSaved(episode)) saved = saved.filter(function(item) { return !NtsApi.sameEpisode(item, episode) })
      else saved = saved.concat([episode])
    }
    function isShowSaved(alias) { return false }
    function playEpisode(episode, at) { played = episode; return true }
  }
  Pages.SearchPage {
    id: page
    anchors.fill: parent
    service: fakeService
    Rectangle { anchors.fill: parent; color: "#111111"; z: -1 }
  }

  function result(name) {
    var episode = NtsApi.emptyEpisode()
    episode.showAlias = "test"
    episode.episodeAlias = name
    episode.name = name
    episode.valid = true
    episode.audioUrl = "https://soundcloud.com/test/" + name
    return { shows: [], tracks: [], tags: [], episodes: [episode], received: 24, total: 72, popular: [] }
  }
  function request(type) {
    return fakeApi.requests.filter(function(r) { return r.type === type }).slice(-1)[0]
  }
  function init() {
    page.setQuery("")
    page.chooseFilter("all")
    fakeApi.requests = []
    fakeApi.playbackRequests = []
    fakeService.played = null
    fakeService.saved = []
  }

  function test_staleRepeatedQuery() {
    page.searchFor("reggae")
    var old = request("episode")
    page.searchFor("jazz")
    page.searchFor("reggae")
    old.callback(result("stale"), true)
    compare(page.episodes.length, 0)
    compare(page.pending, 4)
    request("episode").callback(result("fresh"), true)
    compare(page.episodes[0].name, "fresh")
    compare(page.pending, 3)
  }

  function test_paginationAndRetry() {
    page.searchFor("reggae")
    request("episode").callback(result("first"), true)
    page.chooseFilter("episodes")
    page.cursor = 0
    page.moveCursor(1)
    compare(request("episode").offset, 24)
    request("episode").callback(null, false)
    compare(page.episodes.length, 1)
    verify(page.groups.episodes.failed)
    page.loadGroup("episodes")
    compare(request("episode").offset, 24)
    request("episode").callback(result("second"), true)
    compare(page.episodes.length, 2)
    compare(page.cursor, 0)
    compare(page.groups.episodes.offset, 48)
  }

  function test_clearInvalidatesRequests() {
    page.searchFor("reggae")
    var old = request("episode")
    page.setQuery("")
    old.callback(result("stale"), true)
    compare(page.episodes.length, 0)
    compare(page.pending, 0)
  }

  function test_trackPlaybackHydratesEpisode() {
    page.searchFor("Desmond Decker")
    var track = { showAlias: "test", episodeAlias: "one", episodeName: "One", dateLabel: "", artworkSmall: "" }
    page.playTrack(track)
    compare(fakeService.played, null)
    fakeApi.playbackRequests[0](result("one").episodes[0], true)
    compare(fakeService.played.name, "one")
    page.playTrack(track)
    page.setQuery("jazz")
    fakeService.played = null
    fakeApi.playbackRequests[1](result("one").episodes[0], true)
    compare(fakeService.played, null)
  }

  function test_filtersAndSuggestionInput() {
    page.searchFor("Rege")
    verify(page.suggestions.indexOf("Reggae") >= 0)
    page.searchFor("Reggae")
    page.focusInput()
    verify(page.hasFocus)
    // Programmatic searches must replace the visible input as well.
    keyClick(Qt.Key_End)
    keyClick(Qt.Key_S)
    compare(page.query, "Reggaes")
    page.nextTab()
    compare(page.filter, "episodes")
  }
  function test_trackLayout() {
    page.searchFor("Desmond Decker")
    page.chooseFilter("tracks")
    var matches = result("unused")
    matches.episodes = []
    matches.tracks = []
    for (var i = 0; i < 24; i++) matches.tracks.push({ kind: "track",
      artist: "Desmond Decker", title: i % 2 ? "Israelites" : "It Mek",
      showAlias: "test", episodeAlias: "episode-" + i,
      episodeName: "Asher G's Caribbean Memories", dateLabel: "08 Feb 2026",
      artworkSmall: "", valid: true })
    matches.total = 197
    request("track").callback(matches, true)
    compare(page.shownTracks.length, 24)
    compare(page.cursorCount, 24)
    wait(50)
    var image = grabImage(page)
    compare(image.width, page.width)
    image.save("/tmp/nts-search-review.png")
    page.chooseFilter("episodes")
    compare(page.cursorCount, 0)
  }

  function track() {
    return { showAlias: "test", episodeAlias: "one", episodeName: "One", dateLabel: "", artworkSmall: "" }
  }

  function test_newEpisodePlayWinsOverPendingTrack() {
    page.searchFor("reggae")
    page.playTrack(track())
    page.playEpisode(result("newer").episodes[0])
    fakeApi.playbackRequests[0](result("one").episodes[0], true)
    compare(fakeService.played.name, "newer")
  }

  function test_selectionSurvivesEarlierSectionArrival() {
    page.searchFor("reggae")
    request("episode").callback(result("selected"), true)
    page.moveCursor(1)
    compare(page.cursorTarget().item.name, "selected")
    var matches = result("unused")
    matches.episodes = []
    var show = NtsApi.emptyShow()
    show.alias = "host"
    show.name = "Host"
    matches.shows = [show]
    request("show").callback(matches, true)
    compare(page.cursor, 1)
    compare(page.cursorTarget().kind, "episode")
    compare(page.cursorTarget().item.name, "selected")
  }

  function test_saveTrackLoadsAudioAndDoesNotToggleTwice() {
    page.searchFor("reggae")
    page.saveTrack(track())
    page.saveTrack(track())
    compare(fakeApi.playbackRequests.length, 1)
    compare(fakeService.saved.length, 0)
    fakeApi.playbackRequests[0](result("one").episodes[0], true)
    compare(fakeService.saved.length, 1)
    verify(fakeService.saved[0].audioUrl !== "")
    page.saveTrack(track())
    compare(fakeService.saved.length, 0)
    compare(fakeApi.playbackRequests.length, 1)
  }

  function test_saveFailureCanRetry() {
    page.searchFor("reggae")
    page.saveTrack(track())
    fakeApi.playbackRequests[0](null, false)
    compare(fakeService.saved.length, 0)
    compare(page.savingTracks["test/one"], undefined)
    verify(page.trackMessage.indexOf("Could not save") >= 0)
    page.saveTrack(track())
    fakeApi.playbackRequests[1](result("one").episodes[0], true)
    compare(fakeService.saved.length, 1)
  }

  function test_loadMoreButton() {
    page.searchFor("reggae")
    page.chooseFilter("episodes")
    var matches = result("first")
    matches.episodes = []
    for (var i = 0; i < 24; i++) matches.episodes.push(result("episode-" + i).episodes[0])
    request("episode").callback(matches, true)
    var button = findChild(page, "loadMoreEpisodes")
    var scroller = findChild(page, "searchResults")
    verify(button !== null)
    verify(button.visible)
    wait(50)
    scroller.contentY = scroller.contentHeight - scroller.height
    wait(50)
    mouseClick(button, button.width / 2, button.height / 2)
    compare(request("episode").offset, 24)
    verify(!button.enabledAction)
    var count = fakeApi.requests.length
    page.loadGroup("episodes")
    compare(fakeApi.requests.length, count)
    var last = result("last")
    last.received = 1
    last.total = 25
    request("episode").callback(last, true)
    compare(page.episodes.length, 25)
    verify(!button.visible)
  }

}
