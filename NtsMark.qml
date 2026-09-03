import QtQuick
import qs.Commons

// The station mark: a hard-edged block of ink with the letters knocked out of
// it when the stream is live, the same block as an outline when it is not.
//
// It is deliberately not the NTS logo — no NTS artwork or trademark is
// redistributed here. It is a typographic stand-in built from the theme's own
// two colours, which is why it stays legible on light themes, dark themes and
// a transparent bar alike.
Item {
  id: root

  property string label: "NTS"
  property bool filled: true
  property color ink: Color.foreground
  property color paper: Color.background
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property real paddingX: Style.spaceReal(4)
  property real paddingY: Style.spaceReal(2)
  property real borderWidth: 1

  implicitWidth: Math.ceil(text.implicitWidth + paddingX * 2 + borderWidth * 2)
  implicitHeight: Math.ceil(text.implicitHeight + paddingY * 2 + borderWidth * 2)

  Rectangle {
    id: block
    anchors.fill: parent
    // Square corners on purpose: the whole visual language here is rules and
    // rectangles, not pills.
    radius: 0
    color: root.filled ? root.ink : "transparent"
    border.width: root.borderWidth
    border.color: root.ink

    Behavior on color {
      ColorAnimation { duration: 120 }
    }
  }

  Text {
    id: text
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.label
    color: root.filled ? root.paper : root.ink
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: true
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Math.max(0.5, root.fontSize * 0.08)
    renderType: Text.NativeRendering
  }
}
