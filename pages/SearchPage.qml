import QtQuick
import qs.Commons

import "../components" as Nts
import "../NtsApi.js" as NtsApi
import "../Search.js" as Search

// Independently paginated archive indexes. Request generations prevent stale
// callbacks from replacing a newer search, including repeated queries.
Item {
  id: root

  property var service: null
  property bool active: true
  property color ink: Color.foreground

  signal showRequested(string alias)
  signal episodeRequested(var episode)

  readonly property var api: service ? service.api : null

  property string query: ""
  property var shows: []
  property var episodes: []
  property var tracks: []
  property var tags: []
  property var groups: ({})
  property int generation: 0
  property string filter: "all"
  readonly property bool hasFocus: field.hasFocus
  readonly property int total: Object.keys(groups).reduce(function(n, key) {
    return n + groups[key].total
  }, 0)
  readonly property var suggestions: Search.genreSuggestions(query)

  function nextTab() {
    var tabs = ["all", "episodes", "tracks", "shows", "tags"]
    chooseFilter(tabs[(tabs.indexOf(filter) + 1) % tabs.length])
  }

  function chooseFilter(value) {
    filter = value
    cursor = -1
    scroller.contentY = 0
  }

  function searchFor(value) {
    field.text = value
    setQuery(value)
    debounce.stop()
    run()
  }

  function groupLabel(key) {
    var group = groups[key]
    if (!group) return ""
    if (group.loading) return "Loading…"
    return root[key].length + " of " + group.total
  }

  function canLoad(key) {
    var group = groups[key]
    return !!group && (group.failed || group.more)
  }
  property var popular: []

  property int pending: 0
  property bool failed: false
  // The query the currently displayed results belong to.
  property string resolvedQuery: ""

  readonly property var shownShows: filter === "all" || filter === "shows" ? shows : []
  readonly property var shownEpisodes: filter === "all" || filter === "episodes" ? episodes : []
  readonly property var shownTracks: filter === "all" || filter === "tracks" ? tracks : []
  readonly property var shownTags: filter === "all" || filter === "tags" ? tags : []

  readonly property bool searching: pending > 0
  readonly property bool hasResults: shows.length > 0 || episodes.length > 0
    || tracks.length > 0 || tags.length > 0
  readonly property bool showEmpty: !searching && query !== ""
    && resolvedQuery === query && !hasResults && !failed

  function focusInput() {
    cursor = -1
    field.focusInput()
  }

  // ---- keyboard cursor
  //
  // One index walks all four groups in the order they are drawn, so Down out
  // of the last episode lands on the first track rather than stopping at a
  // section boundary. The offsets are derived rather than stored so they can
  // never disagree with what is on screen.

  property int cursor: -1

  readonly property int episodesOffset: shownShows.length
  readonly property int tracksOffset: episodesOffset + shownEpisodes.length
  readonly property int tagsOffset: tracksOffset + shownTracks.length
  readonly property int cursorCount: tagsOffset + shownTags.length

  // -1 is a real position, not "unset": it means the caret is still in the
  // search field. Moving in and out of the results moves keyboard ownership
  // with it, which is what makes bare-key shortcuts (p, b) act on the
  // selection instead of being typed into the query.
  function moveCursor(delta) {
    if (cursorCount === 0) return
    if (cursor === cursorCount - 1 && delta > 0 && filter !== "all" && canLoad(filter)) {
      loadGroup(filter)
      return
    }

    // The first Down out of the field lands on the first result rather than
    // the second, which is what it looks like it should do.
    var next = cursor < 0 ? (delta > 0 ? 0 : cursorCount - 1) : cursor + delta

    if (next < 0) {
      // Back up past the top of the results and the caret returns to the
      // query, ready to refine it.
      cursor = -1
      field.focusInput()
      return
    }

    cursor = Math.min(cursorCount - 1, next)
    field.releaseInput()
  }

  // What the cursor is on, as { kind, item }.
  function cursorTarget() {
    if (cursor < 0 || cursor >= cursorCount) return null
    if (cursor < episodesOffset) return { kind: "show", item: shownShows[cursor] }
    if (cursor < tracksOffset) return { kind: "episode", item: shownEpisodes[cursor - episodesOffset] }
    if (cursor < tagsOffset) return { kind: "track", item: shownTracks[cursor - tracksOffset] }
    return { kind: "tag", item: shownTags[cursor - tagsOffset] }
  }

  function activateCursor() {
    var target = cursorTarget()
    if (!target) return
    if (target.kind === "show") { root.showRequested(target.item.alias); return }
    if (target.kind === "episode") { root.episodeRequested(target.item); return }
    if (target.kind === "track") {
      if (target.item.showAlias === "" || target.item.episodeAlias === "") return
      root.episodeRequested(episodeFromTrack(target.item))
      return
    }
    // A tag is a query, so activating one searches for it.
    field.text = target.item.name
    setQuery(target.item.name)
    debounce.stop()
    run()
  }

  function playCursor() {
    var target = cursorTarget()
    if (!target || !service) return
    if (target.kind === "track") { playTrack(target.item); return }
    if (target.kind !== "episode") return
    playEpisode(target.item)
  }

  function saveCursor() {
    var target = cursorTarget()
    if (!target || !service) return
    if (target.kind === "episode") service.toggleSaveEpisode(target.item)
    else if (target.kind === "show") service.toggleSaveShow(target.item)
    else if (target.kind === "track" && target.item.showAlias && target.item.episodeAlias)
      saveTrack(target.item)
  }

  function playEpisode(episode) {
    playRequest++
    trackMessage = ""
    if (!service) return
    if (service.isCurrentEpisode(episode)) service.togglePlayback()
    else if (!service.playEpisode(episode, -1)) trackMessage = service.archiveError
  }

  property var savingTracks: ({})

  function saveTrack(track) {
    if (!api || !service || !track.showAlias || !track.episodeAlias) return
    var episode = episodeFromTrack(track)
    var key = NtsApi.episodeKey(episode)
    if (savingTracks[key]) return
    if (service.isEpisodeSaved(episode)) {
      service.toggleSaveEpisode(episode)
      return
    }
    var token = generation
    trackMessage = ""
    var next = Object.assign({}, savingTracks)
    next[key] = true
    savingTracks = next
    api.episode(track.showAlias, track.episodeAlias, function(result, ok) {
      var pendingSaves = Object.assign({}, root.savingTracks)
      delete pendingSaves[key]
      root.savingTracks = pendingSaves
      if (!ok || !result) {
        if (token === root.generation) root.trackMessage = "Could not save episode. Try Save again."
        return
      }
      // Saving remains intentional even if the user browses elsewhere while
      // metadata loads. Do not toggle off a save made from another page.
      if (!service.isEpisodeSaved(result)) service.toggleSaveEpisode(result)
    })
  }

  property int playRequest: 0
  property string trackMessage: ""

  function playTrack(track) {
    if (!api || !service || !track.showAlias || !track.episodeAlias) return
    if (service.isCurrentEpisode(episodeFromTrack(track))) {
      playRequest++
      trackMessage = ""
      service.togglePlayback()
      return
    }
    var wanted = ++playRequest
    trackMessage = "Loading episode…"
    api.episode(track.showAlias, track.episodeAlias, function(result, ok) {
      if (wanted !== root.playRequest) return
      if (!ok || !result) { root.trackMessage = "Could not load episode. Try Play again."; return }
      root.trackMessage = ""
      if (service.isCurrentEpisode(result)) service.togglePlayback()
      else if (!service.playEpisode(result, -1)) root.trackMessage = service.archiveError
    })
  }

  // A track row knows which episode it was played on but not that episode's
  // audio; the episode page fills the rest in when it opens.
  function episodeFromTrack(track) {
    return {
      kind: "episode",
      showAlias: track.showAlias,
      episodeAlias: track.episodeAlias,
      name: track.episodeName,
      showName: "",
      description: "",
      location: "",
      genres: [],
      artworkSmall: track.artworkSmall,
      artworkLarge: track.artworkSmall,
      dateLabel: track.dateLabel,
      broadcastMs: 0,
      audioUrl: "",
      audioSource: "",
      url: "",
      valid: true
    }
  }

  // Cards keep a roughly constant size and the grid grows a column instead of
  // stretching them. Fixed column counts were fine while the window was always
  // tiled at half a screen; opening maximized turned four columns into 300px
  // cards with nothing gained.
  function gridColumns(available, spacing) {
    var target = 175
    var columns = Math.round((available + spacing) / (target + spacing))
    return Math.max(2, Math.min(8, columns))
  }

  // Keep the cursor on screen as it moves. Delegates report their own
  // geometry rather than the page computing it, which is the only thing that
  // works when sections have different row heights.
  function ensureVisible(item) {
    if (!item) return
    var pos = item.mapToItem(results, 0, 0)
    var margin = Style.space(14)
    var top = pos.y - margin
    var bottom = pos.y + item.height + margin
    if (top < scroller.contentY) scroller.contentY = Math.max(0, top)
    else if (bottom > scroller.contentY + scroller.height)
      scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height),
        bottom - scroller.height)
  }

  function clearResults() {
    cursor = -1
    shows = []
    episodes = []
    tracks = []
    tags = []
    groups = ({})
  }

  function setQuery(value) {
    var next = String(value || "").trim()
    if (next === query) return
    generation++
    playRequest++
    trackMessage = ""
    clearResults()
    pending = 0
    failed = false
    resolvedQuery = ""
    scroller.contentY = 0
    query = next
    if (next === "") {
      debounce.stop()
      clearResults()
      pending = 0
      failed = false
      resolvedQuery = ""
      return
    }
    debounce.restart()
  }

  // 280ms: long enough that a word typed at speed is one request rather than
  // eight, short enough that it still feels like it is keeping up.
  Timer {
    id: debounce
    interval: 280
    onTriggered: root.run()
  }

  function run() {
    debounce.stop()
    if (!api || query === "") return
    generation++
    playRequest++
    trackMessage = ""
    clearResults()
    pending = 0
    failed = false
    resolvedQuery = ""
    scroller.contentY = 0
    var initial = {}
    for (var key in Search.types) initial[key] = Search.emptyGroup()
    groups = initial
    for (var name in Search.types) loadGroup(name)
  }

  function loadGroup(key) {
    var group = groups[key]
    if (!api || !group || group.loading || (!group.more && !group.failed)) return
    var token = generation
    var wanted = query
    var next = Object.assign({}, groups)
    next[key] = Object.assign({}, group, { loading: true, failed: false })
    groups = next
    pending++
    api.search(wanted, Search.types[key], key === "tags" ? 12 : 24, group.offset,
      function(result, ok) {
        if (token !== root.generation) return
        var updated = Object.assign({}, root.groups)
        updated[key] = Search.finishGroup(group, result, ok)
        if (ok && result) {
          // Earlier sections can grow while a later result is selected.
          // Preserve that result, rather than the numeric index it occupied.
          var selected = root.cursorTarget()
          root.cursor = -1
          root[key] = Search.merge(root[key], result[key], key)
          if (selected) {
            var items = selected.kind === "show" ? root.shownShows
              : selected.kind === "episode" ? root.shownEpisodes
              : selected.kind === "track" ? root.shownTracks : root.shownTags
            var index = items.indexOf(selected.item)
            var offset = selected.kind === "show" ? 0
              : selected.kind === "episode" ? root.episodesOffset
              : selected.kind === "track" ? root.tracksOffset : root.tagsOffset
            if (index >= 0) root.cursor = offset + index
          }
          if (result.popular.length) root.popular = result.popular
        }
        root.groups = updated
        root.pending = Math.max(0, root.pending - 1)
        root.resolvedQuery = wanted
        root.failed = !root.hasResults && Object.keys(updated).every(function(k) {
          return updated[k].failed
        })
      })
  }

  // Popular terms ride along on every search response, and NTS serves them for
  // an empty query too — so an untouched search page has something to offer.
  function loadPopular() {
    if (!api || popular.length > 0) return
    api.search("", NtsApi.SEARCH_TYPES, 1, 0, function(result, ok) {
      if (ok && result && result.popular.length) root.popular = result.popular
    })
  }

  Component.onCompleted: loadPopular()
  onActiveChanged: {
    if (active) { loadPopular(); field.focusInput() }
    else { playRequest++; trackMessage = "" }
  }

  Column {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(18)
    anchors.leftMargin: Style.space(20)
    anchors.rightMargin: Style.space(20)
    spacing: Style.space(4)

    Nts.SearchField {
      id: field
      width: parent.width
      ink: root.ink
      onEdited: function(value) { root.setQuery(value) }
      onSubmitted: function(value) {
        // Enter means "open what I have picked" once the cursor has moved into
        // the results, and "search for this" while it is still in the field.
        if (root.cursor >= 0) {
          root.activateCursor()
          return
        }
        root.searchFor(value)
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(8)
      Repeater {
        model: ["all", "episodes", "tracks", "shows", "tags"]
        Nts.BlockButton {
          required property string modelData
          label: (modelData === "tracks" ? "Artist / track" : modelData)
            + (root.groups[modelData] ? " · " + root.groups[modelData].total : "")
          ink: root.ink
          filled: root.filter === modelData
          onActivated: root.chooseFilter(modelData)
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.space(8)
      visible: root.suggestions.length > 0
      Repeater {
        model: root.suggestions
        Nts.BlockButton {
          required property string modelData
          label: "Try " + modelData
          ink: root.ink
          onActivated: root.searchFor(modelData)
        }
      }
    }

    Nts.Caption {
      width: parent.width
      ink: root.ink
      dim: 0.42
      text: {
        if (root.trackMessage !== "") return root.trackMessage
        if (root.searching) return "Searching…"
        if (root.query === "") return ""
        if (root.total > 0) return root.total + " matches across episodes, tracks, shows and tags"
        if (root.query !== "") return "Try an artist, track title, show or genre"

        return ""
      }
      visible: text !== ""
    }
  }

  Nts.Scroller {
    id: scroller
    objectName: "searchResults"
    speedPercent: root.service ? root.service.scrollSpeed : 100
    onWheelObserved: function(pixelDelta, angleDelta) {
      if (root.service) root.service.noteWheel(pixelDelta, angleDelta)
    }
    anchors.top: header.bottom
    anchors.topMargin: Style.space(12)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentWidth: width
    contentHeight: results.implicitHeight + Style.space(32)

    Column {
      id: results
      x: Style.space(20)
      width: scroller.width - Style.space(40)
      spacing: Style.space(20)

      Nts.StateNote {
        width: parent.width
        ink: root.ink
        text: {
          if (root.failed) return "Could not reach NTS"
          if (root.showEmpty) return "Nothing for “" + root.query + "”"
          return ""
        }
        isError: root.failed
        actionLabel: root.failed ? "Try again" : ""
        onActionTriggered: root.run()
      }

      // ---- an untouched search page: what other people are looking for

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.query === "" && root.popular.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Popular searches"
          ink: root.ink
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.popular

            Nts.BlockButton {
              required property var modelData
              label: modelData
              ink: root.ink
              onActivated: {
                field.text = modelData
                root.setQuery(modelData)
                debounce.stop()
                root.run()
              }
            }
          }
        }
      }

      // ---- shows

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: root.query !== "" && (root.filter === "all" || root.filter === "shows")

        Nts.SectionHeader {
          width: parent.width
          title: "Shows"
          ink: root.ink
          aside: root.groupLabel("shows")
        }

        Nts.Caption {
          width: parent.width
          ink: root.ink
          visible: root.groups["shows"] !== undefined
            && !root.groups["shows"].loading
            && (root.groups["shows"].failed || root.shows.length === 0)
          text: root.groups["shows"] && root.groups["shows"].failed
            ? "Could not load these matches. Retry below." : "No matches in this category"
        }


        Grid {
          id: showGrid
          width: parent.width
          columns: root.gridColumns(width, Style.space(12))
          spacing: Style.space(12)

          Repeater {
            model: root.shownShows

            Nts.ShowCard {
              required property var modelData
              required property int index
              selected: root.cursor === index
              onSelectedChanged: if (selected) root.ensureVisible(this)
              width: (showGrid.width - Style.space(12) * (showGrid.columns - 1)) / showGrid.columns
              item: modelData
              isShow: true
              service: root.service
              active: root.active
              ink: root.ink
              subtitle: modelData.location
              onOpened: root.showRequested(modelData.alias)
            }
          }
        }

        Nts.BlockButton {
          visible: root.canLoad("shows")
          enabledAction: root.groups["shows"] !== undefined && !root.groups["shows"].loading
          label: root.groups["shows"] && root.groups["shows"].failed
            ? "Retry shows" : "Load more shows"
          ink: root.ink
          onActivated: root.loadGroup("shows")
        }
      }

      // ---- episodes

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.query !== "" && (root.filter === "all" || root.filter === "episodes")

        Nts.SectionHeader {
          width: parent.width
          title: "Episodes"
          ink: root.ink
          aside: root.groupLabel("episodes")
        }

        Nts.Caption {
          width: parent.width
          ink: root.ink
          visible: root.groups["episodes"] !== undefined
            && !root.groups["episodes"].loading
            && (root.groups["episodes"].failed || root.episodes.length === 0)
          text: root.groups["episodes"] && root.groups["episodes"].failed
            ? "Could not load these matches. Retry below." : "No matches in this category"
        }


        Repeater {
          model: root.shownEpisodes

          Nts.EpisodeRow {
            required property var modelData
            required property int index
            selected: root.cursor === root.episodesOffset + index
            onSelectedChanged: if (selected) root.ensureVisible(this)
            width: results.width
            episode: modelData
            service: root.service
            active: root.active
            ink: root.ink
            onOpened: root.episodeRequested(modelData)
            onPlayed: root.playEpisode(modelData)
          }
        }

        Nts.BlockButton {
          objectName: "loadMoreEpisodes"
          visible: root.canLoad("episodes")
          enabledAction: root.groups["episodes"] !== undefined && !root.groups["episodes"].loading
          label: root.groups["episodes"] && root.groups["episodes"].failed
            ? "Retry episodes" : "Load more episodes"
          ink: root.ink
          onActivated: root.loadGroup("episodes")
        }
      }

      // ---- tracks
      //
      // A track is not playable on its own — NTS indexes it as something that
      // was played on an episode — so a track row's action is to open that
      // episode. Play starts or resumes that episode, not an individual track.

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.query !== "" && (root.filter === "all" || root.filter === "tracks")

        Nts.SectionHeader {
          width: parent.width
          title: "Tracks"
          ink: root.ink
          aside: root.groupLabel("tracks")
        }

        Nts.Caption {
          width: parent.width
          ink: root.ink
          visible: root.groups["tracks"] !== undefined
            && !root.groups["tracks"].loading
            && (root.groups["tracks"].failed || root.tracks.length === 0)
          text: root.groups["tracks"] && root.groups["tracks"].failed
            ? "Could not load these matches. Retry below." : "No matches in this category"
        }


        Repeater {
          model: root.shownTracks

          Item {
            id: trackRow
            required property var modelData
            required property int index

            readonly property bool selected: root.cursor === root.tracksOffset + index
            onSelectedChanged: if (selected) root.ensureVisible(this)

            readonly property bool linked: modelData.showAlias !== "" && modelData.episodeAlias !== ""

            width: results.width
            height: Math.max(Style.space(34), trackText.implicitHeight + Style.space(12))

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: -Style.space(6)
              anchors.rightMargin: -Style.space(6)
              color: trackRow.selected ? Util.alpha(root.ink, 0.13)
                : (trackHover.hovered && trackRow.linked
                   ? Util.alpha(root.ink, 0.06) : "transparent")
            }

            HoverHandler { id: trackHover }

            MouseArea {
              anchors.fill: parent
              enabled: trackRow.linked
              cursorShape: Qt.PointingHandCursor
              onClicked: root.episodeRequested(root.episodeFromTrack(trackRow.modelData))
            }

            Row {
              id: trackActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              visible: trackRow.linked
              Nts.BlockButton {
                label: root.service && root.service.isCurrentEpisode(root.episodeFromTrack(trackRow.modelData))
                  && root.service.playing ? "Pause" : "Play episode"
                ink: root.ink
                onActivated: root.playTrack(trackRow.modelData)
              }
              Nts.BlockButton {
                readonly property bool saving: !!root.savingTracks[NtsApi.episodeKey(root.episodeFromTrack(trackRow.modelData))]
                label: saving ? "Saving…" : root.service && root.service.isEpisodeSaved(root.episodeFromTrack(trackRow.modelData))
                  ? "Saved" : "Save"
                enabledAction: !saving
                ink: root.ink
                onActivated: root.saveTrack(trackRow.modelData)
              }
            }

            Column {
              id: trackText
              anchors.left: parent.left
              anchors.right: trackActions.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: trackRow.modelData.artist !== "" && trackRow.modelData.title !== ""
                  ? trackRow.modelData.artist + " — " + trackRow.modelData.title
                  : (trackRow.modelData.artist || trackRow.modelData.title)
                color: root.ink
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Nts.Caption {
                width: parent.width
                ink: root.ink
                dim: 0.4
                visible: text !== ""
                text: {
                  var parts = []
                  if (trackRow.modelData.episodeName) parts.push(trackRow.modelData.episodeName)
                  if (trackRow.modelData.dateLabel) parts.push(trackRow.modelData.dateLabel)
                  return parts.join(" · ")
                }
              }
            }
          }
        }

        Nts.BlockButton {
          visible: root.canLoad("tracks")
          enabledAction: root.groups["tracks"] !== undefined && !root.groups["tracks"].loading
          label: root.groups["tracks"] && root.groups["tracks"].failed
            ? "Retry tracks" : "Load more tracks"
          ink: root.ink
          onActivated: root.loadGroup("tracks")
        }
      }

      // ---- tags
      //
      // A tag is a query, not a destination: NTS has no tag page this plugin
      // can open, so selecting one searches for it.

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.query !== "" && (root.filter === "all" || root.filter === "tags")

        Nts.SectionHeader {
          width: parent.width
          title: "Tags"
          aside: root.groupLabel("tags")
          ink: root.ink
        }

        Nts.Caption {
          width: parent.width
          ink: root.ink
          visible: root.groups["tags"] !== undefined
            && !root.groups["tags"].loading
            && (root.groups["tags"].failed || root.tags.length === 0)
          text: root.groups["tags"] && root.groups["tags"].failed
            ? "Could not load these matches. Retry below." : "No matches in this category"
        }


        Flow {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.shownTags

            Nts.BlockButton {
              required property var modelData
              required property int index
              filled: root.cursor === root.tagsOffset + index
              onFilledChanged: if (filled) root.ensureVisible(this)
              label: modelData.name
              ink: root.ink
              onActivated: {
                field.text = modelData.name
                root.setQuery(modelData.name)
                debounce.stop()
                root.run()
              }
            }
          }
        }

        Nts.BlockButton {
          visible: root.canLoad("tags")
          enabledAction: root.groups["tags"] !== undefined && !root.groups["tags"].loading
          label: root.groups["tags"] && root.groups["tags"].failed
            ? "Retry tags" : "Load more tags"
          ink: root.ink
          onActivated: root.loadGroup("tags")
        }
      }
    }
  }
}
