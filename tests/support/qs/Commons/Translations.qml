import QtQuick
QtObject {
  property var directory: ""
  function t(key, fallback) { return fallback === undefined ? key : fallback }
  function tn(key, count) { return key }
}
