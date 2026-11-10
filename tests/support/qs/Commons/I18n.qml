pragma Singleton
import QtQuick
QtObject {
  property bool rightToLeft: false
  property string formatLocale: "en_US"
  function formatNumber(number) { return String(number) }
}
