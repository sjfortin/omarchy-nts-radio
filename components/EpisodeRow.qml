import QtQuick
import qs.Commons

import "../NtsApi.js" as NtsApi

// One archived episode as a dense list row: thumbnail, title, metadata, and
// the two things you can do with it. Rows are separated by a rule and nothing
// else — no card, no shadow, no rounded corner.
//
// Clicking the row opens the episode; clicking the artwork plays it. Those are
// deliberately different targets: browsing and listening are different
// intentions and a single click target would make one of them a mistake.
Item {
  id: root

  required property var episode
  property var service: null
  property bool active: true
  property color ink: Color.foreground
  property bool showSaveAction: true
  // Under the keyboard cursor. Kept distinct from hover so a pointer moving
  // across the window does not silently move the keyboard's place.
  property bool selected: false
  // Progress through the episode, 0..1, for the thin resume rule. Only set on
  // the "continue listening" shelf.
  property real progress: 0

  signal opened()
  signal played()

  readonly property bool isPlaying: service && episode
    ? service.isCurrentEpisode(episode) && service.playing : false
  readonly property bool isCurrent: service && episode
    ? service.isCurrentEpisode(episode) : false
  readonly property bool isSaved: service && episode ? service.isEpisodeSaved(episode) : false
  readonly property bool hasAudio: episode && episode.audioUrl !== ""

  implicitHeight: Math.max(Style.space(56), layout.implicitHeight + Style.space(16))

  Rectangle {
    anchors.fill: parent
    anchors.leftMargin: -Style.space(6)
    anchors.rightMargin: -Style.space(6)
    color: root.selected ? Util.alpha(root.ink, 0.13)
      : (hover.hovered ? Util.alpha(root.ink, 0.06) : "transparent")
  }

  // The same filled tick the rail uses for the current destination.
  Rectangle {
    anchors.left: parent.left
    anchors.leftMargin: -Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(3)
    height: parent.height * 0.6
    radius: 0
    visible: root.selected
    color: root.ink
  }

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.opened()
  }

  Row {
    id: layout
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(12)

    ArtFrame {
      id: thumb
      width: Style.space(44)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      source: root.episode ? root.episode.artworkSmall : ""
      active: root.active
      ink: root.ink
      decodeWidth: 200
      showPlayAffordance: root.hasAudio
      hovered: artHover.hovered
      playing: root.isPlaying

      HoverHandler { id: artHover }

      MouseArea {
        anchors.fill: parent
        enabled: root.hasAudio
        cursorShape: Qt.PointingHandCursor
        onClicked: root.played()
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: layout.width - thumb.width - actions.width - Style.space(24)
      spacing: Style.space(3)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.episode ? root.episode.name : ""
        color: root.ink
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        // The thing on air is the one bold title in any list.
        font.bold: root.isCurrent
        elide: Text.ElideRight
      }

      Caption {
        width: parent.width
        text: root.episode ? NtsApi.episodeMeta(root.episode) : ""
        ink: root.ink
        dim: 0.45
      }

      // How far in, when this row came off the continue-listening shelf.
      Rectangle {
        visible: root.progress > 0
        width: parent.width * 0.4
        height: 2
        radius: 0
        color: Util.alpha(root.ink, 0.18)

        Rectangle {
          height: parent.height
          radius: 0
          width: parent.width * Math.max(0, Math.min(1, root.progress))
          color: Util.alpha(root.ink, 0.7)
        }
      }
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)

      // Only ever appears on hover or for the current episode, so a long list
      // stays a list of titles rather than a wall of controls.
      BlockButton {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.hasAudio && (hover.hovered || root.selected || root.isCurrent)
        label: root.isPlaying ? "Pause" : "Play"
        filled: root.isPlaying
        ink: root.ink
        horizontalPadding: Style.space(9)
        onActivated: root.played()
      }

      BlockButton {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.showSaveAction && (hover.hovered || root.selected || root.isSaved)
        label: root.isSaved ? "Saved" : "Save"
        filled: root.isSaved
        ink: root.ink
        horizontalPadding: Style.space(9)
        onActivated: if (root.service) root.service.toggleSaveEpisode(root.episode)
      }

      Caption {
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.hasAudio
        text: "No audio"
        ink: root.ink
        dim: 0.35
      }
    }
  }
}
