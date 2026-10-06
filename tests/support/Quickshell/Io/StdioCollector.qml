import QtQuick

QtObject {
  property bool waitForEnd: false
  signal streamFinished(string text)
}
