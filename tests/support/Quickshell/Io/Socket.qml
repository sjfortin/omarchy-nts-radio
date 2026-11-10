import QtQuick
QtObject {
  property string path: ""
  property bool connected: false
  property var parser: null
  property var writes: []
  signal connectionStateChanged()
  signal error(int error)
  function write(text) { writes.push(text) }
  function flush() {}
}
