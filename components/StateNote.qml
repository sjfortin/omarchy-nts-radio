import QtQuick
import qs.Commons

// The quiet inline state a page shows instead of its content: loading, empty,
// or failed. Never a dialog, never a modal — a line of text where the content
// would have been, in the same register as everything else.
Item {
  id: root

  property string text: ""
  property bool isError: false
  property color ink: Color.foreground
  // Optional recovery action, shown as a block button under the line.
  property string actionLabel: ""
  signal actionTriggered()

  visible: text !== ""
  implicitHeight: visible ? column.implicitHeight + Style.space(24) : 0

  Column {
    id: column
    anchors.centerIn: parent
    spacing: Style.space(10)

    Caption {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.text
      ink: root.isError ? Color.urgent : root.ink
      dim: root.isError ? 0.9 : 0.5
    }

    BlockButton {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.actionLabel !== ""
      label: root.actionLabel
      ink: root.ink
      onActivated: root.actionTriggered()
    }
  }
}
