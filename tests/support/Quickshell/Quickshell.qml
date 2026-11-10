pragma Singleton
import QtQuick
QtObject {
  property var detachedCommands: []
  function env(name) { return name === "HOME" ? "/tmp/nts-test" : "" }
  function execDetached(command) { detachedCommands.push(command) }
}
