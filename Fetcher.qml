import QtQuick
import Quickshell.Io

// One HTTP GET, in a subprocess.
//
// Every network read in the plugin goes through one of these — Api.qml owns a
// small pool of them and hands work out. Nothing here knows what an NTS URL
// looks like; that is NtsApi.js's job.
//
// curl rather than a QML network stack for the same reason the live schedule
// already uses it: the work happens in another process, so a slow or hung
// connection cannot block the UI thread, and --max-time bounds it absolutely.
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property string url: ""
  property int timeoutSeconds: 15
  readonly property bool busy: request.running

  // ok is false for any transport failure or non-2xx status. `text` is the
  // body on success and "" otherwise — callers never see a half-response.
  signal finished(string text, bool ok)

  // Filled by onStreamFinished, which fires before onExited because the
  // collector waits for end-of-stream. StdioCollector has no reset(), so the
  // body is captured per-run here rather than read off the collector later.
  property string body: ""

  function start(target) {
    if (request.running) return false
    url = String(target || "")
    if (url === "") return false
    body = ""
    request.command = [
      "curl", "-fsS", "--compressed",
      "--max-time", String(Math.max(3, Math.min(60, timeoutSeconds))),
      // A redirect to a host we did not ask for is not something to follow
      // blindly, but NTS does 302 within its own domain; three hops is ample.
      "--location", "--max-redirs", "3",
      "-H", "Accept: application/json",
      "-A", "omarchy-nts-radio",
      url
    ]
    request.running = true
    return true
  }

  function abort() {
    if (request.running) request.running = false
  }

  Process {
    id: request
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.body = String(text || "")
    }

    // curl's diagnostics are noise; the exit code carries the outcome.
    stderr: StdioCollector { waitForEnd: true }

    onExited: function(exitCode, exitStatus) {
      var payload = exitCode === 0 ? root.body : ""
      root.body = ""
      root.finished(payload, exitCode === 0 && payload !== "")
    }
  }
}
