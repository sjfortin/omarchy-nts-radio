import QtQuick
import QtTest
import "../../components" as Components

TestCase {
  id: test
  name: "BoundedPaste"
  when: windowShown
  visible: true
  width: 700
  height: 160
  Component { id: fieldComponent; Components.SearchField { width: 650 } }
  property var field
  property var input
  property var reader
  property var worker

  function init() {
    field = createTemporaryObject(fieldComponent, test)
    verify(field !== null)
    input = findChild(field, "searchInput")
    reader = findChild(field, "clipboardReader")
    worker = findChild(field, "clipboardWorker")
    verify(input !== null && reader !== null && worker !== null)
    field.focusInput()
    tryCompare(field, "hasFocus", true)
  }
  function complete(payload, code) {
    reader.output = JSON.stringify(payload)
    worker.running = false
    worker.exited(code || 0, 0)
  }
  function test_ctrlVInterceptionAndUtf8Insertion() {
    field.text = "NTS "
    input.cursorPosition = 4
    keyClick(Qt.Key_V, Qt.ControlModifier)
    compare(reader.busy, true)
    compare(worker.command[worker.command.length - 1], "clipboard")
    compare(field.text, "NTS ")
    complete({ ok: true, text: "音楽 🎵" })
    compare(field.text, "NTS 音楽 🎵")
    compare(input.cursorPosition, field.text.length)
  }
  function test_shiftInsertAndDedicatedPasteKey() {
    keyClick(Qt.Key_Insert, Qt.ShiftModifier)
    compare(reader.busy, true)
    complete({ ok: true, text: "first" })
    field.clear()
    verify(field.isPasteKey({ key: Qt.Key_Paste, modifiers: 0, matches: function() { return false } }))
    field.requestPaste(false)
    compare(reader.busy, true)
    complete({ ok: true, text: "second" })
    compare(field.text, "second")
  }
  function test_primaryPasteAndRightButtonCannotReachNativeInput() {
    mouseClick(input, 10, 10, Qt.MiddleButton)
    compare(reader.busy, true)
    compare(worker.command[worker.command.length - 1], "primary")
    complete({ ok: true, text: "primary" })
    mouseClick(input, 10, 10, Qt.RightButton)
    compare(reader.busy, false)
    compare(field.text, "primary")
  }
  function test_selectionReplacementAndLengthCap() {
    field.text = "replace me"
    input.select(0, 7)
    field.requestPaste(false)
    complete({ ok: true, text: "音楽" })
    compare(field.text, "音楽 me")
    input.selectAll()
    field.requestPaste(false)
    complete({ ok: true, text: Array(122).join("x") })
    compare(field.text.length, 120)
  }
  function test_failureNeverInsertsPartialText() {
    field.text = "keep"
    field.requestPaste(false)
    complete({ ok: false, error: "Clipboard transfer timed out", text: "partial" })
    compare(field.text, "keep")
    compare(field.pasteMessage, "Clipboard transfer timed out")
    field.requestPaste(false)
    complete({ ok: true, text: Array(4098).join("x") })
    compare(field.text, "keep")
    compare(field.pasteMessage, "Clipboard text is unavailable")
  }
  function test_editsAndFocusLossCancelAndIgnoreLateResults() {
    field.requestPaste(false)
    keyClick(Qt.Key_A)
    compare(reader.cancelled, true)
    complete({ ok: true, text: "stale" })
    compare(field.text, "a")
    field.requestPaste(false)
    field.releaseInput()
    tryCompare(reader, "cancelled", true)
    complete({ ok: true, text: "stale" })
    compare(field.text, "a")
  }
  function test_navigationDisablesPasteAndRepeatedKeysDoNotSpawn() {
    field.requestPaste(false)
    var command = worker.command
    keyClick(Qt.Key_V, Qt.ControlModifier)
    compare(worker.command, command)
    field.pasteEnabled = false
    compare(reader.cancelled, true)
    complete({ ok: true, text: "stale" })
    keyClick(Qt.Key_V, Qt.ControlModifier)
    compare(reader.busy, false)
    compare(field.text, "")
  }
  function test_protocolFailureAndOrdinaryTypingStillWork() {
    keyClick(Qt.Key_A)
    keyClick(Qt.Key_B)
    compare(field.text, "ab")
    keyClick(Qt.Key_Left)
    keyClick(Qt.Key_Backspace)
    compare(field.text, "b")
    field.requestPaste(false)
    reader.output = "not json"
    worker.exited(0, 0)
    compare(field.text, "b")
    compare(field.pasteMessage, "Clipboard text is unavailable")
  }
  function test_guiGuardCancelsAndDiscardsLateOutput() {
    field.text = "keep"
    field.requestPaste(false)
    var guard = findChild(field, "clipboardGuard")
    compare(guard.interval, 3000)
    guard.triggered()
    compare(worker.running, false)
    compare(reader.cancelled, true)
    compare(field.pasteMessage, "Clipboard transfer timed out")
    complete({ ok: true, text: "late" })
    compare(field.text, "keep")
  }
  function test_pasteButtonUsesSameWorker() {
    var button = findChild(field, "pasteButton")
    button.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(reader.busy, true)
    compare(worker.command[worker.command.length - 1], "clipboard")
    complete({ ok: true, text: "button" })
    compare(field.text, "button")
  }

}
