import QtQuick
import qs.Commons

// The archive progress bar: a rule that fills, and that you can drag.
//
// While a drag is in progress the displayed position follows the pointer
// rather than the player, so the bar does not fight the user; the seek is
// issued on release.
Item {
  id: root

  property real position: 0
  property real duration: 0
  property bool enabledAction: true
  property color ink: Color.foreground

  signal seeked(real seconds)

  property bool dragging: false
  property real dragFraction: 0

  readonly property real fraction: dragging
    ? dragFraction
    : (duration > 0 ? Math.max(0, Math.min(1, position / duration)) : 0)

  implicitHeight: Style.space(12)

  function fractionAt(x) {
    return width <= 0 ? 0 : Math.max(0, Math.min(1, x / width))
  }

  Rectangle {
    id: track
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    height: hover.hovered || root.dragging ? 5 : 3
    radius: 0
    color: Util.alpha(root.ink, 0.18)

    Behavior on height {
      NumberAnimation { duration: 90 }
    }

    Rectangle {
      height: parent.height
      radius: 0
      width: parent.width * root.fraction
      color: root.ink
    }
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
    preventStealing: true

    onPressed: function(mouse) {
      root.dragging = true
      root.dragFraction = root.fractionAt(mouse.x)
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      root.dragFraction = root.fractionAt(mouse.x)
    }
    onReleased: function(mouse) {
      if (!root.dragging) return
      var target = root.fractionAt(mouse.x) * root.duration
      root.dragging = false
      root.seeked(target)
    }
    onCanceled: root.dragging = false
  }
}
