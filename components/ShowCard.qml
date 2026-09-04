import QtQuick
import qs.Commons

// A show or an episode as a grid card: artwork above, title and one line of
// metadata below. Used for the editorial rails on the home page and for the
// saved shelves, where the artwork is the point and the list row would waste
// the width.
Item {
  id: root

  // Either a show (from NtsApi.parseShow / search) or an episode. Both carry
  // name/artwork/genres, so one card renders both and the caller says which.
  required property var item
  property bool isShow: false
  property var service: null
  property bool active: true
  property color ink: Color.foreground
  property string subtitle: ""
  property bool selected: false

  signal opened()
  signal played()

  readonly property bool hasAudio: !isShow && item && item.audioUrl !== ""
  readonly property bool isPlaying: !isShow && service && item
    ? service.isCurrentEpisode(item) && service.playing : false
  readonly property bool isCurrent: !isShow && service && item
    ? service.isCurrentEpisode(item) : false

  implicitHeight: art.height + text.implicitHeight + Style.space(8)

  HoverHandler { id: hover }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: root.opened()
  }

  ArtFrame {
    id: art
    width: parent.width
    height: width
    source: root.item ? (root.item.artworkLarge || root.item.artworkSmall) : ""
    active: root.active
    ink: root.ink
    decodeWidth: 400
    showPlayAffordance: root.hasAudio
    hovered: hover.hovered || root.selected
    playing: root.isPlaying
    border.color: root.selected ? root.ink : Util.alpha(root.ink, 0.28)
    border.width: root.selected ? 2 : 1

    MouseArea {
      anchors.fill: parent
      enabled: root.hasAudio
      cursorShape: Qt.PointingHandCursor
      onClicked: root.played()
    }
  }

  Column {
    id: text
    anchors.top: art.bottom
    anchors.topMargin: Style.space(8)
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(2)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.item ? root.item.name : ""
      color: root.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: root.isCurrent
      elide: Text.ElideRight
      maximumLineCount: 2
      wrapMode: Text.Wrap
    }

    Caption {
      width: parent.width
      text: root.subtitle
      visible: text !== ""
      ink: root.ink
      dim: 0.42
    }
  }
}
