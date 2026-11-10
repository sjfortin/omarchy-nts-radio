import QtQuick
import Quickshell.Io

// Explicit requests only. Never bind canPaste/clipboard text in the GUI.
// Only the helper's bounded JSON reaches StdioCollector; raw clipboard bytes
// stay in a worker with a byte cap and an absolute deadline.
Item {
  id: root
  visible: false
  property bool processActive: false
  property bool cancelled: false
  property string output: ""
  readonly property bool busy: processActive
  signal received(string text)
  signal failed(string message)

  function request(primary) {
    if (processActive) return false
    cancelled = false
    output = ""
    processActive = true
    var path = decodeURIComponent(String(Qt.resolvedUrl("../scripts/clipboard_read.py")).replace(/^file:\/\//, ""))
    worker.command = ["python3", path, primary === true ? "primary" : "clipboard"]
    worker.running = true
    guard.restart()
    return true
  }

  function cancel() {
    cancelled = true
    guard.stop()
    if (processActive) worker.running = false
  }

  Timer {
    id: guard
    objectName: "clipboardGuard"
    interval: 3000
    onTriggered: {
      root.cancel()
      root.failed("Clipboard transfer timed out")
    }
  }

  Process {
    id: worker
    objectName: "clipboardWorker"
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.output = String(text || "")
    }
    // The helper has a fixed error vocabulary and discards producer stderr.
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code, status) {
      guard.stop()
      root.processActive = false
      if (root.cancelled) { root.output = ""; return }
      var result = null
      // A second protocol bound, independent of the helper's 4 KB input cap.
      if (code === 0 && root.output.length <= 25000) {
        try { result = JSON.parse(root.output) } catch (e) {}
      }
      root.output = ""
      if (result && result.ok === true && typeof result.text === "string" && result.text.length <= 4096)
        root.received(result.text)
      else root.failed(result && typeof result.error === "string"
        ? result.error.slice(0, 120) : "Clipboard text is unavailable")
    }
  }

  Component.onDestruction: cancel()
}
