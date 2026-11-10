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
  readonly property bool busy: activeRequest
  property bool activeRequest: false
  property bool childStarted: false

  // ok is false for any transport failure or non-2xx status. `text` is the
  // body on success and "" otherwise — callers never see a half-response.
  signal finished(string text, bool ok, int httpStatus)

  // Filled by onStreamFinished, which fires before onExited because the
  // collector waits for end-of-stream. StdioCollector has no reset(), so the
  // body is captured per-run here rather than read off the collector later.
  property string body: ""
  property int httpStatus: 0

  function start(target) {
    if (busy) return false
    url = String(target || "")
    if (url === "") return false
    body = ""
    httpStatus = 0
    request.command = [
      "curl", "-fsS", "--compressed",
      "--max-time", String(Math.max(3, Math.min(60, timeoutSeconds))),
      // A redirect to a host we did not ask for is not something to follow
      // blindly, but NTS does 302 within its own domain; three hops is ample.
      "--location", "--max-redirs", "3",
      // https on the way out and https on every hop after it. Without the
      // second, a 302 is enough to move the whole exchange onto plaintext, and
      // a redirect is exactly the part of a request we do not control.
      "--proto", "=https",
      "--proto-redir", "=https",
      // The largest thing NTS answers with is a show page carrying its first
      // page of episodes, about 40KB. This is not a real expectation, it is a
      // ceiling: the body is collected into a string in the shell's own heap,
      // so a response that is wrong by orders of magnitude should be dropped
      // rather than held.
      "--max-filesize", "4000000",
      "--write-out", "%{stderr}%{http_code}",
      "-H", "Accept: application/json",
      "-A", "omarchy-nts-radio",
      url
    ]
    childStarted = false
    activeRequest = true
    request.running = true
    return true
  }

  function abort() {
    if (request.running) request.running = false
  }

  function complete(exitCode) {
    if (!activeRequest) return
    var payload = exitCode === 0 ? body : ""
    var status = httpStatus
    body = ""
    httpStatus = 0
    activeRequest = false
    childStarted = false
    finished(payload, exitCode === 0 && payload !== "", status)
  }

  Process {
    id: request
    objectName: "curlRequest"
    running: false
    onStarted: root.childStarted = true
    // FailedToStart has no exited signal. Started children retain the slot
    // until their collectors finish and exited arrives.
    onRunningChanged: if (!running && !root.childStarted) root.complete(-1)

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.body = String(text || "")
    }

    // curl's diagnostics are noise; the exit code carries the outcome.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.httpStatus = Number(String(text || "").slice(-3)) || 0
    }

    onExited: function(exitCode, exitStatus) { root.complete(exitCode) }
  }
}
