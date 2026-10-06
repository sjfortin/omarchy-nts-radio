import QtQuick
import qs.Commons

// A hard-edged rectangle with a word in it. Square corners, one-pixel border,
// filled when it is the active choice. No icons where a word will do.
Rectangle {
  id: root

  property string label: ""
  property bool filled: false
  property bool enabledAction: true
  property color ink: Color.foreground
  property color paper: Color.background
  property real horizontalPadding: Style.space(12)

  signal activated()

  activeFocusOnTab: visible && enabledAction
  Accessible.role: Accessible.Button
  Accessible.name: label

  Keys.onPressed: function(event) {
    if (!root.enabledAction) return
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
        || event.key === Qt.Key_Space) {
      root.activated()
      event.accepted = true
    }
  }

  radius: 0
  implicitWidth: buttonLabel.implicitWidth + horizontalPadding * 2
  implicitHeight: Math.max(Style.space(26), buttonLabel.implicitHeight + Style.space(12))
  color: filled ? ink : (hover.hovered && enabledAction ? Util.alpha(ink, 0.12) : "transparent")
  border.color: Util.alpha(ink, filled || activeFocus ? 1.0 : 0.42)
  border.width: activeFocus ? 2 : 1
  opacity: enabledAction ? 1.0 : 0.35

  Behavior on color {
    ColorAnimation { duration: 110 }
  }

  Text {
    id: buttonLabel
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.label
    color: root.filled ? root.paper : root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    font.bold: true
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Math.max(0.5, Style.font.bodySmall * 0.1)
  }

  HoverHandler {
    id: hover
    enabled: root.enabledAction
    cursorShape: Qt.PointingHandCursor
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabledAction
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
