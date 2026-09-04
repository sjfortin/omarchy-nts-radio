import QtQuick
import qs.Commons

// Uppercase, letter-spaced, quiet. Every label in the browser that is not
// content itself — section headers, metadata, times, states — is one of these.
// The same treatment the bar panel uses, so the two surfaces read as one
// plugin rather than two apps.
Text {
  id: root

  property real dim: 0.55
  property color ink: Color.foreground

  textFormat: Text.PlainText
  color: Util.alpha(ink, dim)
  font.family: Style.font.family
  font.pixelSize: Style.font.caption
  font.capitalization: Font.AllUppercase
  font.letterSpacing: Math.max(0.4, Style.font.caption * 0.09)
  elide: Text.ElideRight
}
