import QtQuick
import qs.Commons
import qs.Ui

// qs.Ui exports a `Panel` of its own, and an explicit module import shadows
// the plugin's own directory. Qualify ours so `Panel.qml` next door is the
// one that gets instantiated.
import "." as Nts
import "Model.js" as Model
import "NtsApi.js" as NtsApi

// Collapsed bar presence: the station mark, the channel, an on-air square,
// and — when there is room for it — the current broadcast title.
//
// One of these exists per monitor. All of them read the same Service, so the
// stream keeps playing no matter which one is clicked or whether any panel is
// open at all.
BarWidget {
  id: root

  moduleName: "sjfortin.nts-radio"

  property var service: null
  property bool popupOpen: false
  property bool watching: false

  readonly property color ink: bar ? bar.barForeground : Color.foreground
  readonly property color paper: bar ? bar.background : Color.background

  readonly property int channel: service ? service.channel : 1
  readonly property bool playing: service ? service.playing : false
  readonly property bool loading: service ? service.loading : false

  // The bar always reflects what is actually on the air, which since Phase 2
  // is not necessarily live radio. An archived episode replaces both the
  // channel token and the title, so the widget never claims to be playing NTS 2
  // while a two-year-old show is coming out of the speakers.
  readonly property bool archive: service ? service.archiveMode : false
  readonly property var archiveEpisode: service ? service.archiveEpisode : null

  readonly property string showTitle: {
    if (!service) return ""
    if (archive) return archiveEpisode ? archiveEpisode.name : ""
    return Model.barTitle(service.now)
  }

  // Where the channel number goes. "ARC" is short enough for a bar and is
  // spelled out as "Archive" in the tooltip and the panel.
  readonly property string sourceToken: archive ? "ARC" : String(channel)

  readonly property string titleMode: String(root.setting("showTitleInBar", "When playing"))
  readonly property int maxTitleWidth: Math.max(0, Math.min(480,
    Math.floor(Number(root.setting("maxBarTextWidth", 160))) || 0))
  readonly property bool titleVisible: !vertical && maxTitleWidth > 0 && showTitle !== ""
    && titleMode !== "Never" && (titleMode === "Always" || playing || loading)

  // Shape the bar's summon/hide/toggle routing expects on a bar-widget root.
  readonly property bool opened: popupOpen
  function open() { setPopupOpen(true) }
  function close() { setPopupOpen(false) }
  function togglePanel() { setPopupOpen(!popupOpen) }

  // ------------------------------------------------------------------ wiring

  // The shell builds services and bar widgets from the same registry sweep, so
  // whichever lands first has to tolerate the other not existing yet.
  function resolveService() {
    if (service || !bar || !bar.shell) return
    var found = null
    if (typeof bar.shell.serviceFor === "function") found = bar.shell.serviceFor(moduleName)
    if (!found && typeof bar.shell.ensureService === "function") found = bar.shell.ensureService(moduleName)
    if (!found) return
    service = found
    syncSettings()
    syncWatcher()
  }

  // The bar assigns `bar` and `settings` in the same deferred pass, `bar`
  // first, so the service is usually resolved before there is anything to
  // give it. Re-offering on every settings change is what makes a remembered
  // channel survive a shell restart.
  function syncSettings() {
    if (!service) return
    if (!service.settingsAdopted) service.adoptSettings(settings)
    else service.applySettings(settings)
  }

  onSettingsChanged: syncSettings()

  // Persist back into this widget's inline shell.json entry, the same path
  // the built-in clock widget uses for its own remembered state.
  function persist(values) {
    if (!values) return
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    var changed = false
    for (var key in values) {
      if (entry[key] !== values[key]) changed = true
      entry[key] = values[key]
    }
    if (!changed) return
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  // The service polls faster while any UI is on screen; this is how it knows.
  function syncWatcher() {
    if (!service) return
    var shouldWatch = popupOpen
    if (shouldWatch === watching) return
    watching = shouldWatch
    if (shouldWatch) service.addWatcher()
    else service.removeWatcher()
  }

  function setPopupOpen(value) {
    if (popupOpen === value) return
    popupOpen = value
    syncWatcher()
  }

  onBarChanged: resolveService()
  Component.onCompleted: resolveService()

  Component.onDestruction: {
    if (watching && service) {
      service.removeWatcher()
      watching = false
    }
  }

  Timer {
    interval: 500
    repeat: true
    running: root.service === null
    triggeredOnStart: true
    onTriggered: root.resolveService()
  }

  Connections {
    target: root.service
    function onSettingsShouldPersist() { root.persist(root.service.persistableSettings()) }
  }

  // ------------------------------------------------------------------ layout

  implicitWidth: vertical ? barSize : content.implicitWidth + Style.space(14)
  implicitHeight: vertical ? content.implicitHeight + Style.space(12) : barSize

  Row {
    id: content
    visible: !root.vertical
    anchors.centerIn: parent
    spacing: Style.space(5)

    NtsMark {
      anchors.verticalCenter: parent.verticalCenter
      ink: root.ink
      paper: root.paper
      filled: root.playing
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: Style.font.caption
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.sourceToken
      color: root.ink
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    // On-air square. Solid while audio is flowing, hollow while it is not,
    // and dimmed on a slow cycle while connecting — the only animation in
    // the widget, and the only one that carries information.
    Rectangle {
      id: onAir
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(6)
      height: width
      radius: 0
      color: root.playing ? root.ink : "transparent"
      border.width: 1
      border.color: root.ink
      opacity: root.loading ? 0.9 : 1.0

      SequentialAnimation on opacity {
        running: root.loading
        loops: Animation.Infinite
        alwaysRunToEnd: true
        NumberAnimation { to: 0.25; duration: 700; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 0.9; duration: 700; easing.type: Easing.InOutQuad }
      }
    }

    Item {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.titleVisible
      width: visible ? Math.min(root.maxTitleWidth, title.implicitWidth) : 0
      height: title.implicitHeight
      clip: true

      Text {
        id: title
        textFormat: Text.PlainText
        text: root.showTitle
        color: root.ink
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        width: parent.width
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // Vertical bars get the mark and the channel only; a broadcast title has
  // nowhere to go.
  Column {
    id: verticalContent
    visible: root.vertical
    anchors.centerIn: parent
    spacing: Style.space(4)

    NtsMark {
      anchors.horizontalCenter: parent.horizontalCenter
      ink: root.ink
      paper: root.paper
      filled: root.playing
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: Style.font.caption
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: root.sourceToken
      color: root.ink
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.service) return
      if (mouse.button === Qt.MiddleButton) root.service.togglePlayback()
      else if (mouse.button === Qt.RightButton) {
        // From an archive, the other channel is not the obvious next step —
        // getting back to live radio at all is. So the first right-click
        // returns to live and further ones flip channels as before.
        if (root.archive) root.service.playLive(root.channel)
        else root.service.setChannel(root.channel === 1 ? 2 : 1)
      }
      else root.togglePanel()
    }

    onWheel: function(wheel) {
      if (!root.service) return
      root.service.setVolume(root.service.volume + (wheel.angleDelta.y > 0 ? 5 : -5))
    }

    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  function tooltip() {
    var state = playing ? "On air" : (loading ? "Connecting" : "Stopped")
    var line = archive ? "Archive · " + state : Model.channelLabel(channel) + " · " + state
    if (archive && service && service.durationSec > 0) {
      line += " · " + NtsApi.clockFromSeconds(service.positionSec)
        + " / " + NtsApi.clockFromSeconds(service.durationSec)
    }
    if (showTitle !== "") line += "\n" + showTitle
    var last = archive
      ? "Click for the panel · middle-click to pause · right-click for live radio"
      : "Click for the panel · middle-click to play · right-click to switch channel"
    return line + "\n" + last
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(372))
    contentHeight: popup.fittedContentHeight(panel.implicitHeight)

    Nts.Panel {
      id: panel
      width: parent.width
      bar: root.bar
      service: root.service
      active: root.popupOpen
      onRequestClose: root.close()
    }
  }
}
