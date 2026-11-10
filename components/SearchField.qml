import QtQuick
import qs.Commons
import qs.Commons as Commons

// The search input. A rule under a line of type — no rounded box, no magnifier
// glyph, no placeholder chrome. The caret is the affordance.
Item {
  id: root

  property string text: ""
  property string placeholder: "Search artists, tracks, shows or genres"
  property color ink: Commons.Color.foreground
  readonly property bool hasFocus: input.activeFocus
  readonly property bool pasting: clipboard.busy
  property string pasteMessage: ""
  property var pasteSnapshot: null
  property bool pasteEnabled: true

  function isPasteKey(event) {
    return event.matches(StandardKey.Paste) || event.key === Qt.Key_Paste
      || (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier))
      || (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
  }

  function requestPaste(primary) {
    if (!pasteEnabled || !input.activeFocus || clipboard.busy) return
    pasteMessage = ""
    pasteSnapshot = { text: input.text, cursor: input.cursorPosition,
      start: input.selectionStart, end: input.selectionEnd }
    clipboard.request(primary === true)
  }

  function cancelPaste() {
    pasteSnapshot = null
    clipboard.cancel()
  }

  onHasFocusChanged: if (!hasFocus) cancelPaste()
  onVisibleChanged: if (!visible) cancelPaste()
  onPasteEnabledChanged: if (!pasteEnabled) cancelPaste()

  ClipboardReader {
    id: clipboard
    objectName: "clipboardReader"
    onReceived: function(value) {
      var snapshot = root.pasteSnapshot
      root.pasteSnapshot = null
      // Discard late responses after edits, cursor/selection changes, page
      // navigation, focus loss or cancellation. Never paste into a new query.
      if (!snapshot || !root.pasteEnabled || !input.activeFocus || input.text !== snapshot.text
          || input.cursorPosition !== snapshot.cursor || input.selectionStart !== snapshot.start
          || input.selectionEnd !== snapshot.end) return
      var start = Math.min(snapshot.start, snapshot.end)
      var end = Math.max(snapshot.start, snapshot.end)
      var available = Math.max(0, input.maximumLength - (input.text.length - (end - start)))
      var bounded = value.slice(0, available)
      // Do not split an astral Unicode character at the UTF-16 limit.
      if (bounded.length && /[\uD800-\uDBFF]$/.test(bounded)) bounded = bounded.slice(0, -1)
      if (start !== end) input.remove(start, end)
      input.insert(start, bounded)
      input.cursorPosition = start + bounded.length
    }
    onFailed: function(message) { root.pasteSnapshot = null; root.pasteMessage = message }
  }

  onTextChanged: if (input.text !== text) input.text = text

  signal edited(string value)
  signal submitted(string value)

  function clear() {
    cancelPaste()
    pasteMessage = ""
    input.text = ""
    root.text = ""
  }

  function focusInput() { input.forceActiveFocus() }

  // Give the keyboard back to the page. Without this, moving the cursor into
  // the results would leave the field focused and every bare-key shortcut
  // would be typed into the query instead of acting on the selection.
  function releaseInput() { input.focus = false }

  implicitHeight: input.implicitHeight + Style.space(14)
    + (pasteMessage !== "" ? pasteNote.implicitHeight + Style.space(6) : 0)

  TextInput {
    id: input
    objectName: "searchInput"
    maximumLength: 120
    anchors.left: parent.left
    anchors.right: pasteButton.left
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
      if (clipboard.busy) root.cancelPaste()
      if (root.text === text) return
      root.text = text
      root.edited(text)
    }

    onCursorPositionChanged: if (clipboard.busy) root.cancelPaste()
    onSelectionStartChanged: if (clipboard.busy) root.cancelPaste()
    onSelectionEndChanged: if (clipboard.busy) root.cancelPaste()

    Keys.priority: Keys.BeforeItem
    Keys.onShortcutOverride: function(event) { if (root.isPasteKey(event)) event.accepted = true }
    Keys.onPressed: function(event) {
      if (root.isPasteKey(event)) {
        event.accepted = true
        if (!event.isAutoRepeat) root.requestPaste(false)
      }
    }

    // TextInput also has a native primary-selection paste on middle release.
    // Consume both middle and right button sequences before the parent input;
    // the explicit Paste button supplies a safe pointer/accessibility route.
    MouseArea {
      objectName: "pasteMouseArea"
      anchors.fill: parent
      acceptedButtons: Qt.MiddleButton | Qt.RightButton
      preventStealing: true
      onPressed: function(mouse) { mouse.accepted = true }
      onReleased: function(mouse) { mouse.accepted = true }
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) {
          input.forceActiveFocus()
          input.cursorPosition = input.positionAt(mouse.x, mouse.y)
          root.requestPaste(true)
        }
      }
    }

    Keys.onReturnPressed: root.submitted(input.text)
    Keys.onEnterPressed: root.submitted(input.text)
    Keys.onEscapePressed: function(event) {
      // Esc clears a query first and only leaves the page when there is
      // nothing left to clear — the usual two-stage escape.
      //
      // The second stage is *not* handled here: leaving the event unaccepted
      // lets it carry on up the focus chain to the window, which is what walks
      // the back stack and ultimately closes the browser. Accepting it
      // unconditionally — which this did — made Escape do nothing at all
      // whenever the field was focused and empty.
      if (input.text === "") {
        event.accepted = false
        return
      }
      root.clear()
      root.edited("")
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
    id: pasteButton
    objectName: "pasteButton"
    anchors.right: clearButton.left
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: input.verticalCenter
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: Strings.t("Paste into search")
    text: root.pasting ? Strings.t("Pasting…") : Strings.t("Paste")
    ink: root.ink
    dim: root.pasting ? 0.35 : 0.55
    function activate() { input.forceActiveFocus(); root.requestPaste(false) }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
        event.accepted = true
        activate()
      }
    }
    MouseArea {
      anchors.fill: parent
      anchors.margins: Style.space(3)
      cursorShape: Qt.PointingHandCursor
      onClicked: pasteButton.activate()
    }
  }

  Caption {
    id: pasteNote
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: input.bottom
    anchors.topMargin: Style.space(6)
    visible: root.pasteMessage !== ""
    text: Strings.t(root.pasteMessage)
    ink: root.ink
    wrapMode: Text.Wrap
  }

  Caption {
    id: clearButton
    activeFocusOnTab: visible
    Accessible.role: Accessible.Button
    Accessible.name: "Clear search"
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
          || event.key === Qt.Key_Space) {
        root.clear()
        root.edited("")
        input.forceActiveFocus()
        event.accepted = true
      }
    }
    anchors.right: parent.right
    anchors.verticalCenter: input.verticalCenter
    visible: input.text !== ""
    text: Strings.t("Clear")
    ink: root.ink
    dim: clearHover.hovered || activeFocus ? 0.9 : 0.45

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
