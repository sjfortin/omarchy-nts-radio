import QtQuick
import qs.Commons

// What was played.
//
// Artist and title, in broadcast order, and nothing else. There are no
// timestamps here and no click-to-seek, deliberately: NTS sells "tracklist
// timestamps on archived episodes" as a Supporter benefit, showing the public
// only the first three. Their API returns every offset without asking who is
// calling, but an endpoint being open is not the same as the feature being
// free, so this plugin does not spend it. The offsets are dropped in
// NtsApi.parseTracklist and never reach the UI.
//
// The tracklist itself is public — the same anonymous episode page prints
// every title — so it stays.
Column {
  id: root

  property var tracks: []
  property color ink: Color.foreground
  property int selectedIndex: -1

  spacing: 0

  Repeater {
    model: root.tracks

    Item {
      id: trackRow
      required property var modelData
      required property int index

      width: root.width
      height: Math.max(Style.space(24), title.implicitHeight + Style.space(8))

      Rectangle {
        anchors.fill: parent
        anchors.leftMargin: -Style.space(6)
        anchors.rightMargin: -Style.space(6)
        color: root.selectedIndex === trackRow.index
          ? Util.alpha(root.ink, 0.13) : "transparent"
      }

      // A running number keeps the column readable without implying a time.
      Caption {
        id: position
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(28)
        text: String(trackRow.index + 1)
        ink: root.ink
        dim: 0.35
      }

      Text {
        id: title
        anchors.left: position.right
        anchors.leftMargin: Style.space(4)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: trackRow.modelData.artist !== "" && trackRow.modelData.title !== ""
          ? trackRow.modelData.artist + " — " + trackRow.modelData.title
          : (trackRow.modelData.artist || trackRow.modelData.title)
        color: Util.alpha(root.ink, 0.72)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }
}
