import QtQuick
import qs.Commons

import "../NtsApi.js" as NtsApi

// What was played, and when.
//
// NTS timestamps most archived episodes track by track, and those offsets are
// seconds into the same recording mpv is playing — so a timestamp is not just
// a label, it is a seek target. Rows with an offset are clickable; rows
// without one are still listed, just inert. Nothing here is a blocker: an
// episode with no tracklist simply has no section.
Column {
  id: root

  property var tracks: []
  property var service: null
  property var episode: null
  property color ink: Color.foreground
  property int selectedIndex: -1

  // Only offer seeking when this episode is the one actually playing.
  // Seeking a recording that is not loaded would either do nothing or, worse,
  // scrub whatever else is on air.
  readonly property bool seekable: service && episode
    ? service.isCurrentEpisode(episode) && service.canSeek : false
  readonly property real position: service ? service.positionSec : 0

  spacing: 0

  Repeater {
    model: root.tracks

    Item {
      id: trackRow
      required property var modelData
      required property int index

      readonly property bool hasOffset: modelData.offsetSec >= 0
      readonly property bool canSeek: root.seekable && hasOffset
      // The track that is playing right now: this one has started and the
      // next one has not.
      readonly property bool current: hasOffset && root.seekable
        && root.position >= modelData.offsetSec
        && (index + 1 >= root.tracks.length
            || root.tracks[index + 1].offsetSec < 0
            || root.position < root.tracks[index + 1].offsetSec)

      width: root.width
      height: Math.max(Style.space(24), title.implicitHeight + Style.space(8))

      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -Style.space(6)
        anchors.rightMargin: -Style.space(6)
        color: root.selectedIndex === trackRow.index ? Util.alpha(root.ink, 0.15)
          : trackRow.current ? Util.alpha(root.ink, 0.09)
          : (rowHover.hovered && trackRow.canSeek ? Util.alpha(root.ink, 0.05) : "transparent")
      }

      HoverHandler { id: rowHover }

      MouseArea {
        anchors.fill: parent
        enabled: trackRow.canSeek
        cursorShape: Qt.PointingHandCursor
        onClicked: root.service.seekTo(trackRow.modelData.offsetSec)
      }

      Caption {
        id: stamp
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        // Wide enough for H:MM:SS — a two-hour show elides its own timestamps
        // otherwise, which is exactly when they matter most.
        width: Style.space(62)
        // NTS fingerprints only part of most tracklists and evenly spaces the
        // rest. A tilde says which times were heard and which were guessed, so
        // a seek that lands slightly off is explained rather than surprising.
        text: !trackRow.hasOffset ? "—"
          : (trackRow.modelData.estimated ? "~" : "") + NtsApi.clockFromSeconds(trackRow.modelData.offsetSec)
        ink: root.ink
        // A timestamp you can act on reads brighter than one you cannot.
        dim: trackRow.current ? 0.95 : (trackRow.canSeek ? 0.6 : 0.3)
      }

      Text {
        id: title
        anchors.left: stamp.right
        anchors.leftMargin: Style.space(4)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: trackRow.modelData.artist !== "" && trackRow.modelData.title !== ""
          ? trackRow.modelData.artist + " — " + trackRow.modelData.title
          : (trackRow.modelData.artist || trackRow.modelData.title)
        color: Util.alpha(root.ink, trackRow.current ? 1.0 : 0.72)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        font.bold: trackRow.current
        elide: Text.ElideRight
      }
    }
  }
}
