import QtQuick
import qs.Commons

import "../components" as Nts
import "../Model.js" as Model
import "../NtsApi.js" as NtsApi
import "../Library.js" as Library

// Live listening first, then the user's own shelf, then NTS's editorial.
//
// The order is the argument: this is a radio station, so what is on air right
// now outranks everything; what you were part way through outranks what you
// might like; and what the station is pushing comes last because it is the
// only part not about you. Sections with nothing in them are not rendered at
// all rather than shown empty.
Item {
  id: root

  property var service: null
  property bool active: true
  property color ink: Color.foreground
  property color paper: Color.background

  signal showRequested(string alias)
  signal episodeRequested(var episode)
  signal searchRequested()

  readonly property var api: service ? service.api : null
  readonly property var library: service ? service.library : null

  property var picks: []
  property var recent: []
  property bool loadingDiscover: false
  property bool discoverFailed: false

  // Fetched once per window, then served from the API cache. The home page is
  // returned to constantly while navigating, and re-requesting NTS's editorial
  // rails on every visit would be rude and slow.
  property bool requested: false

  function load(force) {
    if (!api) return
    if (requested && force !== true) return
    requested = true
    loadingDiscover = true
    discoverFailed = false

    var outstanding = 2
    function done() {
      outstanding--
      if (outstanding > 0) return
      loadingDiscover = false
      discoverFailed = root.picks.length === 0 && root.recent.length === 0
    }

    api.collection("picks", 8, function(result, ok) {
      if (ok && result) root.picks = result.episodes
      done()
    })
    api.collection("recent", 8, function(result, ok) {
      if (ok && result) root.recent = result.episodes
      done()
    })
  }

  function reload() { load(true) }

  Component.onCompleted: load(false)
  onActiveChanged: if (active) load(false)

  // "Continue listening" is the resume shelf, newest first. Library.js already
  // drops entries that finished or never really started.
  readonly property var continueListening: library && library.resume
    ? library.resume.slice(0, 6) : []
  readonly property var savedShows: library && library.shows
    ? library.shows.slice(0, 6) : []

  // ---- keyboard cursor
  //
  // Walks the page's four content shelves in the order they are drawn. The
  // live channel cards are deliberately left out: they already have dedicated
  // keys (1 and 2) that work from anywhere in the browser.

  property int cursor: -1

  readonly property int savedOffset: continueListening.length
  readonly property int picksOffset: savedOffset + savedShows.length
  readonly property int recentOffset: picksOffset + picks.length
  readonly property int cursorCount: recentOffset + recent.length

  function resetCursor() { cursor = -1 }

  function moveCursor(delta) {
    if (cursorCount === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : cursorCount - 1) : cursor + delta
    cursor = Math.max(0, Math.min(cursorCount - 1, next))
  }

  function cursorTarget() {
    if (cursor < 0 || cursor >= cursorCount) return null
    if (cursor < savedOffset) return { kind: "episode", item: continueListening[cursor] }
    if (cursor < picksOffset) return { kind: "show", item: savedShows[cursor - savedOffset] }
    if (cursor < recentOffset) return { kind: "episode", item: picks[cursor - picksOffset] }
    return { kind: "episode", item: recent[cursor - recentOffset] }
  }

  function activateCursor() {
    var target = cursorTarget()
    if (!target) return
    if (target.kind === "show") root.showRequested(target.item.alias)
    else root.episodeRequested(target.item)
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
    if (target.kind === "show") service.toggleSaveShow(target.item)
    else service.toggleSaveEpisode(target.item)
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

  Nts.Scroller {
    id: scroller
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight + Style.space(32)

    Column {
      id: column
      x: Style.space(20)
      y: Style.space(18)
      width: scroller.width - Style.space(40)
      spacing: Style.space(22)

      // ---- live now

      Column {
        width: parent.width
        spacing: Style.space(12)

        Nts.SectionHeader {
          width: parent.width
          title: "Live now"
          ink: root.ink
          aside: root.service && root.service.metadataFailed
            ? (root.service.live ? "Schedule may be out of date" : "Cannot reach NTS") : ""
        }

        Row {
          width: parent.width
          spacing: Style.space(14)

          Repeater {
            model: [1, 2]

            // A live channel, sized like a wide card: artwork, the channel,
            // what is on, and how far through it is.
            Item {
              id: channelCard
              required property int modelData

              readonly property var state: root.service
                ? root.service.channelState(modelData) : null
              readonly property var show: state ? state.now : null
              readonly property bool selected: root.service
                && !root.service.archiveMode && root.service.channel === modelData
              readonly property bool onAir: selected && root.service.playing

              width: (parent.width - Style.space(14)) / 2
              height: Style.space(104)

              Rectangle {
                anchors.fill: parent
                radius: 0
                color: channelHover.hovered ? Util.alpha(root.ink, 0.06) : "transparent"
                border.width: 1
                border.color: Util.alpha(root.ink, channelCard.selected ? 0.85 : 0.25)

                Behavior on color {
                  ColorAnimation { duration: 110 }
                }
              }

              HoverHandler { id: channelHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.service) root.service.playLive(channelCard.modelData)
              }

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(12)

                Nts.ArtFrame {
                  id: channelArt
                  width: parent.height
                  height: width
                  source: channelCard.show ? channelCard.show.artworkLarge : ""
                  active: root.active
                  ink: root.ink
                  showPlayAffordance: true
                  hovered: channelHover.hovered
                  playing: channelCard.onAir
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - channelArt.width - Style.space(12)
                  spacing: Style.space(4)

                  Row {
                    spacing: Style.space(6)

                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(6)
                      height: width
                      radius: 0
                      color: channelCard.onAir ? root.ink : "transparent"
                      border.width: 1
                      border.color: Util.alpha(root.ink, 0.6)
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: Model.channelLabel(channelCard.modelData)
                      color: root.ink
                      font.family: Style.font.family
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                      font.letterSpacing: 0.5
                    }
                  }

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: channelCard.show && channelCard.show.valid
                      ? Model.barTitle(channelCard.show) : "—"
                    color: Util.alpha(root.ink, 0.8)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                    maximumLineCount: 2
                    wrapMode: Text.Wrap
                  }

                  Nts.Caption {
                    width: parent.width
                    ink: root.ink
                    dim: 0.42
                    text: channelCard.show
                      ? Model.remainingLabel(channelCard.show,
                          root.service ? root.service.nowMs : Date.now())
                      : ""
                    visible: text !== ""
                  }
                }
              }
            }
          }
        }
      }

      // ---- continue listening

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.continueListening.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Continue listening"
          ink: root.ink
        }

        Repeater {
          model: root.continueListening

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
            progress: Library.resumeFraction(modelData)
            onOpened: root.episodeRequested(modelData)
            onPlayed: {
              if (root.service.isCurrentEpisode(modelData)) root.service.togglePlayback()
              else root.service.playEpisode(modelData, -1)
            }
          }
        }
      }

      // ---- saved shows

      Column {
        width: parent.width
        spacing: Style.space(12)
        visible: root.savedShows.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Your shows"
          ink: root.ink
          aside: root.library && root.library.shows.length > 6
            ? root.library.shows.length + " saved" : ""
        }

        Grid {
          id: savedGrid
          width: parent.width
          columns: root.gridColumns(width, Style.space(12))
          spacing: Style.space(12)

          Repeater {
            model: root.savedShows

            Nts.ShowCard {
              required property var modelData
              required property int index
              selected: root.cursor === root.savedOffset + index
              onSelectedChanged: if (selected) root.ensureVisible(this)
              width: (savedGrid.width - Style.space(12) * (savedGrid.columns - 1)) / savedGrid.columns
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

      // ---- discover

      Column {
        width: parent.width
        spacing: Style.space(12)

        Nts.SectionHeader {
          width: parent.width
          title: "NTS picks"
          ink: root.ink
        }

        Nts.StateNote {
          width: parent.width
          ink: root.ink
          text: root.loadingDiscover ? "Loading" : (root.discoverFailed ? "Could not reach NTS" : "")
          isError: root.discoverFailed
          actionLabel: root.discoverFailed ? "Try again" : ""
          onActionTriggered: root.reload()
        }

        Grid {
          id: picksGrid
          width: parent.width
          columns: root.gridColumns(width, Style.space(14))
          spacing: Style.space(14)
          visible: root.picks.length > 0

          Repeater {
            model: root.picks

            Nts.ShowCard {
              required property var modelData
              required property int index
              selected: root.cursor === root.picksOffset + index
              onSelectedChanged: if (selected) root.ensureVisible(this)
              width: (picksGrid.width - Style.space(14) * (picksGrid.columns - 1)) / picksGrid.columns
              item: modelData
              service: root.service
              active: root.active
              ink: root.ink
              subtitle: NtsApi.dateLabel(modelData.broadcastMs)
              onOpened: root.episodeRequested(modelData)
              onPlayed: {
                if (root.service.isCurrentEpisode(modelData)) root.service.togglePlayback()
                else root.service.playEpisode(modelData, -1)
              }
            }
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(8)
        visible: root.recent.length > 0

        Nts.SectionHeader {
          width: parent.width
          title: "Recently added"
          ink: root.ink
        }

        Repeater {
          model: root.recent

          Nts.EpisodeRow {
            required property var modelData
            required property int index
            selected: root.cursor === root.recentOffset + index
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
      }
    }
  }
}
