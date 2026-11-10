pragma Singleton
import QtQuick
import qs.Commons as Commons

QtObject {
  property Commons.Translations catalog: Commons.Translations { directory: Qt.resolvedUrl("../i18n") }
  function t(english) { return catalog.t(english, english) }
  function tn(key, count) { return catalog.tn(key, count) }
}
