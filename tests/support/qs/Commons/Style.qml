pragma Singleton
import QtQuick
QtObject {
  property var font: ({ family: "sans-serif", body: 14, bodySmall: 12, caption: 11, heading: 24 })
  function space(value) { return value }
}
