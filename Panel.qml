import QtQuick
import qs.Commons
import qs.Ui

import "Model.js" as Model
import "NtsApi.js" as NtsApi

// The expanded view: channel selector, the live broadcast, transport, and a
// subordinate look at what is coming next.
//
// Composition is deliberately editorial — rules instead of cards, blocks
// instead of pills, uppercase letter-spaced labels instead of icons wherever a
// word will do. Colour comes from the show artwork and nowhere else; every
// other surface is drawn from the two colours the active Omarchy theme
// already provides, so this reads correctly on a light theme too.
Item {
  id: root

  property QtObject bar: null
  property var service: null

  // The popup keeps this item alive while closed, so artwork is only given a
  // source while the panel is actually on screen. Nothing should be fetching
  // over the network on behalf of a surface nobody can see.
  property bool active: false

  signal requestClose()

  readonly property color ink: bar ? bar.foreground : Color.popups.text
  readonly property color paper: Color.popups.background
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Since Phase 2 the panel has two possible subjects: the live broadcast, or
  // an archived episode. Rather than branching all through the layout, the
  // whole "what is on air" question is answered once here and the layout below
  // reads these.
  readonly property bool archive: service ? service.archiveMode : false
  readonly property var archiveEpisode: service ? service.archiveEpisode : null

  readonly property var show: service ? service.now : Model.emptyShow()
  readonly property bool hasShow: archive
    ? (archiveEpisode !== null && archiveEpisode.valid === true)
    : (show && show.valid === true)

  readonly property string subjectTitle: archive
    ? (archiveEpisode ? archiveEpisode.name : "")
    : (hasShow ? (show.title || show.showName) : "")

  readonly property string subjectSubtitle: {
    if (archive) return archiveEpisode ? archiveEpisode.showName : ""
    if (!hasShow) return ""
    // The broadcast title usually already carries the guest; the show name is
    // only worth a line when it says something different.
    return show.showName !== "" && show.showName !== show.title ? show.showName : ""
  }

  readonly property string subjectArtwork: archive
    ? (archiveEpisode ? (archiveEpisode.artworkLarge || archiveEpisode.artworkSmall) : "")
    : (show ? show.artworkLarge : "")

  readonly property string subjectMeta: {
    var parts = []
    var source = archive ? archiveEpisode : show
    if (!source) return ""
    if (archive) {
      var when = NtsApi.dateLabel(source.broadcastMs)
      if (when) parts.push(when)
    }
    if (source.location) parts.push(source.location)
    for (var i = 0; i < source.genres.length && parts.length < 3; i++) parts.push(source.genres[i])
    return parts.join(" · ")
  }
  readonly property double nowMs: service ? service.nowMs : Date.now()
  readonly property int channel: service ? service.channel : 1
  readonly property bool playing: service ? service.playing : false
  readonly property bool loading: service ? service.loading : false

  readonly property real controlHeight: Style.space(30)
  readonly property string statusLabel: {
    if (archive) return playing ? "Playing" : (loading ? "Loading" : "Paused")
    return playing ? "On air" : (loading ? "Connecting" : "Off air")
  }

  // One quiet line, never a notification. Playback problems outrank schedule
  // problems because the user asked for audio; a stale schedule is cosmetic.
  readonly property string problem: {
    if (!service) return ""
    // A missing backend outranks everything: it explains the failure the user
    // is about to hit, and it is the only problem here with a fix.
    if (!casting && !service.mpvAvailable) return "mpv is not installed — sudo pacman -S mpv"
    if (service.playbackError !== "" && !playing) return service.playbackError
    if (service.metadataFailed) return service.live ? "Schedule may be out of date" : "Cannot reach NTS"
    return ""
  }

  // Shown under the output list, not as an error: casting being unavailable
  // is a missing optional dependency, not something going wrong.
  readonly property string castNote: {
    if (!service || service.castAvailable) return ""
    if (service.castUnavailableReason !== "") return "Casting needs python-pychromecast"
    return ""
  }

  // Archived episodes are resolved on this machine before they can be played,
  // so there is no URL a Chromecast could fetch for itself. The output choice
  // is kept and takes effect again on live radio.
  readonly property string archiveCastNote: archive && casting
    ? "Archived shows play on this computer" : ""

  readonly property bool casting: service ? service.casting : false
  readonly property var castDevices: service ? service.castDevices : []
  readonly property string castTarget: service ? service.castTargetName : ""

  implicitHeight: layout.implicitHeight

  // Discovery is cheap and only runs while the panel is open, so the device
  // list is current by the time anyone looks at the output row.
  // Unconditional: whether casting is available is exactly what discovery
  // answers, so gating on it would mean never finding out. The helper reports
  // back in well under a second when the backend is missing.
  onActiveChanged: if (active && service) service.discoverCastDevices()

  function clock(ms) {
    return ms > 0 ? Qt.formatDateTime(new Date(ms), "HH:mm") : "--:--"
  }

  // ------------------------------------------------------------- components

  component Rule: Rectangle {
    width: parent ? parent.width : 0
    height: 1
    color: Util.alpha(root.ink, 0.22)
  }

  // Uppercase, letter-spaced, quiet. Used for every label that is not
  // content: section headers, metadata, times.
  component Caption: Text {
    property real dim: 0.55
    textFormat: Text.PlainText
    color: Util.alpha(root.ink, dim)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.capitalization: Font.AllUppercase
    font.letterSpacing: Math.max(0.4, Style.font.caption * 0.09)
    elide: Text.ElideRight
  }

  component BlockButton: Rectangle {
    id: blockButton

    property string label: ""
    property bool filled: false
    property bool enabledAction: true
    signal activated()

    radius: 0
    implicitHeight: Math.max(Style.space(26), buttonLabel.implicitHeight + Style.space(12))
    color: filled ? root.ink : (buttonHover.hovered ? Util.alpha(root.ink, 0.1) : "transparent")
    border.width: 1
    border.color: Util.alpha(root.ink, filled ? 1.0 : 0.45)
    opacity: enabledAction ? 1.0 : 0.4

    Behavior on color {
      ColorAnimation { duration: 110 }
    }

    Text {
      id: buttonLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: blockButton.label
      color: blockButton.filled ? root.paper : root.ink
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      font.capitalization: Font.AllUppercase
      font.letterSpacing: Math.max(0.5, Style.font.bodySmall * 0.1)
    }

    HoverHandler { id: buttonHover }

    MouseArea {
      anchors.fill: parent
      enabled: blockButton.enabledAction
      cursorShape: Qt.PointingHandCursor
      onClicked: blockButton.activated()
    }
  }

  // One selectable audio destination. Deliberately a rule-separated row
  // rather than a card: the output list is a subordinate choice, not a
  // second control surface competing with the transport.
  component OutputRow: Item {
    id: outputRow

    property string label: ""
    property string detail: ""
    property bool selected: false
    property bool connecting: false
    property bool enabledAction: true
    signal activated()

    implicitHeight: Math.max(Style.space(22), rowLabel.implicitHeight + Style.space(8))
    height: visible ? implicitHeight : 0
    opacity: enabledAction ? 1.0 : 0.45

    // The selection marker is a filled square, the same language the bar
    // widget uses for "audio is coming out of here".
    Rectangle {
      id: marker
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(7)
      height: width
      radius: 0
      color: outputRow.selected && !outputRow.connecting ? root.ink : "transparent"
      border.width: 1
      border.color: Util.alpha(root.ink, outputRow.selected ? 0.9 : 0.4)
    }

    Text {
      id: rowLabel
      anchors.left: marker.right
      anchors.leftMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: outputRow.label
      color: Util.alpha(root.ink, outputRow.selected ? 1.0 : 0.75)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: outputRow.selected
      elide: Text.ElideRight
      width: Math.max(0, outputRow.width - marker.width - rowDetail.implicitWidth - Style.space(24))
    }

    Caption {
      id: rowDetail
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: outputRow.connecting ? "Connecting" : outputRow.detail
      dim: 0.42
    }

    HoverHandler { id: rowHover }

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      z: -1
      color: rowHover.hovered && outputRow.enabledAction ? Util.alpha(root.ink, 0.07) : "transparent"
    }

    MouseArea {
      anchors.fill: parent
      enabled: outputRow.enabledAction && !outputRow.selected
      cursorShape: Qt.PointingHandCursor
      onClicked: outputRow.activated()
    }
  }

  // ------------------------------------------------------------------ layout

  Column {
    id: layout
    width: parent.width
    spacing: Style.space(10)

    // ---- masthead

    Item {
      width: parent.width
      height: masthead.implicitHeight

      Row {
        id: masthead
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        NtsMark {
          anchors.verticalCenter: parent.verticalCenter
          ink: root.ink
          paper: root.paper
          filled: root.playing
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
        }

        Caption {
          anchors.verticalCenter: parent.verticalCenter
          text: "Radio"
          dim: 0.7
          font.bold: true
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(5)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: 0
          color: root.playing ? root.ink : "transparent"
          border.width: 1
          border.color: Util.alpha(root.ink, 0.6)
        }

        Caption {
          anchors.verticalCenter: parent.verticalCenter
          text: root.statusLabel
          dim: root.playing ? 0.9 : 0.5
        }
      }
    }

    Rule {}

    // ---- channel selector

    Row {
      id: channels
      width: parent.width
      spacing: Style.space(8)

      Repeater {
        model: [1, 2]

        Rectangle {
          id: channelBlock
          required property int modelData

          readonly property bool selected: !root.archive && root.channel === modelData
          readonly property var live: root.service ? root.service.channelState(modelData) : Model.emptyChannel(modelData)

          width: (channels.width - Style.space(8)) / 2
          implicitHeight: channelColumn.implicitHeight + Style.space(16)
          radius: 0
          color: selected ? root.ink : (channelHover.hovered ? Util.alpha(root.ink, 0.08) : "transparent")
          border.width: 1
          border.color: Util.alpha(root.ink, selected ? 1.0 : 0.35)

          Behavior on color {
            ColorAnimation { duration: 110 }
          }

          Column {
            id: channelColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(9)
            anchors.rightMargin: Style.space(9)
            spacing: Style.space(3)

            Text {
              textFormat: Text.PlainText
              text: Model.channelLabel(channelBlock.modelData)
              color: channelBlock.selected ? root.paper : root.ink
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              font.letterSpacing: Math.max(0.5, Style.font.subtitle * 0.06)
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Model.barTitle(channelBlock.live.now)
              visible: text !== ""
              color: Util.alpha(channelBlock.selected ? root.paper : root.ink, 0.62)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          HoverHandler { id: channelHover }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.service) root.service.setChannel(channelBlock.modelData)
          }
        }
      }
    }

    Rule {}

    // ---- the live broadcast

    // The artwork block is the only colour in the panel, and it is left to
    // stand on its own: no wash, no tint, no gradient behind the type.
    Item {
      width: parent.width
      height: liveRow.implicitHeight + Style.space(6)

      Row {
        id: liveRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(12)

        Rectangle {
          id: artFrame
          width: Style.space(92)
          height: width
          radius: 0
          color: Util.alpha(root.ink, 0.06)
          border.width: 1
          border.color: Util.alpha(root.ink, 0.35)

          Image {
            anchors.fill: parent
            anchors.margins: 1
            source: root.active ? root.subjectArtwork : ""
            visible: status === Image.Ready
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            // Hold the previous cover while the next one decodes, so a
            // handover between shows does not blink an empty frame.
            retainWhileLoading: true
            sourceSize.width: 400
          }

          // Empty frame rather than a placeholder icon: a missing image is
          // information too, and a glyph here would be the loudest thing in
          // the panel.
          Caption {
            anchors.centerIn: parent
            visible: root.subjectArtwork === ""
            text: "NTS"
            dim: 0.3
            font.bold: true
          }
        }

        Column {
          width: liveRow.width - artFrame.width - Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Caption {
            width: parent.width
            text: root.archive ? "Archive" : (root.hasShow || (root.service && root.service.live) ? "Now" : "Loading")
            dim: 0.45
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.hasShow ? root.subjectTitle : "—"
            color: root.ink
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.subjectSubtitle
            visible: text !== ""
            color: Util.alpha(root.ink, 0.65)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Caption {
            width: parent.width
            visible: text !== ""
            dim: 0.5
            text: root.subjectMeta
          }
        }
      }
    }

    // ---- broadcast clock

    Item {
      width: parent.width
      height: timeRow.implicitHeight + Style.space(8)
      visible: root.archive ? root.hasShow : (root.hasShow && root.show.startMs > 0)

      Column {
        id: timeRow
        width: parent.width
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(5)

        Rectangle {
          width: parent.width
          height: Style.space(3)
          radius: 0
          color: Util.alpha(root.ink, 0.18)

          Rectangle {
            height: parent.height
            radius: 0
            color: root.ink
            width: parent.width * (root.archive
              ? (root.service && root.service.durationSec > 0
                 ? Math.max(0, Math.min(1, root.service.positionSec / root.service.durationSec)) : 0)
              : Model.progressFraction(root.show, root.nowMs))
          }
        }

        Item {
          width: parent.width
          height: startLabel.implicitHeight

          Caption {
            id: startLabel
            anchors.left: parent.left
            // Live shows a wall clock; an archive shows how far in you are,
            // because "19:00 – 21:00" says nothing about a recording.
            text: root.archive
              ? (root.service ? NtsApi.clockFromSeconds(root.service.positionSec) : "0:00")
              : root.clock(root.show.startMs) + " – " + root.clock(root.show.endMs)
            dim: 0.5
          }

          Caption {
            anchors.right: parent.right
            text: root.archive
              ? (root.service && root.service.durationSec > 0
                 ? NtsApi.clockFromSeconds(root.service.durationSec) : "")
              : Model.remainingLabel(root.show, root.nowMs)
            dim: 0.5
          }
        }
      }
    }

    // ---- transport

    Row {
      id: transport
      width: parent.width
      spacing: Style.space(8)
      height: root.controlHeight

      BlockButton {
        id: playButton
        width: Style.space(94)
        height: root.controlHeight
        // "Retrying" rather than a "Connecting" that never resolves: the
        // player backs off and keeps trying, and this button is also how the
        // user calls it off.
        label: root.playing ? (root.casting && !root.archive ? "Stop" : "Pause")
          : (root.loading ? (root.service && root.service.playbackError !== "" ? "Retrying" : "Connecting")
          : "Play")
        filled: root.playing
        enabledAction: root.service !== null
        onActivated: if (root.service) root.service.togglePlayback()
      }

      Item {
        id: volumeSlot
        height: root.controlHeight
        width: Math.max(Style.space(60), transport.width - playButton.width - transport.spacing)

        Caption {
          id: volumeLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Vol"
          dim: 0.5
        }

        PanelSlider {
          anchors.left: volumeLabel.right
          anchors.right: parent.right
          anchors.leftMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          value: root.service ? root.service.volume : 70
          onMoved: function(value) { if (root.service) root.service.setVolume(value) }
          onReleased: function(value) { if (root.service) root.service.setVolume(value) }
        }
      }

    }

    // The way out of the mini-player and into the full application, plus a
    // one-press return to live radio when an archive has taken over.
    Row {
      width: parent.width
      spacing: Style.space(8)

      BlockButton {
        width: root.archive
          ? (parent.width - Style.space(8) * 2) / 3
          : (parent.width - Style.space(8)) / 2
        height: root.controlHeight
        label: "Browse"
        enabledAction: root.service !== null
        onActivated: {
          if (root.service) root.service.openBrowser()
          root.requestClose()
        }
      }

      BlockButton {
        visible: root.archive
        width: (parent.width - Style.space(8) * 2) / 3
        height: root.controlHeight
        label: "Live"
        enabledAction: root.service !== null
        onActivated: if (root.service) root.service.playLive()
      }

      BlockButton {
        width: root.archive
          ? (parent.width - Style.space(8) * 2) / 3
          : (parent.width - Style.space(8)) / 2
        height: root.controlHeight
        label: "Open"
        enabledAction: root.hasShow
        onActivated: if (root.service) root.service.openCurrent()
      }
    }

    // ---- output: this machine, or a device that fetches the stream itself

    Rule {
      visible: outputSection.visible
    }

    Column {
      id: outputSection
      width: parent.width
      spacing: Style.space(5)
      // Hidden entirely when there is nothing to choose between: no cast
      // backend installed and no devices means no decision to present.
      visible: root.service && (root.service.castAvailable || root.casting || root.castNote !== "")

      Item {
        width: parent.width
        height: outputHeader.implicitHeight

        Caption {
          id: outputHeader
          anchors.left: parent.left
          text: "Output"
          dim: 0.45
          font.bold: true
        }

        Caption {
          anchors.right: parent.right
          text: root.service && root.service.castDiscovering ? "Looking…" : ""
          dim: 0.4
        }
      }

      // "This computer" is always first and always available; devices follow
      // in discovery order.
      Column {
        width: parent.width
        spacing: Style.space(4)

        // While an archive plays, the audio really is on this machine
        // whatever the remembered output says, so the list shows that rather
        // than the preference. Anything else would point at a speaker that is
        // silent.
        OutputRow {
          width: parent.width
          label: "This computer"
          detail: root.service && !root.service.mpvAvailable ? "mpv not installed" : ""
          selected: !root.casting || root.archive
          enabledAction: root.service !== null && root.service.mpvAvailable
          onActivated: if (root.service) root.service.castToLocal()
        }

        Repeater {
          model: root.castDevices

          OutputRow {
            required property var modelData

            width: outputSection.width
            label: modelData.name
            // A device that is the remembered output but cannot take the
            // current audio says so, instead of silently looking unselected.
            detail: root.archive && root.service && root.service.castUuid === modelData.uuid
              ? "Live radio only" : modelData.model
            selected: root.casting && !root.archive && root.service
              && root.service.castUuid === modelData.uuid
            connecting: selected && root.service && !root.service.castConnected
            onActivated: if (root.service) root.service.castTo(modelData.uuid, modelData.name)
          }
        }

        Caption {
          width: parent.width
          visible: root.castNote !== "" || root.archiveCastNote !== ""
          text: root.castNote !== "" ? root.castNote : root.archiveCastNote
          dim: 0.4
          topPadding: Style.space(3)
        }

        // A remembered device that is not answering right now still deserves
        // a row, so the panel explains the state rather than losing it.
        OutputRow {
          width: parent.width
          visible: root.casting && !root.archive && root.castTarget !== ""
            && !Model.hasDevice(root.castDevices, root.service ? root.service.castUuid : "")
          label: root.castTarget
          detail: "Not on this network"
          selected: true
          enabledAction: false
        }
      }
    }

    // ---- up next, kept quiet and secondary

    Rule {
      visible: upNext.visible
    }

    Column {
      id: upNext
      width: parent.width
      spacing: Style.space(5)
      visible: root.service && root.service.upNext.length > 0

      Caption {
        text: "Up next"
        dim: 0.45
        font.bold: true
      }

      Repeater {
        model: root.service ? root.service.upNext.slice(0, 3) : []

        Item {
          id: upNextRow
          required property var modelData

          width: upNext.width
          height: upNextTitle.implicitHeight + Style.space(3)

          Caption {
            id: upNextTime
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(42)
            text: root.clock(upNextRow.modelData.startMs)
            dim: 0.45
          }

          Text {
            id: upNextTitle
            anchors.left: upNextTime.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Model.barTitle(upNextRow.modelData)
            color: Util.alpha(root.ink, 0.72)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }
      }
    }

    // ---- quiet failure line

    Caption {
      width: parent.width
      visible: root.problem !== ""
      text: root.problem
      dim: 0.55
      color: Util.alpha(Color.urgent, 0.85)
    }
  }
}
