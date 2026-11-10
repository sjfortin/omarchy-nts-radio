import QtQuick
QtObject {
  property bool deferStart: false
  property bool failNextStart: false
  property bool running: false
  onRunningChanged: {
    if (!running) return
    if (failNextStart) {
      failNextStart = false
      running = false // Real FailedToStart has no started/exited signal.
    } else if (!deferStart) started()
  }
  property bool stdinEnabled: false
  property var command: []
  property var stdout: null
  property var stderr: null
  property var writes: []
  signal started()
  signal exited(int exitCode, int exitStatus)
  function write(text) { writes.push(text) }
  function flush() {}
}
