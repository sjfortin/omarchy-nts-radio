import QtQuick
QtObject {
  property string path: ""
  property bool watchChanges: false
  property bool atomicWrites: false
  property bool printErrors: false
  property bool preload: false
  property bool blockLoading: false
  property string contents: ""
  signal loaded()
  signal loadFailed(int error)
  signal saved()
  signal saveFailed(int error)
  function text() { return contents }
  function setText(value) { contents = value; Qt.callLater(function() { saved() }) }
  function reload() {}
}
