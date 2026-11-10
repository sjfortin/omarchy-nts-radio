import QtQuick
QtObject {
  property bool running: false
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
