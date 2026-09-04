import QtQuick
import qs.Commons

// A hairline. The browser separates things with rules rather than cards or
// shadows: it is a magazine layout, not a dashboard.
Rectangle {
  property color ink: Color.foreground
  property real dim: 0.18

  width: parent ? parent.width : 0
  height: 1
  color: Util.alpha(ink, dim)
}
