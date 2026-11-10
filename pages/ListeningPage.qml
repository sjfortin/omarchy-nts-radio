import QtQuick
import QtQuick.Dialogs
import qs.Commons
import qs.Commons as Commons
import "../components" as Nts
import "../Library.js" as Library

Item {
  id: root
  property var service: null
  property bool active: true
  property color ink: Commons.Color.foreground
  property string tab: "queue"
  property int cursor: -1
  readonly property var items: !service ? [] : tab === "queue" ? service.queue : tab === "history" ? service.history : []
  signal episodeRequested(var episode)

  function nextTab() { tab = tab === "queue" ? "history" : tab === "history" ? "library" : "queue" }
  function moveCursor(delta) {
    if (!items.length) return
    cursor = Math.max(0, Math.min(items.length - 1, cursor < 0 ? 0 : cursor + delta))
    list.positionViewAtIndex(cursor, ListView.Contain)
  }
  function activateCursor() { if (cursor >= 0 && cursor < items.length) episodeRequested(items[cursor]) }
  function playCursor() {
    if (!service || cursor < 0 || cursor >= items.length) return
    if (tab === "queue") service.playQueued(cursor)
    else service.playEpisode(items[cursor], -1)
  }
  function saveCursor() { if (service && cursor >= 0 && cursor < items.length) service.toggleSaveEpisode(items[cursor]) }
  onTabChanged: cursor = -1

  FileDialog {
    id: exportDialog
    title: Nts.Strings.t("Export library")
    fileMode: FileDialog.SaveFile
    nameFilters: ["JSON backups (*.json)"]
    defaultSuffix: "json"
    onAccepted: if (root.service) root.service.exportLibrary(selectedFile)
  }
  FileDialog {
    id: importDialog
    title: Nts.Strings.t("Import library")
    fileMode: FileDialog.OpenFile
    nameFilters: ["JSON backups (*.json)"]
    onAccepted: if (root.service) root.service.previewImport(selectedFile)
  }

  Column {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.margins: Style.space(20)
    spacing: Style.space(12)

    Text {
      textFormat: Text.PlainText
      text: Nts.Strings.t("Listening")
      color: root.ink
      font.family: Style.font.family
      font.pixelSize: Style.font.display
      font.bold: true
    }
    Flow {
      width: parent.width
      spacing: Style.space(8)
      Repeater {
        model: [{ key: "queue", label: Nts.Strings.t("Queue") }, { key: "history", label: Nts.Strings.t("History") }, { key: "library", label: Nts.Strings.t("Library tools") }]
        Nts.BlockButton {
          required property var modelData
          label: modelData.label
          filled: root.tab === modelData.key
          ink: root.ink
          onActivated: root.tab = modelData.key
        }
      }
      Nts.BlockButton {
        visible: root.tab === "queue"
        label: Nts.Strings.t("Start queue")
        ink: root.ink
        enabledAction: root.items.length > 0
        onActivated: root.service.playNextQueued()
      }
      Nts.BlockButton {
        visible: root.tab === "queue"
        label: Nts.Strings.t("Clear queue")
        ink: root.ink
        enabledAction: root.items.length > 0
        onActivated: root.service.clearQueue()
      }
      Nts.BlockButton {
        visible: root.tab === "history"
        label: Nts.Strings.t("Clear history")
        ink: root.ink
        enabledAction: root.items.length > 0
        onActivated: root.service.clearHistory()
      }
    }
    Nts.Caption {
      width: parent.width
      ink: root.ink
      text: !root.service ? "" : root.service.sleepAtEpisodeEnd ? Nts.Strings.t("Sleep: at episode end")
        : root.service.sleepRemainingMinutes > 0 ? Nts.Strings.t("Sleep: %1 min remaining").arg(Commons.I18n.formatNumber(root.service.sleepRemainingMinutes)) : Nts.Strings.t("Sleep timer off")
    }
    Flow {
      width: parent.width
      spacing: Style.space(6)
      Repeater {
        model: [15, 30, 60]
        Nts.BlockButton {
          required property int modelData
          label: Nts.Strings.t("%1 min").arg(Commons.I18n.formatNumber(modelData))
          ink: root.ink
          onActivated: if (root.service) root.service.setSleepTimer(modelData)
        }
      }
      Nts.BlockButton {
        label: Nts.Strings.t("At episode end")
        ink: root.ink
        enabledAction: root.service && root.service.archiveMode
        onActivated: root.service.setSleepAtEnd()
      }
      Nts.BlockButton {
        label: Nts.Strings.t("Off")
        ink: root.ink
        onActivated: if (root.service) root.service.setSleepTimer(0)
      }
    }
    Nts.Rule { ink: root.ink }
  }

  ListView {
    id: list
    anchors.top: header.bottom
    anchors.topMargin: Style.space(10)
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(20)
    clip: true
    reuseItems: true
    visible: root.tab !== "library"
    model: root.items
    boundsBehavior: Flickable.StopAtBounds
    delegate: Column {
      id: row
      required property var modelData
      required property int index
      width: list.width
      Nts.EpisodeRow {
        width: parent.width
        episode: row.modelData
        showQueueAction: root.tab !== "queue"
        service: root.service
        selected: root.cursor === row.index
        ink: root.ink
        onOpened: root.episodeRequested(row.modelData)
        onPlayed: root.tab === "queue" ? root.service.playQueued(row.index) : root.service.playEpisode(row.modelData, -1)
      }
      Flow {
        visible: root.tab === "queue"
        width: parent.width
        spacing: Style.space(6)
        Nts.BlockButton {
          label: Nts.Strings.t("Move up")
          ink: root.ink
          enabledAction: row.index > 0
          onActivated: root.service.moveQueued(row.index, -1)
        }
        Nts.BlockButton {
          label: Nts.Strings.t("Move down")
          ink: root.ink
          enabledAction: row.index + 1 < root.items.length
          onActivated: root.service.moveQueued(row.index, 1)
        }
        Nts.BlockButton {
          label: Nts.Strings.t("Remove")
          ink: root.ink
          onActivated: root.service.removeQueued(row.index)
        }
      }
    }
    Nts.StateNote {
      width: parent.width
      visible: root.items.length === 0
      ink: root.ink
      text: root.tab === "queue" ? Nts.Strings.t("Your queue is empty — add episodes with Queue or Play next") : Nts.Strings.t("Episodes you listen to will appear here")
    }
  }

  Nts.Scroller {
    anchors.top: header.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(20)
    visible: root.tab === "library"
    contentWidth: width
    contentHeight: tools.implicitHeight
    Column {
      id: tools
      width: parent.width
      spacing: Style.space(12)
      Nts.BlockButton {
        label: root.service && root.service.followSavedShows ? Nts.Strings.t("Saved-show updates: on") : Nts.Strings.t("Saved-show updates: off")
        filled: root.service && root.service.followSavedShows
        ink: root.ink
        onActivated: if (root.service) {
          root.service.followSavedShows = !root.service.followSavedShows
          root.service.requestPersist()
        }
      }
      Nts.Caption {
        width: parent.width
        wrapMode: Text.Wrap
        ink: root.ink
        text: Nts.Strings.t("Optional updates check up to 20 saved shows each hour. Larger libraries rotate across checks. Recent episodes appear on Home.")
      }
      Row {
        spacing: Style.space(8)
        Nts.BlockButton {
          label: Nts.Strings.t("Export library")
          ink: root.ink
          enabledAction: root.service && !root.service.transferBusy
          onActivated: exportDialog.open()
        }
        Nts.BlockButton {
          label: Nts.Strings.t("Import backup")
          ink: root.ink
          enabledAction: root.service && !root.service.transferBusy
          onActivated: importDialog.open()
        }
      }
      Nts.Caption {
        width: parent.width
        wrapMode: Text.Wrap
        ink: root.ink
        text: root.service ? Nts.Strings.t(root.service.libraryTransferMessage) : ""
      }
      Nts.Caption {
        width: parent.width
        wrapMode: Text.Wrap
        ink: root.ink
        text: {
          var preview = root.service ? root.service.importPreview : null
          return preview ? Nts.Strings.t("Backup contains %1 shows, %2 episodes, %3 history entries and %4 queued episodes. Import replaces your library; a backup is saved first.")
            .arg(Commons.I18n.formatNumber(preview.shows.length)).arg(Commons.I18n.formatNumber(preview.episodes.length)).arg(Commons.I18n.formatNumber(preview.history.length)).arg(Commons.I18n.formatNumber(preview.queue.length)) : ""
        }
      }
      Nts.BlockButton {
        visible: root.service && root.service.importPreview !== null
        label: Nts.Strings.t("Replace library with backup")
        ink: root.ink
        enabledAction: root.service && !root.service.transferBusy
        onActivated: root.service.applyImport()
      }
      Nts.Caption {
        width: parent.width
        wrapMode: Text.Wrap
        ink: root.ink
        text: Nts.Strings.t("History stays on this computer and can be cleared. Sleep timers require this computer and the plugin to stay awake; a cast speaker cannot run the timer by itself.")
      }
    }
  }
}
