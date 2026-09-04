import QtQuick
import qs.Commons

import "../Model.js" as Model
import "../NtsApi.js" as NtsApi

// The persistent transport across the bottom of the browser window.
//
// It reads entirely from the shared service, which is what makes it agree with
// the bar widget at all times: both are views onto the same playback, and
// neither owns it. Live and archive are shown differently on purpose — an
// archive gets a position, a duration and a scrubber; live gets the on-air
// square and the channel, because it has no position to report and offering a
// scrubber for it would be a lie.
Item {
  id: root

  property var service: null
  property color ink: Color.foreground
  property color paper: Color.background

  signal showRequested(string showAlias, string episodeAlias)

  readonly property bool archive: service ? service.archiveMode : false
  readonly property var episode: service ? service.archiveEpisode : null
  readonly property bool playing: service ? service.playing : false
  readonly property bool loading: service ? service.loading : false
  readonly property var liveShow: service ? service.now : null

  readonly property string primary: {
    if (!service) return ""
    if (archive) return episode ? episode.name : ""
    return liveShow && liveShow.valid ? Model.barTitle(liveShow) : Model.channelLabel(service.channel)
  }

  readonly property string secondary: {
    if (!service) return ""
    if (archive) {
      if (!episode) return "Archive"
      var parts = ["Archive"]
      if (episode.showName && episode.showName !== episode.name) parts.push(episode.showName)
      var when = NtsApi.dateLabel(episode.broadcastMs)
      if (when) parts.push(when)
      return parts.join(" · ")
    }
    return Model.channelLabel(service.channel) + " · Live"
  }

  implicitHeight: Style.space(72)

  Rule {
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    ink: root.ink
    dim: 0.28
  }

  Row {
    id: layout
    anchors.fill: parent
    anchors.topMargin: Style.space(12)
    anchors.bottomMargin: Style.space(12)
    anchors.leftMargin: Style.space(16)
    anchors.rightMargin: Style.space(16)
    spacing: Style.space(14)

    ArtFrame {
      id: thumb
      width: parent.height
      height: width
      anchors.verticalCenter: parent.verticalCenter
      source: {
        if (root.archive) return root.episode ? root.episode.artworkSmall : ""
        return root.liveShow ? root.liveShow.artworkSmall : ""
      }
      ink: root.ink
      decodeWidth: 200

      MouseArea {
        anchors.fill: parent
        enabled: root.archive && root.episode !== null
        cursorShape: Qt.PointingHandCursor
        onClicked: root.showRequested(root.episode.showAlias, root.episode.episodeAlias)
      }
    }

    // Transport. "Live" is a stop rather than a pause: there is no position to
    // hold, so calling it Pause would promise something the medium cannot do.
    BlockButton {
      id: transport
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(78)
      label: root.playing
        ? (root.archive ? "Pause" : (root.service && root.service.castingAudio ? "Stop" : "Pause"))
        : (root.loading ? "…" : "Play")
      filled: root.playing
      ink: root.ink
      paper: root.paper
      enabledAction: root.service !== null
      onActivated: if (root.service) root.service.togglePlayback()
    }

    // Title block and, for archives, the scrubber under it.
    Item {
      id: middle
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(Style.space(120),
        layout.width - thumb.width - transport.width - volumeBlock.width - layout.spacing * 3)
      height: parent.height

      Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Row {
          width: parent.width
          spacing: Style.space(7)

          // On-air square: solid while audio is flowing. The same mark the bar
          // widget uses, so the two surfaces say the same thing.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(7)
            height: width
            radius: 0
            color: root.playing ? root.ink : "transparent"
            border.width: 1
            border.color: Util.alpha(root.ink, 0.55)
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(14)
            textFormat: Text.PlainText
            text: root.primary
            color: root.ink
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
          }
        }

        Caption {
          width: parent.width
          text: root.secondary
          ink: root.ink
          dim: 0.45
        }

        Item {
          width: parent.width
          height: root.archive ? seek.implicitHeight : 0
          visible: root.archive
          clip: true

          SeekBar {
            id: seek
            anchors.left: parent.left
            anchors.right: elapsed.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            ink: root.ink
            position: root.service ? root.service.positionSec : 0
            duration: root.service ? root.service.durationSec : 0
            enabledAction: root.service ? root.service.canSeek : false
            onSeeked: function(seconds) { if (root.service) root.service.seekTo(seconds) }
          }

          Caption {
            id: elapsed
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            ink: root.ink
            dim: 0.5
            text: {
              if (!root.service) return ""
              var at = NtsApi.clockFromSeconds(root.service.positionSec)
              var total = root.service.durationSec > 0
                ? NtsApi.clockFromSeconds(root.service.durationSec) : "--:--"
              return at + " / " + total
            }
          }
        }
      }
    }

    Item {
      id: volumeBlock
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(120)
      height: parent.height

      Caption {
        id: volumeLabel
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "Vol"
        ink: root.ink
        dim: 0.45
      }

      // The same bar as the scrubber, standing in for a slider: one visual
      // idea doing two jobs rather than two controls that look different for
      // no reason.
      SeekBar {
        anchors.left: volumeLabel.right
        anchors.leftMargin: Style.space(8)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        ink: root.ink
        position: root.service ? root.service.volume : 70
        duration: 100
        enabledAction: root.service !== null
        onSeeked: function(value) { if (root.service) root.service.setVolume(value) }
      }
    }
  }
}
