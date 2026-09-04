import QtQuick
import qs.Commons

// The search input. A rule under a line of type — no rounded box, no magnifier
// glyph, no placeholder chrome. The caret is the affordance.
Item {
  id: root

  property string text: ""
  property string placeholder: "Search shows, hosts, tracks"
  property color ink: Color.foreground
  readonly property bool hasFocus: input.activeFocus

  signal edited(string value)
  signal submitted(string value)
  signal dismissed()

  function clear() {
    input.text = ""
    root.text = ""
  }

  function focusInput() { input.forceActiveFocus() }

  // Give the keyboard back to the page. Without this, moving the cursor into
  // the results would leave the field focused and every bare-key shortcut
  // would be typed into the query instead of acting on the selection.
  function releaseInput() { input.focus = false }

  implicitHeight: input.implicitHeight + Style.space(14)

  TextInput {
    id: input
    anchors.left: parent.left
    anchors.right: clearButton.left
    anchors.rightMargin: Style.space(8)
    anchors.top: parent.top

    color: root.ink
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    selectionColor: Util.alpha(root.ink, 0.28)
    selectedTextColor: root.ink
    selectByMouse: true
    clip: true

    onTextChanged: {
      if (root.text === text) return
      root.text = text
      root.edited(text)
    }

    Keys.onReturnPressed: root.submitted(input.text)
    Keys.onEnterPressed: root.submitted(input.text)
    Keys.onEscapePressed: function(event) {
      // Esc clears a query first and only closes the window when there is
      // nothing left to clear — the usual two-stage escape.
      if (input.text !== "") {
        root.clear()
        root.edited("")
      } else {
        root.dismissed()
      }
      event.accepted = true
    }

    Text {
      anchors.fill: parent
      visible: input.text === ""
      textFormat: Text.PlainText
      text: root.placeholder
      color: Util.alpha(root.ink, 0.3)
      font: input.font
      verticalAlignment: Text.AlignVCenter
    }
  }

  Caption {
    id: clearButton
    anchors.right: parent.right
    anchors.verticalCenter: input.verticalCenter
    visible: input.text !== ""
    text: "Clear"
    ink: root.ink
    dim: clearHover.hovered ? 0.9 : 0.45

    HoverHandler { id: clearHover }

    MouseArea {
      anchors.fill: parent
      anchors.margins: -Style.space(6)
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.clear()
        root.edited("")
        input.forceActiveFocus()
      }
    }
  }

  Rule {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    ink: root.ink
    dim: input.activeFocus ? 0.7 : 0.25
  }
}
