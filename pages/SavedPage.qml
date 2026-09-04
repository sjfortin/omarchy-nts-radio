import QtQuick
import qs.Commons

import "../components" as Nts
import "../NtsApi.js" as NtsApi
import "../Library.js" as Library

// The user's own shelf.
//
// Two tabs rather than the three the brief sketched, because NTS's data model
// has two things to hold: a show (which is also how it models a host — the
// host page and the show page are the same resource, /shows/{alias}) and an
// episode. There is no separately addressable "series", so a third tab would
// have been an empty promise.
//
// Everything here is local. See Library.js for why there is no account.
Item {
  id: root

  property var service: null
  property bool active: true
  property color ink: Color.foreground

  signal showRequested(string alias)
  signal episodeRequested(var episode)
  signal browseRequested()

  property string tab: "shows"

  readonly property var library: service ? service.library : null
  readonly property var shows: library ? library.shows : []
  readonly property var episodes: library ? library.episodes : []

  // ---- keyboard cursor over whichever tab is showing.
  property int cursor: -1
  readonly property var cursorItems: tab === "shows" ? shows : episodes
  readonly property int cursorCount: cursorItems.length

  function resetCursor() { cursor = -1 }

  function moveCursor(delta) {
    if (cursorCount === 0) return
    var next = cursor < 0 ? (delta > 0 ? 0 : cursorCount - 1) : cursor + delta
    cursor = Math.max(0, Math.min(cursorCount - 1, next))
  }

  function activateCursor() {
    if (cursor < 0 || cursor >= cursorCount) return
    if (tab === "shows") root.showRequested(cursorItems[cursor].alias)
    else root.episodeRequested(cursorItems[cursor])
  }

  function playCursor() {
    if (cursor < 0 || cursor >= cursorCount || tab !== "episodes" || !service) return
    var episode = cursorItems[cursor]
    if (service.isCurrentEpisode(episode)) service.togglePlayback()
    else service.playEpisode(episode, -1)
  }

  function saveCursor() {
    if (cursor < 0 || cursor >= cursorCount || !service) return
    // On this page, save is unsave: the shelf is what you are looking at.
    if (tab === "shows") service.toggleSaveShow(cursorItems[cursor])
    else service.toggleSaveEpisode(cursorItems[cursor])
  }

  // Tab moves between the two shelves. Left/Right would be the other obvious
  // choice, but those scrub the archive from anywhere in the window and a page
  // should not quietly steal a global transport key.
  function nextTab() {
    tab = tab === "shows" ? "episodes" : "shows"
  }

  onTabChanged: cursor = -1

  function ensureVisible(item) {
    if (!item) return
    var pos = item.mapToItem(content, 0, 0)
    var margin = Style.space(14)
    var top = pos.y - margin
    var bottom = pos.y + item.height + margin
    if (top < scroller.contentY) scroller.contentY = Math.max(0, top)
    else if (bottom > scroller.contentY + scroller.height)
      scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height),
        bottom - scroller.height)
  }

  Column {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: Style.space(18)
    anchors.leftMargin: Style.space(20)
    anchors.rightMargin: Style.space(20)
    spacing: Style.space(14)

    Text {
      textFormat: Text.PlainText
      text: "Saved"
      color: root.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.display
      font.bold: true
      font.letterSpacing: -0.2
    }

    Row {
      spacing: Style.space(8)

      Nts.BlockButton {
        label: "Shows"
        filled: root.tab === "shows"
        ink: root.ink
        onActivated: root.tab = "shows"
      }

      Nts.BlockButton {
        label: "Episodes"
        filled: root.tab === "episodes"
        ink: root.ink
        onActivated: root.tab = "episodes"
      }

      Nts.Caption {
        anchors.verticalCenter: parent.verticalCenter
        ink: root.ink
        dim: 0.4
        text: root.tab === "shows"
          ? (root.shows.length + (root.shows.length === 1 ? " show" : " shows"))
          : (root.episodes.length + (root.episodes.length === 1 ? " episode" : " episodes"))
      }
    }

    Nts.Rule { ink: root.ink }
  }

  Flickable {
    id: scroller
    anchors.top: header.bottom
    anchors.topMargin: Style.space(14)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentWidth: width
    contentHeight: content.implicitHeight + Style.space(32)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      x: Style.space(20)
      width: scroller.width - Style.space(40)
      spacing: Style.space(12)

      Nts.StateNote {
        width: parent.width
        ink: root.ink
        text: {
          if (root.tab === "shows" && root.shows.length === 0)
            return "No saved shows yet — save one from any show page"
          if (root.tab === "episodes" && root.episodes.length === 0)
            return "No saved episodes yet — save one from any episode"
          return ""
        }
        actionLabel: (root.tab === "shows" ? root.shows.length : root.episodes.length) === 0
          ? "Browse" : ""
        onActionTriggered: root.browseRequested()
      }

      Grid {
        width: parent.width
        columns: 5
        spacing: Style.space(12)
        visible: root.tab === "shows" && root.shows.length > 0

        Repeater {
          model: root.tab === "shows" ? root.shows : []

          Nts.ShowCard {
            required property var modelData
            required property int index
            selected: root.cursor === index
            onSelectedChanged: if (selected) root.ensureVisible(this)
            width: (content.width - Style.space(12) * 4) / 5
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

      Column {
        width: parent.width
        spacing: 0
        visible: root.tab === "episodes" && root.episodes.length > 0

        Repeater {
          model: root.tab === "episodes" ? root.episodes : []

          Nts.EpisodeRow {
            required property var modelData
            required property int index
            selected: root.cursor === index
            onSelectedChanged: if (selected) root.ensureVisible(this)
            width: content.width
            episode: modelData
            service: root.service
            active: root.active
            ink: root.ink
            progress: Library.resumeFraction(
              Library.resumeFor(root.library, modelData) || {})
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
