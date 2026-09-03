import QtQuick
import qs.Commons
import qs.Ui

import "Model.js" as Model

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

  readonly property var show: service ? service.now : Model.emptyShow()
  readonly property bool hasShow: show && show.valid === true
  readonly property double nowMs: service ? service.nowMs : Date.now()
  readonly property int channel: service ? service.channel : 1
  readonly property bool playing: service ? service.playing : false
  readonly property bool loading: service ? service.loading : false

  readonly property real controlHeight: Style.space(30)
  readonly property string statusLabel: playing ? "On air" : (loading ? "Connecting" : "Off air")

  // One quiet line, never a notification. Playback problems outrank schedule
  // problems because the user asked for audio; a stale schedule is cosmetic.
  readonly property string problem: {
    if (!service) return ""
    if (service.playbackError !== "" && !playing) return service.playbackError
    if (service.metadataFailed) return service.live ? "Schedule may be out of date" : "Cannot reach NTS"
    return ""
  }

  implicitHeight: layout.implicitHeight

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

          readonly property bool selected: root.channel === modelData
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
            source: root.active && root.show ? root.show.artworkLarge : ""
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
            visible: !root.show || root.show.artworkSmall === ""
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
            text: root.hasShow ? "Now" : (root.service && root.service.live ? "Now" : "Loading")
            dim: 0.45
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.hasShow ? (root.show.title || root.show.showName) : "—"
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
            // The broadcast title usually already carries the guest; the show
            // name is only worth a line when it says something different.
            text: root.hasShow && root.show.showName !== "" && root.show.showName !== root.show.title
              ? root.show.showName : ""
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
            text: {
              if (!root.hasShow) return ""
              var parts = []
              if (root.show.location !== "") parts.push(root.show.location)
              for (var i = 0; i < root.show.genres.length && parts.length < 3; i++)
                parts.push(root.show.genres[i])
              return parts.join(" · ")
            }
          }
        }
      }
    }

    // ---- broadcast clock

    Item {
      width: parent.width
      height: timeRow.implicitHeight + Style.space(8)
      visible: root.hasShow && root.show.startMs > 0

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
            width: parent.width * Model.progressFraction(root.show, root.nowMs)
          }
        }

        Item {
          width: parent.width
          height: startLabel.implicitHeight

          Caption {
            id: startLabel
            anchors.left: parent.left
            text: root.clock(root.show.startMs) + " – " + root.clock(root.show.endMs)
            dim: 0.5
          }

          Caption {
            anchors.right: parent.right
            text: Model.remainingLabel(root.show, root.nowMs)
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
        label: root.playing ? "Pause"
          : (root.loading ? (root.service && root.service.playbackError !== "" ? "Retrying" : "Connecting")
          : "Play")
        filled: root.playing
        enabledAction: root.service !== null
        onActivated: if (root.service) root.service.togglePlayback()
      }

      Item {
        id: volumeSlot
        height: root.controlHeight
        width: Math.max(Style.space(60),
          transport.width - playButton.width - openButton.width - transport.spacing * 2)

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

      BlockButton {
        id: openButton
        width: Style.space(74)
        height: root.controlHeight
        label: "Open"
        enabledAction: root.hasShow
        onActivated: if (root.service) root.service.openCurrentShow()
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
