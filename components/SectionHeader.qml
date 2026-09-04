import QtQuick
import qs.Commons

// A section's name on the left, an optional aside on the right, a rule under
// both. The browser's only structural device.
Item {
  id: root

  property string title: ""
  property string aside: ""
  property color ink: Color.foreground

  implicitHeight: label.implicitHeight + Style.space(10)

  Caption {
    id: label
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.title
    ink: root.ink
    dim: 0.85
    font.bold: true
  }

  Caption {
    anchors.right: parent.right
    anchors.baseline: label.baseline
    text: root.aside
    ink: root.ink
    dim: 0.4
  }

  Rule {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    ink: root.ink
  }
}
