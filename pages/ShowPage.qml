import QtQuick
import qs.Commons

import "../components" as Nts
import "../NtsApi.js" as NtsApi

// A show, which on NTS is also a host.
//
// The brief asked for a show page and a host page. NTS does not separate them:
// /shows/{alias} carries the presenter's image, their biography and their back
// catalogue, and the site's own "host" links point at exactly this resource.
// Two pages would have been the same page twice, so this is both — laid out
// editorially, with the biography given room rather than squeezed into a
// metadata strip.
Item {
  id: root

  property var service: null
  property bool active: true
  property color ink: Color.foreground
  property string alias: ""

  signal episodeRequested(var episode)

  readonly property var api: service ? service.api : null

  property var show: null
  property var episodes: []
  property int total: 0
  property bool loading: false
  property bool failed: false
  property bool loadingMore: false

  readonly property bool saved: service && show ? service.isShowSaved(show.alias) : false
  readonly property bool hasMore: episodes.length > 0 && episodes.length < total

  // ---- keyboard cursor: the episode list is the only selectable region.
  property int cursor: -1
  readonly property int cursorCount: episodes.length

  function resetCursor() { cursor = -1 }

  function moveCursor(delta) {
    if (cursorCount === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : cursorCount - 1) : cursor + delta
    cursor = Math.max(0, Math.min(cursorCount - 1, next))
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= episodes.length) return
    root.episodeRequested(episodes[cursor])
  }

  function playCursor() {
    if (cursor < 0 || cursor >= episodes.length || !service) return
    var episode = episodes[cursor]
    if (service.isCurrentEpisode(episode)) service.togglePlayback()
    else service.playEpisode(episode, -1)
  }

  function saveCursor() {
    if (cursor < 0 || cursor >= episodes.length || !service) return
    service.toggleSaveEpisode(episodes[cursor])
  }

  function ensureVisible(item) {
    if (!item) return
    var pos = item.mapToItem(column, 0, 0)
    var margin = Style.space(14)
    var top = pos.y - margin
    var bottom = pos.y + item.height + margin
    if (top < scroller.contentY) scroller.contentY = Math.max(0, top)
    else if (bottom > scroller.contentY + scroller.height)
      scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height),
        bottom - scroller.height)
  }

  onAliasChanged: load()
  Component.onCompleted: load()

  function load() {
    cursor = -1
    show = null
    episodes = []
    total = 0
    failed = false
    if (!api || alias === "") return
    loading = true
    var wanted = alias

    api.show(alias, function(result, ok) {
      // The user may have navigated on while this was in flight.
      if (root.alias !== wanted) return
      root.loading = false
      if (!ok || !result) {
        root.failed = true
        return
      }
      root.show = result.show
      // The episode endpoint has no field for the show's name — only its
      // alias — so the name is carried down from here, where it is known.
      root.episodes = root.stamped(result.episodes, result.show.name)
      // The embedded list is the first page; the real count comes with the
      // paginated endpoint, so assume there is more until told otherwise.
      root.total = result.episodes.length
      root.fetchCount(wanted)
    })
  }

  // The show payload does not carry a total, so ask the paginated endpoint for
  // one row purely to learn how many there are. Cheap, and it means the
  // "Load more" affordance is honest rather than optimistic.
  function fetchCount(wanted) {
    api.showEpisodes(wanted, 1, 0, function(result, ok) {
      if (root.alias !== wanted || !ok || !result) return
      root.total = result.total
    })
  }

  // Copies rather than mutates: the objects come out of the API cache and may
  // be handed to another page that should not see this page's edits.
  function stamped(episodes, showName) {
    if (!showName) return episodes
    var out = []
    for (var i = 0; i < episodes.length; i++) {
      var copy = {}
      for (var key in episodes[i]) copy[key] = episodes[i][key]
      copy.showName = showName
      out.push(copy)
    }
    return out
  }

  function loadMore() {
    if (!api || loadingMore || !hasMore) return
    loadingMore = true
    var wanted = alias
    var offset = episodes.length

    api.showEpisodes(wanted, 16, offset, function(result, ok) {
      if (root.alias !== wanted) return
      root.loadingMore = false
      if (!ok || !result) return
      // Concatenate rather than replace; the model is the whole list so far.
      var merged = root.episodes.slice()
      var named = root.stamped(result.episodes, root.show ? root.show.name : "")
      for (var i = 0; i < named.length; i++) merged.push(named[i])
      root.episodes = merged
      root.total = result.total
    })
  }

  Flickable {
    id: scroller
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight + Style.space(32)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: column
      x: Style.space(20)
      y: Style.space(18)
      width: scroller.width - Style.space(40)
      spacing: Style.space(20)

      Nts.StateNote {
        width: parent.width
        ink: root.ink
        text: root.loading ? "Loading" : (root.failed ? "Could not load this show" : "")
        isError: root.failed
        actionLabel: root.failed ? "Try again" : ""
        onActionTriggered: root.load()
      }

      // ---- hero

      Row {
        width: parent.width
        spacing: Style.space(20)
        visible: root.show !== null

        Nts.ArtFrame {
          id: hero
          width: Math.min(Style.space(180), column.width * 0.3)
          height: width
          source: root.show ? root.show.artworkLarge : ""
          active: root.active
          ink: root.ink
          decodeWidth: 600
        }

        Column {
          width: column.width - hero.width - Style.space(20)
          spacing: Style.space(9)

          Nts.Caption {
            text: "Show"
            ink: root.ink
            dim: 0.4
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.show ? root.show.name : ""
            color: root.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            font.letterSpacing: -0.4
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Nts.Caption {
            width: parent.width
            ink: root.ink
            dim: 0.5
            visible: text !== ""
            text: {
              if (!root.show) return ""
              var parts = []
              if (root.show.location) parts.push(root.show.location)
              for (var i = 0; i < root.show.genres.length && parts.length < 5; i++)
                parts.push(root.show.genres[i])
              return parts.join(" · ")
            }
          }

          // The biography, given its own measure rather than a metadata line.
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.show ? root.show.description : ""
            visible: text !== ""
            color: Util.alpha(root.ink, 0.72)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            lineHeight: 1.35
            wrapMode: Text.Wrap
            maximumLineCount: 6
            elide: Text.ElideRight
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Nts.BlockButton {
              label: root.saved ? "Saved" : "Save show"
              filled: root.saved
              ink: root.ink
              enabledAction: root.show !== null
              onActivated: if (root.service) root.service.toggleSaveShow(root.show)
            }

            Nts.BlockButton {
              label: "Open on nts.live"
              ink: root.ink
              enabledAction: root.show !== null
              onActivated: if (root.service) root.service.openExternal(root.show.url)
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
          aside: root.total > 0 ? root.episodes.length + " of " + root.total : ""
        }

        Repeater {
          model: root.episodes

          Nts.EpisodeRow {
            required property var modelData
            required property int index
            selected: root.cursor === index
            onSelectedChanged: if (selected) root.ensureVisible(this)
            width: column.width
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

        Item {
          width: parent.width
          height: more.implicitHeight + Style.space(14)
          visible: root.hasMore

          Nts.BlockButton {
            id: more
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            label: root.loadingMore ? "Loading" : "Load more"
            enabledAction: !root.loadingMore
            ink: root.ink
            onActivated: root.loadMore()
          }
        }
      }
    }
  }
}
