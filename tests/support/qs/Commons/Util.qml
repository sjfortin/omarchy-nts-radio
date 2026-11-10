pragma Singleton
import QtQuick
QtObject {
  function readingKey(event) { return event.key }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
