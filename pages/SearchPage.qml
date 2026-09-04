import QtQuick
import qs.Commons

import "../components" as Nts
import "../NtsApi.js" as NtsApi

// Search across shows, episodes, tracks and tags.
//
// NTS returns tracks and tags from different indexes than shows and episodes,
// so this fires three requests per query rather than one and groups what comes
// back. They resolve independently: a slow track index does not hold up the
// show results, and a group that fails simply does not appear.
//
// Every response carries the query it was for. A fast typist outruns the
// network, and without that check an early request landing late would replace
// the results for what they are actually looking at now.
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
  property int total: 0
  property var popular: []

  property int pending: 0
  property bool failed: false
  // The query the currently displayed results belong to.
  property string resolvedQuery: ""

  // The API returns shows and episodes mixed in one response, so the split
  // between groups is made here rather than asked for. Each group shows a
  // taste and names its full size, which is what keeps all four groups on
  // screen together instead of burying tracks under thirty episodes.
  readonly property var shownShows: shows.slice(0, 5)
  readonly property var shownEpisodes: episodes.slice(0, 6)

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
  readonly property int tagsOffset: tracksOffset + tracks.length
  readonly property int cursorCount: tagsOffset + tags.length

  function resetCursor() { cursor = -1 }

  // -1 is a real position, not "unset": it means the caret is still in the
  // search field. Moving in and out of the results moves keyboard ownership
  // with it, which is what makes bare-key shortcuts (p, b) act on the
  // selection instead of being typed into the query.
  function moveCursor(delta) {
    if (cursorCount === 0) return

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
    if (cursor < tagsOffset) return { kind: "track", item: tracks[cursor - tracksOffset] }
    return { kind: "tag", item: tags[cursor - tagsOffset] }
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
    if (!target || target.kind !== "episode" || !service) return
    if (service.isCurrentEpisode(target.item)) service.togglePlayback()
    else service.playEpisode(target.item, -1)
  }

  function saveCursor() {
    var target = cursorTarget()
    if (!target || !service) return
    if (target.kind === "episode") service.toggleSaveEpisode(target.item)
    else if (target.kind === "show") service.toggleSaveShow(target.item)
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
    total = 0
  }

  function setQuery(value) {
    var next = String(value || "").trim()
    if (next === query) return
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
    if (!api || query === "") return
    var wanted = query
    failed = false
    pending = 3

    function settle(forQuery) {
      if (forQuery !== root.query) return false
      root.pending = Math.max(0, root.pending - 1)
      if (root.pending === 0) {
        root.resolvedQuery = forQuery
        root.failed = !root.hasResults && root.failedAll
      }
      return true
    }

    failedAll = true

    api.search(wanted, NtsApi.SEARCH_TYPES, 12, 0, function(result, ok) {
      if (root.query !== wanted) return
      if (ok && result) {
        root.failedAll = false
        root.shows = result.shows
        root.episodes = result.episodes
        root.total = result.total
        if (result.popular.length) root.popular = result.popular
      }
      settle(wanted)
    })

    api.search(wanted, NtsApi.SEARCH_TYPES_TRACK, 8, 0, function(result, ok) {
      if (root.query !== wanted) return
      if (ok && result) {
        root.failedAll = false
        root.tracks = result.tracks
      }
      settle(wanted)
    })

    api.search(wanted, NtsApi.SEARCH_TYPES_TAG, 8, 0, function(result, ok) {
      if (root.query !== wanted) return
      if (ok && result) {
        root.failedAll = false
        root.tags = result.tags
      }
      settle(wanted)
    })

    // The new query owns the view from this moment; stale rows would
    // otherwise sit under a spinner belonging to something else.
    clearResults()
  }

  property bool failedAll: false

  // Popular terms ride along on every search response, and NTS serves them for
  // an empty query too — so an untouched search page has something to offer.
  function loadPopular() {
    if (!api || popular.length > 0) return
    api.search("", NtsApi.SEARCH_TYPES, 1, 0, function(result, ok) {
      if (ok && result && result.popular.length) root.popular = result.popular
    })
  }

  Component.onCompleted: loadPopular()
  onActiveChanged: if (active) { loadPopular(); field.focusInput() }

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
        debounce.stop()
        root.setQuery(value)
        root.run()
      }
    }

    Nts.Caption {
      width: parent.width
      ink: root.ink
      dim: 0.42
      text: {
        if (root.searching) return "Searching…"
        if (root.query === "") return ""
        if (root.total > 0) return root.total + " results"
        return ""
      }
      visible: text !== ""
    }
  }

  Flickable {
    id: scroller
    anchors.top: header.bottom
    anchors.topMargin: Style.space(12)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentWidth: width
    contentHeight: results.implicitHeight + Style.space(32)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

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
        visible: root.shows.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Shows"
          ink: root.ink
          aside: root.shows.length > root.shownShows.length
            ? root.shownShows.length + " of " + root.shows.length : ""
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
      }

      // ---- episodes

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.episodes.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Episodes"
          ink: root.ink
          aside: root.episodes.length > root.shownEpisodes.length
            ? root.shownEpisodes.length + " of " + root.episodes.length : ""
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
            onPlayed: {
              if (root.service.isCurrentEpisode(modelData)) root.service.togglePlayback()
              else root.service.playEpisode(modelData, -1)
            }
          }
        }
      }

      // ---- tracks
      //
      // A track is not playable on its own — NTS indexes it as something that
      // was played on an episode — so a track row's action is to open that
      // episode at the point it appears.

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.tracks.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Tracks"
          ink: root.ink
          aside: "Played on"
        }

        Repeater {
          model: root.tracks

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
              onClicked: root.episodeRequested({
                kind: "episode",
                showAlias: trackRow.modelData.showAlias,
                episodeAlias: trackRow.modelData.episodeAlias,
                name: trackRow.modelData.episodeName,
                showName: "",
                description: "",
                location: "",
                genres: [],
                artworkSmall: trackRow.modelData.artworkSmall,
                artworkLarge: trackRow.modelData.artworkSmall,
                broadcastMs: 0,
                audioUrl: "",
                audioSource: "",
                url: "",
                valid: true
              })
            }

            Column {
              id: trackText
              anchors.left: parent.left
              anchors.right: parent.right
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
      }

      // ---- tags
      //
      // A tag is a query, not a destination: NTS has no tag page this plugin
      // can open, so selecting one searches for it.

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.tags.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Tags"
          ink: root.ink
        }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.tags

            Nts.BlockButton {
              required property var modelData
              required property int index
              filled: root.cursor === root.tagsOffset + index
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
      }
    }
  }
}
